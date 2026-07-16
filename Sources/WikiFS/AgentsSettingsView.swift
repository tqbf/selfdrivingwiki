import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Settings → **Agents** tab (Phase 3 of `plans/acp-multi-provider.md`):
/// replaces the old "Agent" + "Providers" tabs with one view over
/// `AgentProvidersConfig` — the editable multi-provider list, per-stage
/// (planner/executor/finalizer) provider/model routing, and the permission
/// mode picker (moved here from the old Agent tab).
///
/// Persists via `AgentProvidersConfig.save(to:)` on every edit — no explicit
/// save step, mirroring `ZoteroSettingsView`/`AgentProvidersSettingsView`.
/// Secrets (API keys) go through `ACPCredentialStore` (Keychain), never into
/// the JSON file.
struct AgentsSettingsView: View {
    @State private var config: AgentProvidersConfig
    @State private var selectedProviderID: String?
    @State private var providerPendingDeletion: AgentProvider?

    @AppStorage(AgentLauncher.permissionModeKey) private var permissionModeRaw = PermissionPolicy.bypass.rawValue

    let containerDirectory: URL
    private let credentialStore: any ACPCredentialStore

    init(
        containerDirectory: URL,
        credentialStore: any ACPCredentialStore = KeychainACPCredentialStore()
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        let loaded = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        _config = State(initialValue: loaded)
        _selectedProviderID = State(initialValue: loaded.providers.first?.id)
    }

