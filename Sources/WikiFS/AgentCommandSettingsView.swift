import AppKit
import SwiftUI
import WikiFSCore

/// Settings → Agent tab: configure the agent executable, prefix arguments,
/// model override, and extra environment variables. Mirrors `ZoteroSettingsView`
/// in structure: `Form` + `.formStyle(.grouped)`, explicit Save button in the
/// form (not the toolbar), no height constraint.
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
        Form {
            Section {
                TextField("Executable", text: $executable, prompt: Text("claude"))
                TextField("Prefix arguments", text: $prefixArguments)
                TextField("Model override", text: $modelOverride, prompt: Text("default (per-op alias)"))
            } header: {
                Text("Command")
            } footer: {
                Text("Executable is resolved on the login-shell PATH. Use an absolute path, ./relative/path, or ~/path to pin a specific binary. Prefix arguments are inserted before the standard flags (e.g. sandbox-exec -f profile.sb claude).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $extraEnvironment)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
            } header: {
                Text("Extra Environment")
            } footer: {
                Text("KEY=VALUE, one per line. WIKI_ROOT and WIKI_DB are always set by the app and cannot be overridden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(resolvedPreview.isEmpty ? "—" : resolvedPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Resolved Preview")
            }

            Section {
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
        }
        .formStyle(.grouped)
        .frame(width: Metrics.width)
        .onAppear { updatePreview() }
    }

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
        static let width: CGFloat = 460
    }
}
