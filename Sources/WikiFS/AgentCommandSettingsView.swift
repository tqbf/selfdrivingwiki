import SwiftUI
import WikiFSCore

/// Settings → Agent tab: configure the agent executable, prefix arguments,
/// model override, and extra environment variables.
/// Mirrors `ZoteroSettingsView`: a `Form` whose fields persist immediately via
/// `.onChange(of:)` — no explicit save step, so a value is never lost when the
/// Settings window closes.
struct AgentCommandSettingsView: View {
    @State private var executable: String
    @State private var prefixArguments: String
    @State private var modelOverride: String
    @State private var extraEnvironment: String
    @State private var sandboxEnabled: Bool

    let containerDirectory: URL

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        let config = AgentCommandConfig.load(from: containerDirectory)
        _executable = State(initialValue: config.executable)
        _prefixArguments = State(initialValue: config.prefixArguments)
        _modelOverride = State(initialValue: config.modelOverride)
        _extraEnvironment = State(initialValue: config.extraEnvironment)
        _sandboxEnabled = State(initialValue: SandboxConfig.load(from: containerDirectory).enabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Executable", text: $executable, prompt: Text("claude"))
                    TextField("Prefix arguments", text: $prefixArguments)
                    TextField("Model override", text: $modelOverride, prompt: Text("default (per-op alias)"))
                } header: {
                    Text("Command")
                }

                Section {
                    TextEditor(text: $extraEnvironment)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 64)
                } header: {
                    Text("Extra Environment")
                } footer: {
                    Text("KEY=VALUE, one per line. WIKI_ROOT and WIKI_DB are always set by the app and cannot be overridden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Run agent in sandbox", isOn: $sandboxEnabled)
                } header: {
                    Text("Sandbox")
                } footer: {
                    Text("When on, the main agent and Edit sessions run under a seatbelt that confines writes to the wiki DB and scratch directory (plus ~/.claude). The Ask session is always read-only sandboxed regardless of this setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Reset to Default") { resetToDefault() }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .onChange(of: executable) { _, _ in saveCommand() }
        .onChange(of: prefixArguments) { _, _ in saveCommand() }
        .onChange(of: modelOverride) { _, _ in saveCommand() }
        .onChange(of: extraEnvironment) { _, _ in saveCommand() }
        .onChange(of: sandboxEnabled) { _, _ in saveSandbox() }
    }

    // MARK: - Actions

    private func saveCommand() {
        let config = AgentCommandConfig(
            executable: executable,
            prefixArguments: prefixArguments,
            modelOverride: modelOverride,
            extraEnvironment: extraEnvironment)
        try? config.save(to: containerDirectory)
    }

    private func saveSandbox() {
        // Load fresh to PRESERVE extraAllowedPaths — we only mutate `enabled` here.
        // Safe because this view is currently the sole writer of sandbox-config.json;
        // revisit if an extraAllowedPaths editor is added. A corrupt file degrades to
        // .default (empty paths), which is accepted.
        var config = SandboxConfig.load(from: containerDirectory)
        config.enabled = sandboxEnabled
        // try? is deliberate: the view has no error-reporting surface. Matches saveCommand().
        try? config.save(to: containerDirectory)
    }

    private func resetToDefault() {
        let cmdDefaults = AgentCommandConfig.default
        executable = cmdDefaults.executable
        prefixArguments = cmdDefaults.prefixArguments
        modelOverride = cmdDefaults.modelOverride
        extraEnvironment = cmdDefaults.extraEnvironment
        saveCommand()
        // Also reset the sandbox toggle so "Reset to Default" is fully consistent.
        sandboxEnabled = SandboxConfig.default.enabled
        // Explicit save mirrors saveCommand() above: persistence-on-reset is
        // unconditional regardless of .onChange timing. The .onChange(of: sandboxEnabled)
        // would also fire and call saveSandbox(), but the explicit call here is
        // intentional — do not remove it as "redundant".
        saveSandbox()
    }
}