    var body: some View {
        Form {
            providersSection
            permissionSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .sheet(item: $editingProvider) { provider in
            ProviderEditorView(
                provider: provider,
                cachedModels: config.cachedModels(forProvider: provider.id),
                selectedModelId: config.selectedModelId(forProvider: provider.id) ?? "",
                credentialStore: credentialStore,
                onSave: { updated, selectedModelId in
                    applyEdit(updated, selectedModelId: selectedModelId)
                })
        }
        .confirmationDialog(
            "Delete \(providerPendingDeletion?.label ?? "provider")?",
            isPresented: isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { providerPendingDeletion = nil }
        } message: {
            Text("This removes its command, environment, and stage assignments. Its API key stays in the Keychain until overwritten.")
        }
    }

    // MARK: - Providers section

    private var providersSection: some View {
        Section {
            List(config.providers, selection: $selectedProviderID) { provider in
                providerRow(provider)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        selectedProviderID = provider.id
                        editingProvider = provider
                    }
            }
            .frame(minHeight: 160, maxHeight: 220)
            .listStyle(.inset)

            HStack {
                Menu {
                    Button("Add Claude") { addSeed(.claudeAcpDefault) }
                    Button("Add Hermes") { addSeed(.hermesDefault) }
                    Button("Add OpenCode") { addSeed(.opencodeDefault) }
                    Divider()
                    Button("Custom…") { addCustom() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    if let provider = selectedProvider {
                        providerPendingDeletion = provider
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedProvider == nil || config.providers.count <= 1)

                Button("Make Default") {
                    if let id = selectedProviderID {
                        save(config.settingDefault(id: id))
                    }
                }
                .disabled(selectedProvider?.isDefault ?? true)

                Spacer()

                Button("Edit…") {
                    if let provider = selectedProvider {
                        editingProvider = provider
                    }
                }
                .disabled(selectedProvider == nil)
            }
        } header: {
            Text("Providers")
        } footer: {
            Text("Double-click a provider to edit its command, environment, API key, and models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func providerRow(_ provider: AgentProvider) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: enabledBinding(for: provider))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.label)
                        .fontWeight(.medium)
                    if provider.isDefault {
                        Text("Default")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(provider.command.map(ShellWords.join) ?? "—")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .tag(provider.id)
    }

    private func enabledBinding(for provider: AgentProvider) -> Binding<Bool> {
        Binding(
            get: { provider.enabled },
            set: { newValue in
                var updated = config
                if let idx = updated.providers.firstIndex(where: { $0.id == provider.id }) {
                    updated.providers[idx].enabled = newValue
                }
                save(AgentProvidersConfig(
                    providers: updated.providers,
                    providerModels: updated.providerModels,
                    selectedModelIds: updated.selectedModelIds,
                    favoriteModelIds: updated.favoriteModelIds,
                    stageAssignments: updated.stageAssignments))
            })
    }

    private var selectedProvider: AgentProvider? {
        guard let id = selectedProviderID else { return nil }
        return config.provider(id: id)
    }

    /// Drives the editor sheet (`sheet(item: $editingProvider)`): set on
    /// double-click, "Edit…", or right after adding a custom provider.
    @State private var editingProvider: AgentProvider?

    /// Merge the editor's saved provider back into `config.providers` (by id)
    /// and persist the model selection alongside it.
    private func applyEdit(_ updated: AgentProvider, selectedModelId: String?) {
        var providers = config.providers
        if let idx = providers.firstIndex(where: { $0.id == updated.id }) {
            // Preserve enabled/isDefault — the editor doesn't own those (the
            // list row's toggle / "Make Default" do).
            var merged = updated
            merged.enabled = providers[idx].enabled
            merged.isDefault = providers[idx].isDefault
            providers[idx] = merged
        } else {
            providers.append(updated)
        }
        save(AgentProvidersConfig(
            providers: providers,
            providerModels: config.providerModels,
            selectedModelIds: config.selectedModelIds,
            favoriteModelIds: config.favoriteModelIds,
            stageAssignments: config.stageAssignments)
            .settingSelectedModel(selectedModelId, forProvider: updated.id))
    }

    // MARK: - Add / delete

    private func addSeed(_ seed: AgentProvider) {
        guard !config.providers.contains(where: { $0.id == seed.id }) else {
            selectedProviderID = seed.id
            return
        }
        var updated = config
        updated.providers.append(seed)
        save(AgentProvidersConfig(
            providers: updated.providers,
            providerModels: updated.providerModels,
            selectedModelIds: updated.selectedModelIds,
            favoriteModelIds: updated.favoriteModelIds,
            stageAssignments: updated.stageAssignments))
        selectedProviderID = seed.id
    }

    private func addCustom() {
        var id = "custom"
        var suffix = 1
        while config.providers.contains(where: { $0.id == id }) {
            suffix += 1
            id = "custom-\(suffix)"
        }
        let blank = AgentProvider(
            id: id,
            label: "Custom Agent",
            command: [],
            env: [:],
            enabled: true,
            isDefault: false)
        var updated = config
        updated.providers.append(blank)
        save(AgentProvidersConfig(
            providers: updated.providers,
            providerModels: updated.providerModels,
            selectedModelIds: updated.selectedModelIds,
            favoriteModelIds: updated.favoriteModelIds,
            stageAssignments: updated.stageAssignments))
        selectedProviderID = id
        editingProvider = blank
    }

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { providerPendingDeletion != nil },
            set: { if !$0 { providerPendingDeletion = nil } })
    }

    private func confirmDelete() {
        guard let provider = providerPendingDeletion else { return }
        var updated = config
        updated.providers.removeAll { $0.id == provider.id }
        // Re-running init() re-normalizes (promotes a new default if the
        // deleted one was default) and prunes now-orphaned stage assignments.
        save(AgentProvidersConfig(
            providers: updated.providers,
            providerModels: updated.providerModels,
            selectedModelIds: updated.selectedModelIds,
            favoriteModelIds: updated.favoriteModelIds,
            stageAssignments: updated.stageAssignments))
        if selectedProviderID == provider.id {
            selectedProviderID = config.providers.first?.id
        }
        providerPendingDeletion = nil
    }

    // MARK: - Permission mode (moved from the old Agent tab)

    private var permissionSection: some View {
        Section {
            Picker("Permission Mode", selection: $permissionModeRaw) {
                ForEach(PermissionPolicy.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Applies to every ACP provider. Bypass (default) applies writes automatically; the other modes gate them behind approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Persistence

    private func save(_ updated: AgentProvidersConfig) {
        config = updated
        try? config.save(to: containerDirectory)
    }
}

// MARK: - Provider editor

/// The provider editor sheet: label, command (parsed via `ShellWords`), env
/// vars, API key, and the model picker fed from captured models. Saves back to
/// the parent's config via `onSave` — this view owns no persistence itself.
private struct ProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let originalID: String
    @State private var label: String
    @State private var commandText: String
    @State private var envRows: [EnvRow]
    @State private var apiKey: String
    @State private var selectedModelId: String
    @State private var isAvailable: Bool = false

    let cachedModels: [CachedModelInfo]
    let credentialStore: any ACPCredentialStore
    let onSave: (AgentProvider, String?) -> Void

    private struct EnvRow: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(
        provider: AgentProvider,
        cachedModels: [CachedModelInfo],
        selectedModelId: String,
        credentialStore: any ACPCredentialStore,
        onSave: @escaping (AgentProvider, String?) -> Void
    ) {
        self.originalID = provider.id
        self._label = State(initialValue: provider.label)
        self._commandText = State(initialValue: provider.command.map(ShellWords.join) ?? "")
        self._envRows = State(initialValue: provider.env
            .sorted(by: { $0.key < $1.key })
            .map { EnvRow(key: $0.key, value: $0.value) })
        self._apiKey = State(initialValue: "")
        self._selectedModelId = State(initialValue: selectedModelId)
        self.cachedModels = cachedModels
        self.credentialStore = credentialStore
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Label", text: $label)
                    TextField("Command", text: $commandText, prompt: Text("hermes acp"))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isAvailable ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(isAvailable ? "Executable found on PATH" : "Not found on PATH")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Command")
                } footer: {
                    Text("A single command line, e.g. bun x @agentclientprotocol/claude-agent-acp. Quote arguments containing spaces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach($envRows) { $row in
                        HStack {
                            TextField("KEY", text: $row.key)
                                .fontDesign(.monospaced)
                                .frame(maxWidth: 160)
                            TextField("value", text: $row.value)
                                .fontDesign(.monospaced)
                            Button {
                                envRows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        envRows.append(EnvRow(key: "", value: ""))
                    } label: {
                        Label("Add Variable", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Environment")
                } footer: {
                    Text("Non-secret configuration only — API keys and other secrets belong in the field below, never here (this list is stored in plain JSON).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    SecureField("API Key", text: $apiKey, prompt: Text("optional"))
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Stored in the macOS Keychain, never in the provider's JSON config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Model", selection: $selectedModelId) {
                        Text("Provider default").tag("")
                        ForEach(cachedModels) { model in
                            Text(model.name).tag(model.modelId)
                        }
                    }
                    HStack {
                        Button("Refresh Models") {
                            // No-op: model discovery only happens on a live
                            // ACP session/new response (see AgentLauncher /
                            // ACPBackend), which this editor cannot spin up
                            // without a wiki context. Left disabled with a
                            // tooltip explaining why — wiring a real refresh
                            // here is a follow-up once that path is exposed
                            // outside the launcher.
                        }
                        .disabled(true)
                        .help("Models are captured automatically the first time you chat with this provider.")
                        Spacer()
                        if cachedModels.isEmpty {
                            Text("No models captured yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Model")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear {
            apiKey = credentialStore.apiKey(forProvider: originalID) ?? ""
            refreshAvailability()
        }
    }

    private func refreshAvailability() {
        let words = ShellWords.split(commandText)
        let exe = words.first ?? ""
        guard !exe.isEmpty else {
            isAvailable = false
            return
        }
        Task {
            let result = await Task.detached { PathPreflight.resolveOnLoginShell(executable: exe) }.value
            await MainActor.run {
                isAvailable = if case .found = result { true } else { false }
            }
        }
    }

    private func save() {
        var env: [String: String] = [:]
        for row in envRows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            env[key] = row.value
        }
        let command = ShellWords.split(commandText)
        let updated = AgentProvider(
            id: originalID,
            label: label.trimmingCharacters(in: .whitespaces),
            command: command.isEmpty ? nil : command,
            env: env,
            enabled: true,
            isDefault: false)
        try? credentialStore.setAPIKey(apiKey.isEmpty ? nil : apiKey, forProvider: originalID)
        onSave(updated, selectedModelId.isEmpty ? nil : selectedModelId)
        dismiss()
    }
}
