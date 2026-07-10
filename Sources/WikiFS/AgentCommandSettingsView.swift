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
    /// Opt-in: use the ACP (Agent Client Protocol) backend instead of the Claude
    /// CLI. Default OFF — preserves today's behavior exactly. ON launches the
    /// configured agent (executable + prefix args) as an ACP agent over JSON-RPC,
    /// enabling the structural always-ask/yolo write-permission gate.
    @AppStorage(AgentLauncher.useACPBackendKey) private var useACPBackend = false

    let containerDirectory: URL

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        let config = AgentCommandConfig.load(from: containerDirectory)
        _executable = State(initialValue: config.executable)
        _prefixArguments = State(initialValue: config.prefixArguments)
        _modelOverride = State(initialValue: config.modelOverride)
        _extraEnvironment = State(initialValue: config.extraEnvironment)
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
                } footer: {
                    if useACPBackend {
                        Text("ACP backend is ON — the executable and prefix arguments above launch the ACP agent (e.g. executable `npx`, prefix arguments `--yes @agentclientprotocol/claude-agent-acp`).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("The Claude CLI command. When the ACP backend is on, these same fields launch the ACP agent instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Use ACP backend", isOn: $useACPBackend)
                } header: {
                    Text("Backend")
                } footer: {
                    Text("Off (default): the Claude CLI backend — writes apply with no review. On: launch the agent over ACP, which adds a structural always-ask / yolo permission gate for writes. Requires a configured ACP agent above. Live approval is only possible with an agent that emits request_permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $extraEnvironment)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 64)
                } header: {
                    Text("Extra Environment")
                } footer: {
                    Text("bash-style, one per line. `export KEY=VALUE` and `$VAR` / `${VAR}` expansion are supported (single quotes are taken literally). WIKI_ROOT and WIKI_DB are always set by the app and cannot be overridden.")
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

    private func resetToDefault() {
        let cmdDefaults = AgentCommandConfig.default
        executable = cmdDefaults.executable
        prefixArguments = cmdDefaults.prefixArguments
        modelOverride = cmdDefaults.modelOverride
        extraEnvironment = cmdDefaults.extraEnvironment
        saveCommand()
    }
}
