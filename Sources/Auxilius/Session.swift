import AppKit
import AVFoundation
import Observation
import OSLog

enum CameraState: Equatable {
    case starting
    case running
    case paused
    case denied
    case unavailable
    case failed(String)
}

/// Everything the window shows, and the glue between the camera, the transcriber and the feed.
@MainActor
@Observable
final class Session {
    private static let selectedCameraKey = "selectedCameraID"
    private static let modelKey = "transcriptionModel"
    private static let copiedConfirmation = Duration.seconds(1.5)
    private static let keepsHistoryKey = "keepsPageHistory"
    private static let logger = Logger(subsystem: "auxilius", category: "session")

    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var selectedCameraID = UserDefaults.standard.string(forKey: selectedCameraKey)
    private(set) var cameraState = CameraState.starting
    private(set) var preview: CGImage?
    private(set) var page: CGImage?
    private(set) var pageCapturedAt: Date?
    private(set) var isWriting = false
    // The model's Markdown, circuit blocks included. Chats get `chatTranscript` instead.
    private(set) var transcript = ""
    // The photo the transcript was read from, which the transcript pane crops sketches out of.
    private(set) var transcribedPageJPEG: Data?
    private(set) var didJustCopy = false
    private(set) var isTranscribing = false
    private(set) var transcriptionError: String?
    // Read from the keychain once per launch: an ad-hoc signed rebuild can make every read ask for permission.
    private(set) var apiKey = Keychain.apiKey()
    private(set) var model = Session.savedModel()
    // Off by default: it keeps every camera photo of the page on disk.
    private(set) var keepsHistory = UserDefaults.standard.bool(forKey: keepsHistoryKey)

    private var camera: Camera!
    private var pageJPEG: Data?
    private var pageNumber = 0
    // The current page's name in the page history, when the history is on.
    private var historyName: String?
    private var transcribedPageNumber = 0

