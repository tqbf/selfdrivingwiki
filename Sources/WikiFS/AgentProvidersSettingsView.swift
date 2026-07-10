import SwiftUI
import WikiFSCore

/// Settings → Providers tab (#324): a native macOS provider manager modeled on
/// paseo's `providers-section.tsx` + `provider-catalog-list.tsx` +
/// `provider-diagnostic-sheet.tsx`. Three pieces, all native `Form`/grouped:
///
/// 1. **Providers list** — each configured provider (Claude default + ACP
///    providers) shown with a status badge (available = binary on PATH), an
///    enable toggle, a default radio selector, and a "details" disclosure.
/// 2. **Add Provider** — a searchable catalog sheet of `ACPProviderCatalog.agents`
///    not yet added; one-click Add creates the provider config.
/// 3. **Per-provider detail** — command (editable), env, a `SecureField` API key
///    (Keychain via `ACPCredentialStore`, keyed by provider id — NEVER plain
///    text), enable, set-default.
///
/// Persists to `agent-providers.json` (via `AgentProvidersConfig`) on every edit.
/// Secrets go through `ACPCredentialStore`. Default = Claude; existing users see
/// no behavior change.
struct AgentProvidersSettingsView: View {
    @State private var config: AgentProvidersConfig
    @State private var showCatalog = false
    @State private var selectedDetailID: String?

