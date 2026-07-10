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

    /// Slice 3: dedicated ACP agent config (separate from the Claude-CLI config
    /// above). Shown only when `useACPBackend` is on. The API key is backed by
    /// Keychain (via `ACPCredentialStore`), not UserDefaults — so it has its own
    /// `@State` draft + `onChange` persist, mirroring ZoteroSettingsView's key.
    @State private var acpExecutable: String
    @State private var acpPrefixArguments: String
    @State private var acpModelOverride: String
    @State private var acpExtraEnvironment: String
    @State private var acpAPIKey: String

    let containerDirectory: URL
    /// Injectable for previews/tests; defaults to the Keychain-backed store.
    private let credentialStore: any ACPCredentialStore

    init(
        containerDirectory: URL,
        credentialStore: any ACPCredentialStore = KeychainACPCredentialStore()
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        let config = AgentCommandConfig.load(from: containerDirectory)
        _executable = State(initialValue: config.executable)
        _prefixArguments = State(initialValue: config.prefixArguments)
        _modelOverride = State(initialValue: config.modelOverride)
        _extraEnvironment = State(initialValue: config.extraEnvironment)
        let acp = ACPAgentConfig.load(from: containerDirectory)
        _acpExecutable = State(initialValue: acp.executable)
        _acpPrefixArguments = State(initialValue: acp.prefixArguments)
        _acpModelOverride = State(initialValue: acp.modelOverride)
        _acpExtraEnvironment = State(initialValue: acp.extraEnvironment)
        _acpAPIKey = State(initialValue: credentialStore.apiKey() ?? "")
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
                    Text("The Claude CLI command (used when the ACP backend is off).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Use ACP backend", isOn: $useACPBackend)
                } header: {
                    Text("Backend")
                } footer: {
                    Text("Off (default): the Claude CLI backend — writes apply with no review. On: launch the agent over ACP, which adds a structural always-ask / yolo permission gate for writes. Requires a configured ACP agent below. Live approval is only possible with an agent that emits request_permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if useACPBackend {
                    Section {
                        TextField("Executable", text: $acpExecutable, prompt: Text("npx"))
                        TextField("Arguments", text: $acpPrefixArguments)
                        TextField("Model override", text: $acpModelOverride, prompt: Text("default (agent-chosen)"))
                    } header: {
                        Text("ACP Agent")
                    } footer: {
                        Text("The ACP agent to launch over JSON-RPC/stdio (e.g. executable `npx`, arguments `--yes @agentclientprotocol/claude-agent-acp`). Configured separately from the Claude CLI command above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        SecureField("API Key", text: $acpAPIKey, prompt: Text("optional (some agents need none)"))
                    } header: {
                        Text("ACP Authentication")
                    } footer: {
                        Text("Stored in the macOS Keychain — never written to disk as plain text. Leave blank if the agent advertises no auth methods.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .onChange(of: acpExecutable) { _, _ in saveACPCommand() }
        .onChange(of: acpPrefixArguments) { _, _ in saveACPCommand() }
        .onChange(of: acpModelOverride) { _, _ in saveACPCommand() }
        .onChange(of: acpAPIKey) { _, _ in saveACPKey() }
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

    /// Persist the ACP agent config (plain prefs only — the key is separate).
    private func saveACPCommand() {
        let config = ACPAgentConfig(
            executable: acpExecutable,
            prefixArguments: acpPrefixArguments,
            modelOverride: acpModelOverride,
            extraEnvironment: "")
        try? config.save(to: containerDirectory)
    }

    /// Persist the API key through the Keychain-backed store (never plain disk).
    private func saveACPKey() {
        try? credentialStore.setAPIKey(acpAPIKey.isEmpty ? nil : acpAPIKey)
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
