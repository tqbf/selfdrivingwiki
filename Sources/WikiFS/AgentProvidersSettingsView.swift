import SwiftUI
import WikiFSCore

/// Settings → Providers tab: shows the single configured provider (Claude via
/// ACP). No add-provider catalog, no default picker (single provider), no
/// enable toggle. Just the provider's status + command + optional API key.
///
/// Persists to `agent-providers.json` (via `AgentProvidersConfig`). Secrets go
/// through `ACPCredentialStore` (Keychain).
struct AgentProvidersSettingsView: View {
    @State private var config: AgentProvidersConfig
    @State private var apiKey: String = ""
    @State private var isAvailable: Bool = false

    let containerDirectory: URL
    private let credentialStore: any ACPCredentialStore

    init(
        containerDirectory: URL,
        credentialStore: any ACPCredentialStore = KeychainACPCredentialStore()
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        _config = State(initialValue: AgentProvidersConfig.loadOrSeed(from: containerDirectory))
    }

    private var provider: AgentProvider {
        config.selectedProvider()
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Provider") {
                    Text(provider.label)
                        .font(.body)
                        .fontWeight(.medium)
                }
                LabeledContent("Backend") {
                    Text("ACP (Agent Client Protocol)")
                }
                LabeledContent("Status") {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isAvailable ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(isAvailable ? "Available" : "Not installed")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Executable") {
                    Text(provider.command?.first ?? "—")
                        .font(.body)
                        .fontDesign(.monospaced)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Runs via the bundled bun runtime + the official ACP wrapper (@agentclientprotocol/claude-agent-acp). No system-wide install required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("API Key", text: $apiKey, prompt: Text("optional"))
                    .onChange(of: apiKey) { _, newValue in
                        try? credentialStore.setAPIKey(
                            newValue.isEmpty ? nil : newValue,
                            forProvider: provider.id)
                    }
            } header: {
                Text("Authentication")
            } footer: {
                Text("Stored in the macOS Keychain. Leave blank — Claude authenticates via its own OAuth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            apiKey = credentialStore.apiKey(forProvider: provider.id) ?? ""
            refreshAvailability()
        }
    }

    // MARK: - Availability

    private func refreshAvailability() {
        let exe = provider.command?.first ?? "bun"
        Task {
            let result = await Task.detached { PathPreflight.resolveOnLoginShell(executable: exe) }.value
            await MainActor.run {
                isAvailable = if case .found = result { true } else { false }
            }
        }
    }
}
