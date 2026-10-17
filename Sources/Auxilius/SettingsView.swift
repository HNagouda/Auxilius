import AppKit
import SwiftUI

/// The settings window's own state. A class rather than @State, which needs Xcode's macro plugins to build.
@Observable
final class SettingsForm {
    var draftKey = ""
    var keyError: String?
    var claudeDesktopResult: String?
    var models: [ClaudeModel] = []
    var modelsError: String?
}

struct SettingsView: View {
    let session: Session
    @Bindable var form: SettingsForm

    var body: some View {
        Form {
            transcriptionSection
            chatSection
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: session.hasAPIKey) { await loadModels() }
    }

    private var transcriptionSection: some View {
        Section {
            if session.hasAPIKey {
                LabeledContent("Anthropic API key") {
                    HStack {
                        Text("Saved in Keychain").foregroundStyle(.secondary)
                        Button("Remove") { run { try session.removeAPIKey() } }
                    }
                }
            } else {
                LabeledContent("Anthropic API key") {
                    HStack {
                        SecureField("sk-ant-…", text: $form.draftKey)
                            .labelsHidden()
                        Button("Save") {
                            run { try session.saveAPIKey(form.draftKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            form.draftKey = ""
                        }
                        .disabled(form.draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            if let keyError = form.keyError {
                Text(keyError).foregroundStyle(.secondary)
            }
            Picker("Model", selection: Binding(get: { session.model }, set: session.selectModel)) {
                ForEach(modelChoices) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .disabled(form.models.isEmpty)
            if let modelsError = form.modelsError {
                Text(modelsError).foregroundStyle(.secondary)
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text("Each time you pause writing, the model reads the page. The list shows every model on your account that can read images. Get a key at [platform.claude.com](https://platform.claude.com/settings/keys).")
                .foregroundStyle(.secondary)
        }
    }

    private var chatSection: some View {
        Section {
            LabeledContent("Claude Desktop") {
                Button("Connect") {
                    do {
                        try ChatConnections.addToClaudeDesktop()
                        form.claudeDesktopResult = "Connected. Quit and reopen Claude Desktop to load it."
                    } catch {
                        form.claudeDesktopResult = error.localizedDescription
                    }
                }
            }
            if let claudeDesktopResult = form.claudeDesktopResult {
                Text(claudeDesktopResult).foregroundStyle(.secondary)
            }
            LabeledContent("Claude Code") {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ChatConnections.claudeCodeCommand, forType: .string)
                }
            }
            Text(ChatConnections.claudeCodeCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !ChatConnections.isInstalled {
                Text("Move Auxilius to Applications before connecting, so the path chat clients launch stays valid.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Chat")
        } footer: {
            Text("Connected chats get a read_paper tool that shows them your page and its transcript. Any other chat: copy the transcript with ⇧⌘C and paste it.")
                .foregroundStyle(.secondary)
        }
    }

    /// The account's models, plus the current choice in case the list has not loaded or no longer has it.
    private var modelChoices: [ClaudeModel] {
        form.models.contains(session.model) ? form.models : [session.model] + form.models
    }

    private func loadModels() async {
        guard let apiKey = session.apiKey else {
            form.models = []
            form.modelsError = nil
            return
        }

        do {
            form.models = try await ClaudeModel.available(apiKey: apiKey)
            form.modelsError = nil
        } catch {
            form.modelsError = "Could not load models: \(error.localizedDescription)"
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            form.keyError = nil
        } catch {
            form.keyError = error.localizedDescription
        }
    }
}