    /// Cache of binary-on-PATH status per provider (available / not installed),
    /// keyed by the executable to resolve. Refreshed on appear + on demand.
    @State private var availability: [String: Bool] = [:]
    @State private var isRefreshing = false

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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                providersSection
                addProviderSection
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Refresh status") { refreshAvailability() }
                    .disabled(isRefreshing)
                Spacer()
                Button("Add Provider…") { showCatalog = true }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 480, minHeight: 420)
        .sheet(isPresented: $showCatalog) {
            ProviderCatalogSheet(
                addedIDs: Set(config.providers.map(\.id)),
                onAdd: { agent in addProvider(agent) })
        }
        .sheet(item: Binding(
            get: { selectedDetailID.flatMap { id in config.provider(id: id).map(ProviderDetailItem.init) } },
            set: { selectedDetailID = $0?.id }
        )) { item in
            if let idx = config.providers.firstIndex(where: { $0.id == item.id }) {
                ProviderDetailSheet(
                    provider: $config.providers[idx],
                    isAvailable: availability[executableToResolve(for: config.providers[idx])] ?? false,
                    credentialStore: credentialStore,
                    onChange: persist
                )
            }
        }
        .onAppear { refreshAvailability() }
    }

    // MARK: - Providers list

    @ViewBuilder
    private var providersSection: some View {
        Section {
            ForEach(config.providers) { provider in
                ProviderRow(
                    provider: provider,
                    isAvailable: availability[executableToResolve(for: provider)] ?? false,
                    onToggleEnabled: { enabled in toggleEnabled(id: provider.id, enabled: enabled) },
                    onShowDetail: { selectedDetailID = provider.id }
                )
            }
            defaultPicker
        } header: {
            Text("Providers")
        } footer: {
            Text("The default provider is used for new agent sessions. Available means the agent's command is on your PATH. ACP providers add a write-permission gate; the Claude CLI backend has none.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Mutually-exclusive default selection, native macOS radio-group idiom.
    @ViewBuilder
    private var defaultPicker: some View {
        Picker("Default provider", selection: Binding(
            get: { config.defaultProvider.id },
            set: { newID in setDefault(id: newID) }
        )) {
            ForEach(config.providers.filter(\.enabled)) { p in
                Text(p.label).tag(p.id)
            }
        }
        .pickerStyle(.radioGroup)
    }

    // MARK: - Add provider section

    @ViewBuilder
    private var addProviderSection: some View {
        Section {
            Button {
                showCatalog = true
            } label: {
                Label("Add Provider…", systemImage: "plus.circle")
            }
        } footer: {
            Text("Browse known ACP-capable agents. Claude is the built-in default and is not in the catalog.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mutations

    private func addProvider(_ agent: KnownACPAgent) {
        guard !config.providers.contains(where: { $0.id == agent.id }) else { return }
        config.providers.append(.acp(from: agent))
        persist()
        refreshAvailability()
    }

    private func toggleEnabled(id: String, enabled: Bool) {
        guard let idx = config.providers.firstIndex(where: { $0.id == id }) else { return }
        config.providers[idx].enabled = enabled
        persist()
    }

    private func setDefault(id: String) {
        config = config.settingDefault(id: id)
        persist()
    }

    private func persist() {
        try? AgentProvidersConfig(providers: config.providers).save(to: containerDirectory)
    }

    // MARK: - Availability

    /// The executable name to PATH-resolve for a provider (the command's first
    /// element, or "claude" for the CLI backend). Used as the availability key.
    private func executableToResolve(for provider: AgentProvider) -> String {
        switch provider.backend {
        case .claudeCLI:
            return "claude"
        case .acp:
            return provider.command?.first ?? ""
        }
    }

    /// Resolve each provider's binary on the login-shell PATH off the main actor
    /// (the resolver does a real `zsh -lc` hop). Results land on the main actor.
    private func refreshAvailability() {
        let executables = Array(Set(config.providers.map { executableToResolve(for: $0) }.filter { !$0.isEmpty }))
        isRefreshing = true
        Task {
            var results: [String: Bool] = [:]
            for exe in executables {
                let result = await Task.detached { PathPreflight.resolveOnLoginShell(executable: exe) }.value
                if case .found = result { results[exe] = true } else { results[exe] = false }
            }
            await MainActor.run {
                availability = results
                isRefreshing = false
            }
        }
    }
}

// MARK: - Provider row

/// One row in the providers list: name + status badge + enable toggle + default
/// radio + details disclosure. Mirrors paseo's `ProviderRow` (icon/name/status/
/// enable/details) in native macOS idioms.
private struct ProviderRow: View {
    let provider: AgentProvider
    let isAvailable: Bool
    let onToggleEnabled: (Bool) -> Void
    let onShowDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                providerIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.label).font(.body).fontWeight(.medium)
                        if provider.isDefault {
                            Text("Default")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.18), in: Capsule())
                        }
                    }
                    StatusBadge(provider: provider, isAvailable: isAvailable)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { provider.enabled },
                    set: { newValue in onToggleEnabled(newValue) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Enable or disable this provider")
                Button("Details", systemImage: "info.circle") { onShowDetail() }
                    .buttonStyle(.borderless)
                    .help("Edit this provider")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var providerIcon: some View {
        Image(systemName: iconName)
            .font(.title3)
            .foregroundStyle(provider.backend == .claudeCLI ? .purple : .blue)
            .frame(width: 24)
    }

    private var iconName: String {
        switch provider.backend {
        case .claudeCLI: return "terminal.fill"
        case .acp: return "cpu"
        }
    }
}

// MARK: - Status badge

/// The provider status indicator (available / not installed / disabled), modeled
/// on paseo's `StatusIndicator` (dot + label). Native macOS color tokens.
private struct StatusBadge: View {
    let provider: AgentProvider
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 7, height: 7)
            Text(tone.label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tone: (label: String, color: Color) {
        if !provider.enabled { return ("Disabled", .secondary) }
        if provider.backend == .claudeCLI { return ("Available", .green) }
        return isAvailable ? ("Available", .green) : ("Not installed", .orange)
    }
}

// MARK: - Catalog sheet (Add Provider)

/// The searchable catalog of known ACP agents not yet added (mirrors paseo's
/// `ProviderCatalogList`). One-click Add appends a provider config; hides
/// already-added agents.
private struct ProviderCatalogSheet: View {
    let addedIDs: Set<String>
    let onAdd: (KnownACPAgent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var available: [KnownACPAgent] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return ACPProviderCatalog.agents
            .filter { !addedIDs.contains($0.id) }
            .filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Provider").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)

            TextField("Search agents", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if available.isEmpty {
                Text("No agents match.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(available) { agent in
                    CatalogRow(agent: agent, onAdd: {
                        onAdd(agent)
                    })
                }
            }
        }
        .frame(width: 460, height: 480)
    }
}

private struct CatalogRow: View {
    let agent: KnownACPAgent
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label).font(.body).fontWeight(.medium)
                Text(agent.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(agent.command.joined(separator: " "))
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Add", systemImage: "plus", action: onAdd)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Provider detail sheet

/// Per-provider editor (mirrors paseo's `provider-diagnostic-sheet`): command
/// (editable), env, a `SecureField` API key (Keychain, per provider id), enable,
/// set-default. NEVER writes the key to the JSON config.
private struct ProviderDetailSheet: View {
    @Binding var provider: AgentProvider
    let isAvailable: Bool
    let credentialStore: any ACPCredentialStore
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var commandText: String = ""
    @State private var envText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(provider.label).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)

            Form {
                Section {
                    LabeledContent("Status") {
                        statusLabel
                    }
                    if provider.backend == .acp {
                        LabeledContent("Backend") {
                            Text("ACP (Agent Client Protocol)")
                        }
                        LabeledContent("Executable") {
                            executableLabel
                        }
                    } else {
                        LabeledContent("Backend") { Text("Claude CLI (claude -p)") }
                    }
                }

                if provider.backend == .acp {
                    Section {
                        TextField("Command", text: $commandText, prompt: Text("e.g. gemini --acp"))
                            .fontDesign(.monospaced)
                            .disabled(provider.id == "claude")
                    } header: {
                        Text("Command")
                    } footer: {
                        Text("The ACP spawn argv. The first token is PATH-resolved at spawn time. Editing this overrides the catalog default.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section {
                        SecureField("API Key", text: $apiKey, prompt: Text("optional"))
                    } header: {
                        Text("Authentication")
                    } footer: {
                        Text("Stored in the macOS Keychain, keyed by provider id — never written to the config file. Leave blank if the agent needs none.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $provider.enabled)
                    if provider.isDefault {
                        Text("This is the default provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use the radio group in the Providers list to change the default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 440, minHeight: 460)
        .onAppear {
            commandText = provider.command?.joined(separator: " ") ?? ""
            apiKey = credentialStore.apiKey(forProvider: provider.id) ?? ""
        }
        .onChange(of: commandText) { _, _ in
            if provider.backend == .acp {
                provider.command = AgentCommandConfig.tokenize(commandText).filter { !$0.isEmpty }
                onChange()
            }
        }
        .onChange(of: apiKey) { _, newValue in
            try? credentialStore.setAPIKey(newValue.isEmpty ? nil : newValue, forProvider: provider.id)
        }
        .onChange(of: provider.enabled) { _, _ in onChange() }
    }

    private var statusText: String {
        if !provider.enabled { return "Disabled" }
        if provider.backend == .claudeCLI { return "Available" }
        return isAvailable ? "Available" : "Not installed"
    }

    private var statusColor: Color {
        if !provider.enabled { return .secondary }
        if provider.backend == .claudeCLI { return .green }
        return isAvailable ? .green : .orange
    }

    private var statusLabel: some View {
        Text(statusText)
            .foregroundStyle(statusColor)
    }

    private var executableLabel: some View {
        let exe = provider.command?.first ?? "—"
        return Text(exe)
            .font(.body)
            .fontDesign(.monospaced)
    }
}

/// Wrapper so `AgentProvider` (already `Identifiable`) can drive a `.sheet(item:)`
/// binding from an optional id without a separate selection type.
private struct ProviderDetailItem: Identifiable {
    let id: String
    init(_ provider: AgentProvider) { self.id = provider.id }
}