    init() {
        let processor = FrameProcessor { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
        camera = Camera(onFrame: processor.process)

        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.camerasChanged() }
            }
        }
    }

    var isPaused: Bool { cameraState == .paused }

    var hasAPIKey: Bool { apiKey != nil }

    var isTranscriptCurrent: Bool { pageNumber > 0 && transcribedPageNumber == pageNumber }

    var selectedCamera: AVCaptureDevice? {
        cameras.first { $0.uniqueID == selectedCameraID } ?? cameras.first
    }

    // * ====================================================================
    // * === camera
    // * ====================================================================

    func start() async {
        cameras = Camera.availableDevices()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await runCamera()
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) {
                await runCamera()
            } else {
                cameraState = .denied
            }
        default:
            cameraState = .denied
        }
    }

    func selectCamera(_ id: String) {
        selectedCameraID = id
        UserDefaults.standard.set(id, forKey: Self.selectedCameraKey)
        Task { await runCamera() }
    }

    func togglePause() {
        if isPaused {
            Task { await runCamera() }
        } else if cameraState == .running {
            camera.stop()
            cameraState = .paused
        }
    }

    private func runCamera() async {
        guard let device = selectedCamera else {
            camera.stop()
            cameraState = .unavailable
            return
        }

        cameraState = .starting
        do {
            try await camera.start(device)
            cameraState = .running
        } catch {
            Self.logger.error("Could not start \(device.localizedName): \(error.localizedDescription)")
            cameraState = .failed(error.localizedDescription)
        }
    }

    private func camerasChanged() {
        let previous = selectedCamera?.uniqueID
        cameras = Camera.availableDevices()
        guard cameraState != .denied, cameraState != .paused else { return }

        // Restart only if the camera in use went away or a camera turned up after there was none.
        if selectedCamera?.uniqueID != previous || cameraState == .unavailable {
            Task { await runCamera() }
        }
    }

    // * ====================================================================
    // * === pages
    // * ====================================================================

    private func handle(_ event: FrameEvent) {
        guard cameraState == .running else { return }

        switch event {
        case .preview(let image):
            preview = image
        case .writing(let writing):
            isWriting = writing
        case .newPage(let image, let jpeg, let foundPage):
            let capturedAt = Date()
            page = image
            pageJPEG = jpeg
            pageCapturedAt = capturedAt
            pageNumber += 1
            do {
                try Feed.write(jpeg: jpeg)
            } catch {
                Self.logger.error("Could not save the page for chat: \(error.localizedDescription)")
            }
            // Frames without a detected sheet are usually the desk or a sleeve, not worth keeping.
            historyName = keepsHistory && foundPage ? saveToHistory(jpeg, capturedAt: capturedAt) : nil
            writeRecord()
            transcribeLatestPage()
        }
    }

    private func saveToHistory(_ jpeg: Data, capturedAt: Date) -> String? {
        do {
            return try PageHistory.save(jpeg: jpeg, capturedAt: capturedAt)
        } catch {
            Self.logger.error("Could not add the page to the history: \(error.localizedDescription)")
            return nil
        }
    }

    // A failure here only costs the history its transcript, so it must not stop transcription.
    private func saveTranscriptToHistory(forPageNamed name: String) {
        do {
            try PageHistory.saveTranscript(transcript, model: model.id, forPageNamed: name)
        } catch {
            Self.logger.error("Could not add the transcript to the history: \(error.localizedDescription)")
        }
    }

    func setKeepsHistory(_ keeps: Bool) {
        keepsHistory = keeps
        UserDefaults.standard.set(keeps, forKey: Self.keepsHistoryKey)
    }

    private func writeRecord() {
        guard let pageCapturedAt else { return }

        let record = PageRecord(capturedAt: pageCapturedAt, transcript: chatTranscript, transcriptIsCurrent: transcribedPageNumber == pageNumber)
        do {
            try Feed.write(record)
        } catch {
            Self.logger.error("Could not save the transcript for chat: \(error.localizedDescription)")
        }
    }

    // * ====================================================================
    // * === transcription
    // * ====================================================================

    /// Reads pages one at a time; pages that arrive meanwhile collapse into the newest one.
    /// After a failure it waits for Try Again or a new key, rather than failing again on every page.
    func transcribeLatestPage() {
        guard !isTranscribing, transcriptionError == nil, let apiKey else { return }

        isTranscribing = true
        Task {
            while transcribedPageNumber < pageNumber, let jpeg = pageJPEG {
                let number = pageNumber
                let pageHistoryName = historyName
                do {
                    transcript = try await Transcriber.transcribe(jpeg: jpeg, previous: transcript, model: model, apiKey: apiKey)
                    transcribedPageJPEG = jpeg
                    transcribedPageNumber = number
                    writeRecord()
                    if let pageHistoryName {
                        saveTranscriptToHistory(forPageNamed: pageHistoryName)
                    }
                } catch {
                    Self.logger.error("Transcription failed: \(error.localizedDescription)")
                    transcriptionError = error.localizedDescription
                    break
                }
            }
            isTranscribing = false
        }
    }

    func saveAPIKey(_ key: String) throws {
        try Keychain.save(apiKey: key)
        apiKey = key
        transcriptionError = nil
        transcribeLatestPage()
    }

    func retryTranscription() {
        transcriptionError = nil
        transcribeLatestPage()
    }

    func selectModel(_ model: ClaudeModel) {
        self.model = model
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(model), forKey: Self.modelKey)
        } catch {
            Self.logger.error("Could not save the model choice: \(error.localizedDescription)")
        }
    }

    private static func savedModel() -> ClaudeModel {
        guard let data = UserDefaults.standard.data(forKey: modelKey) else { return .standard }
        do {
            return try JSONDecoder().decode(ClaudeModel.self, from: data)
        } catch {
            logger.error("Saved model choice is unreadable, using the default: \(error.localizedDescription)")
            return .standard
        }
    }

    func removeAPIKey() throws {
        try Keychain.deleteAPIKey()
        apiKey = nil
    }

    // * ====================================================================
    // * === pasteboard
    // * ====================================================================

    var chatTranscript: String {
        Netlist.chatVersion(of: transcript)
    }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chatTranscript, forType: .string)

        didJustCopy = true
        Task {
            try? await Task.sleep(for: Self.copiedConfirmation)
            didJustCopy = false
        }
    }

    func copyPageImage() {
        guard let page else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: page, size: .zero)])
    }
}
