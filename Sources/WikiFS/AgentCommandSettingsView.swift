import AppKit
import SwiftUI
import WikiFSCore

/// Settings → Agent tab: configure the agent executable, prefix arguments,
/// model override, and extra environment variables. Mirrors `ZoteroSettingsView`
/// in structure: `Form` + `.formStyle(.grouped)`, explicit Save button in the
/// form (not the toolbar), resolved preview alongside the fields.
struct AgentCommandSettingsView: View {
    @State private var executable: String
    @State private var prefixArguments: String
    @State private var modelOverride: String
    @State private var extraEnvironment: String
    @State private var resolvedPreview: String = ""

    let containerDirectory: URL
    @Environment(\.dismiss) private var dismiss

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        let config = AgentCommandConfig.load(from: containerDirectory)
        _executable = State(initialValue: config.executable)
        _prefixArguments = State(initialValue: config.prefixArguments)
        _modelOverride = State(initialValue: config.modelOverride)
        _extraEnvironment = State(initialValue: config.extraEnvironment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                fieldsForm
                previewForm
            }
            buttonsBar
                .padding(.top, 8)
        }
        .padding([.horizontal, .top])
        .frame(width: Metrics.width)
        .onAppear { updatePreview() }
    }

    // MARK: - Fields (left column)

    private var fieldsForm: some View {
        Form {
            Section {
                TextField("Executable", text: $executable, prompt: Text("claude"))
                    .onChange(of: executable) { _, _ in updatePreview() }
                TextField("Prefix arguments", text: $prefixArguments)
                    .onChange(of: prefixArguments) { _, _ in updatePreview() }
                TextField("Model override", text: $modelOverride, prompt: Text("default (per-op alias)"))
                    .onChange(of: modelOverride) { _, _ in updatePreview() }
            } header: {
                Text("Command")
            }

            Section {
                TextEditor(text: $extraEnvironment)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .onChange(of: extraEnvironment) { _, _ in updatePreview() }
            } header: {
                Text("Extra Environment")
            } footer: {
                Text("KEY=VALUE, one per line. WIKI_ROOT and WIKI_DB are always set by the app and cannot be overridden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Preview (right column)

    private var previewForm: some View {
        Form {
            Section {
                Text(resolvedPreview.isEmpty ? "—" : resolvedPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Resolved Command")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Buttons

    private var buttonsBar: some View {
        HStack {
            Button("Reset to Default") {
                executable = "claude"
                prefixArguments = ""
                modelOverride = ""
                extraEnvironment = ""
                updatePreview()
            }
            Spacer()
            Button("Save") { saveAndClose() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func updatePreview() {
        let config = AgentCommandConfig(
            executable: executable,
            prefixArguments: prefixArguments,
            modelOverride: modelOverride,
            extraEnvironment: extraEnvironment)
        let args = config.tokenizedPrefixArgs()
        let model = config.modelOverride.isEmpty ? "opus" : config.modelOverride
        let argv = args + ["-p", "<prompt>", "--model", model, "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--append-system-prompt", "<system-prompt>", "--dangerously-skip-permissions"]
        let cmd = ([config.resolvedExecutable()] + argv)
            .map(ClaudePromptHelp.shellQuoted)
            .joined(separator: " \\\n  ")
        resolvedPreview = cmd
    }

    private func saveAndClose() {
        let config = AgentCommandConfig(
            executable: executable,
            prefixArguments: prefixArguments,
            modelOverride: modelOverride,
            extraEnvironment: extraEnvironment)
        try? config.save(to: containerDirectory)
        dismiss()
        NSApp.keyWindow?.close()
    }

    private enum Metrics {
        static let width: CGFloat = 700
    }
}
