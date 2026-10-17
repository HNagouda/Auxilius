import AppKit
import SwiftUI

struct ContentView: View {
    private static let pageShare = 0.58

    let session: Session

    var body: some View {
        // A fixed split rather than HSplitView, which opens with the page squeezed to its minimum width.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                PagePane(session: session)
                    .frame(width: geometry.size.width * Self.pageShare)
                Divider()
                TranscriptPane(session: session)
            }
        }
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    private var subtitle: String {
        switch session.cameraState {
        case .starting: return "Starting camera"
        case .paused: return "Paused"
        case .denied, .unavailable, .failed: return ""
        case .running:
            if session.isTranscribing { return "Reading the page…" }
            if session.isWriting { return "Following along" }
            guard let capturedAt = session.pageCapturedAt else { return "Watching" }
            let time = capturedAt.formatted(date: .omitted, time: .shortened)
            return session.isTranscriptCurrent ? "Up to date · \(time)" : "Page captured · \(time)"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Camera", selection: Binding(get: { session.selectedCamera?.uniqueID ?? "" }, set: session.selectCamera)) {
                    ForEach(session.cameras, id: \.uniqueID) { camera in
                        Text(camera.localizedName).tag(camera.uniqueID)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Camera", systemImage: "camera")
            }
            .help("Choose a camera")
            .disabled(session.cameras.isEmpty)
        }
        ToolbarItem {
            Button(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play" : "pause") {
                session.togglePause()
            }
            .help(session.isPaused ? "Resume the camera" : "Pause the camera")
            .disabled(session.cameraState != .running && !session.isPaused)
        }
    }
}

private struct PagePane: View {
    let session: Session

    var body: some View {
        Group {
            switch session.cameraState {
            case .denied:
                ContentUnavailableView {
                    Label("No Camera Access", systemImage: "video.slash")
                } description: {
                    Text("Auxilius needs the camera to see your page.")
                } actions: {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }
            case .unavailable:
                ContentUnavailableView("No Camera", systemImage: "video.slash", description: Text("Connect a camera or bring your iPhone close to use Continuity Camera."))
            case .failed(let message):
                ContentUnavailableView {
                    Label("Camera Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await session.start() } }
                }
            case .starting, .running, .paused:
                if let preview = session.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .opacity(session.isPaused ? 0.4 : 1)
                        .padding(24)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }
}

private struct TranscriptPane: View {
    let session: Session

    var body: some View {
        VStack(spacing: 0) {
            if !session.transcript.isEmpty {
                TranscriptView(text: session.transcript, pageJPEG: session.transcribedPageJPEG)
            } else if !session.hasAPIKey {
                ContentUnavailableView {
                    Label("No Transcription", systemImage: "text.viewfinder")
                } description: {
                    Text("Add an Anthropic API key to turn your handwriting into text. Claude can already see the page through MCP.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                }
                .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nothing Written Yet", systemImage: "pencil.and.scribble", description: Text("Write on your page. The text appears here once you pause."))
                    .frame(maxHeight: .infinity)
            }

            if let error = session.transcriptionError {
                Divider()
                HStack {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Try Again") { session.retryTranscription() }
                        .disabled(session.isTranscribing)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()
            HStack {
                Spacer()
                Button {
                    session.copyTranscript()
                } label: {
                    Label(session.didJustCopy ? "Copied" : "Copy", systemImage: session.didJustCopy ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help("Copy the transcript, with circuits as netlists, to paste into any chat (⇧⌘C)")
                .disabled(session.transcript.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
