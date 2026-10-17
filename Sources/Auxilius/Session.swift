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
    private static let logger = Logger(subsystem: "auxilius", category: "session")

    private(set) var cameras: [AVCaptureDevice] = []
    private(set) var selectedCameraID = UserDefaults.standard.string(forKey: selectedCameraKey)
    private(set) var cameraState = CameraState.starting
    private(set) var preview: CGImage?
    private(set) var page: CGImage?
    private(set) var pageCapturedAt: Date?
    private(set) var isWriting = false
    private(set) var transcript = ""
    private(set) var isTranscribing = false
    private(set) var transcriptionError: String?
    private(set) var hasAPIKey = Keychain.apiKey() != nil
    private(set) var model = Session.savedModel()

    private var camera: Camera!
    private var pageJPEG: Data?
    private var pageNumber = 0
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
        case .newPage(let image, let jpeg):
            page = image
            pageJPEG = jpeg
            pageCapturedAt = Date()
            pageNumber += 1
            do {
                try Feed.write(jpeg: jpeg)
            } catch {
                Self.logger.error("Could not save the page for chat: \(error.localizedDescription)")
            }
            writeRecord()
            transcribeLatestPage()
        }
    }

    private func writeRecord() {
        guard let pageCapturedAt else { return }

        let record = PageRecord(capturedAt: pageCapturedAt, transcript: transcript, transcriptIsCurrent: transcribedPageNumber == pageNumber)
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
    func transcribeLatestPage() {
        guard !isTranscribing, let apiKey = Keychain.apiKey() else { return }

        isTranscribing = true
        transcriptionError = nil
        Task {
            while transcribedPageNumber < pageNumber, let jpeg = pageJPEG {
                let number = pageNumber
                do {
                    transcript = try await Transcriber.transcribe(jpeg: jpeg, previous: transcript, model: model, apiKey: apiKey)
                    transcribedPageNumber = number
                    writeRecord()
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
        hasAPIKey = true
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
        hasAPIKey = false
    }

    // * ====================================================================
    // * === pasteboard
    // * ====================================================================

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func copyPageImage() {
        guard let page else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: page, size: .zero)])
    }
}
