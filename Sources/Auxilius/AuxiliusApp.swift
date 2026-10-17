import AppKit
import SwiftUI

struct AuxiliusApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // A plain stored property, because SwiftUI's @State macro does not ship with the Command Line Tools.
    // The App value is created once, so the session lives as long as the app.
    private let session = Session()
    private let settingsForm = SettingsForm()

    var body: some Scene {
        Window("Auxilius", id: "main") {
            ContentView(session: session)
                .frame(minWidth: 760, minHeight: 480)
                .task { await session.start() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Transcript") { session.copyTranscript() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(session.transcript.isEmpty)
                Button("Copy Page Image") { session.copyPageImage() }
                    .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                    .disabled(session.page == nil)
            }
            CommandMenu("Camera") {
                Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(session: session, form: settingsForm)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
