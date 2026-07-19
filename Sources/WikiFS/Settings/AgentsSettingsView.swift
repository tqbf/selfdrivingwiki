import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Settings → **Agents** tab (Phase 3 of `plans/acp-multi-provider.md`):
/// replaces the old "Agent" + "Providers" tabs with one view over
/// `AgentProvidersConfig` — the editable multi-provider list and the permission
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

    @AppStorage(AgentLauncher.PermissionModeKey.chat)   private var chatModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.ingest) private var ingestModeRaw = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.lint)   private var lintModeRaw   = PermissionPolicy.bypass.rawValue

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
                },
                onRefreshModels: { provider, models in
                    // #640: durable-persist path for probe-discovered models.
                    // Runs on the parent (which owns `containerDirectory` +
                    // `@State config`). Uses `settingCachedModels` directly so
                    // ALL existing fields carry over (maxConcurrent in
                    // particular — the parent's `save(_:)` helper drops it,
                    // pre-existing bug at AgentsSettingsView.swift:250-255,
                    // :360-362). `@Sendable` so the sheet's `Task` can call
                    // it across actors.
                    await persistDiscoveredModels(models, forProvider: provider.id)
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
            Text("This removes its command and environment. Its API key stays in the Keychain until overwritten.")
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
                // Orange "no model picked" caption. The launcher now refuses to
                // spawn without an explicit `selectedModelId` (see
                // `SpawnModelGuard`), so surface the missing selection here.
                // NON-BLOCKING — models are discovered live on first spawn
                // (`AgentsSettingsView`'s editor comment at line ~503), so we
                // let the user save a provider without a model and just remind
                // them to pick one before running. Disabled providers show no
                // caption (they can't spawn anyway).
                if let warning = Self.modelWarning(for: provider, in: config) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .tag(provider.id)
    }

    /// Returns a warning string when `provider` is enabled, has no selected
    /// model, and the launcher will therefore refuse to spawn it (see
    /// `SpawnModelGuard`). Returns `nil` for disabled providers (they can't
    /// spawn anyway) and providers with a selected model.
    ///
    /// Two warning shapes:
    /// - When the provider has cached models to pick from → the user must
    ///   pick one before running ("No model selected — pick one before running.").
    /// - When the provider has no cached models yet → the editor's
    ///   "No models captured yet" caption and the launcher need a first
    ///   successful spawn to capture them; surface a gentle guidance line
    ///   ("No model captured yet — chat with this provider once to discover
    ///   models."). The launcher will still refuse spawn in this state — that
    ///   is an accepted UX wrinkle tracked in `PROGRESS.md` (a future
    ///   dry-run `session/new` on Save would close it).
    ///
    /// PURE + STATIC so it can be unit-tested without rendering. The row reads
    /// the same `config` source the view stores in its `@State`, so passing it
    /// in as a parameter captures the identical value the row would render.
    ///
    /// `nonisolated`: a SwiftUI `View` is implicitly `@MainActor`, but this
    /// helper touches no view state — only the pure `AgentProvidersConfig`
    /// argument. Marking it `nonisolated` lets the test suite call it
    /// synchronously (without `@MainActor`) while the row's call site
    /// (`Self.modelWarning(for:in:)`) continues to work identically.
    nonisolated static func modelWarning(for provider: AgentProvider, in config: AgentProvidersConfig) -> String? {
        guard provider.enabled else { return nil }
        let modelId = config.selectedModelId(forProvider: provider.id)
        if let modelId, !modelId.isEmpty { return nil }
        let models = config.cachedModels(forProvider: provider.id)
        if models.isEmpty {
            return "No model captured yet — chat with this provider once to discover models."
        }
        return "No model selected — pick one before running."
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
                    favoriteModelIds: updated.favoriteModelIds))
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
            favoriteModelIds: config.favoriteModelIds)
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
            favoriteModelIds: updated.favoriteModelIds))
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
            favoriteModelIds: updated.favoriteModelIds))
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
        // Re-running init() re-normalizes: promotes a new default if the
        // deleted one was default.
        save(AgentProvidersConfig(
            providers: updated.providers,
            providerModels: updated.providerModels,
            selectedModelIds: updated.selectedModelIds,
            favoriteModelIds: updated.favoriteModelIds))
        if selectedProviderID == provider.id {
            selectedProviderID = config.providers.first?.id
        }
        providerPendingDeletion = nil
    }

    // MARK: - Permission mode (moved from the old Agent tab)

    /// #607: per-operation permission pickers. Pre-split, a single shared
    /// `agentPermissionMode` key fed chat + ingest + lint — a user who chose
    /// `alwaysAsk` for chat got the same gating applied to an unattended
    /// ingest/lint, guaranteeing a stall on the first prompt needing a
    /// permission (#606). Now three independent pickers. Extraction is
    /// intentionally omitted — see `plans/acp-permissions.md` §5.1 (extraction
    /// keeps its `.bypass` default on `ACPExtractionClient`).
    private var permissionSection: some View {
        Section {
            Picker("Chat Permission Mode", selection: $chatModeRaw) {
                ForEach(PermissionPolicy.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            Picker("Ingest Permission Mode", selection: $ingestModeRaw) {
                ForEach(PermissionPolicy.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            Picker("Lint Permission Mode", selection: $lintModeRaw) {
                ForEach(PermissionPolicy.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("These control how the app responds to the agent's permission requests for each operation. Ingest and Lint run unattended — Bypass is recommended (the sandbox already confines writes; an unattended pipeline can't use Always Ask productively, and a stuck permission would auto-reject after 60s).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Persistence

    private func save(_ updated: AgentProvidersConfig) {
        config = updated
        try? config.save(to: containerDirectory)
    }

    /// #640: persist probe-discovered models durably. Uses
    /// `settingCachedModels` DIRECTLY (NOT the parent's `save(_:)` helper) —
    /// the helper reconstructs the config from a hand-rolled subset of fields
    /// and DROPS `maxConcurrent` (pre-existing bug, see
    /// `AgentsSettingsView.swift:250-255` / `:360-362`). `settingCachedModels`
    /// is the PURE value-returning mutator the launcher's
    /// `cacheDiscoveredModels` already uses (`AgentLauncher.swift:297-309`) —
    /// it carries every field forward. The probe is the Settings-driven
    /// equivalent of that launcher path.
    ///
    /// `@MainActor`: mutates `@State config` and writes the sidecar. Called
    /// from the editor sheet's refresh Task via `await MainActor.run { … }`
    /// (the probe itself runs off-main; only the persist is on-main).
    @MainActor
    private func persistDiscoveredModels(_ models: [CachedModelInfo], forProvider id: String) async {
        let updated = config.settingCachedModels(models, forProvider: id)
        do {
            try updated.save(to: containerDirectory)
        } catch {
            // House rule: never bare `try?`. The write may fail (read-only
            // mount, permission) — log so it's visible in Console.app.
            DebugLog.store("persistDiscoveredModels save failed (provider=\(id)): \(error.localizedDescription)")
        }
        config = updated
        DebugLog.store("persistDiscoveredModels: provider=\(id) models=\(models.count) → saved")
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

    /// #640: the cached-model list is now mutable local state (was `let`) so
    /// the model `Picker` repopulates immediately on Refresh without re-
    /// presenting the sheet. Seeded from the parent's `config.cachedModels`
    /// at `init`; updated in-place when a refresh succeeds.
    @State private var cachedModels: [CachedModelInfo]
    /// #640: per-provider refresh lifecycle state. Mirrors Paseo's
    /// `refreshProvider` status model
    /// (`provider-snapshot-manager.ts:716-787`): `idle` → `loading` →
    /// `ready`/`error`. On `.error`, `cachedModels` is NOT wiped (the
    /// last-known list stays visible).
    @State private var modelRefreshState: ModelRefreshState = .idle

    let credentialStore: any ACPCredentialStore
    let onSave: (AgentProvider, String?) -> Void
    /// #640: durable-persist callback for discovered models. The probe calls
    /// this on success so the discovered list lands in `agent-providers.json`
    /// immediately (survives the user never clicking Save — same behavior as
    /// the launcher's post-spawn `cacheDiscoveredModels`). nil when the parent
    /// does not support refresh (kept optional for the hosted-test seam).
    let onRefreshModels: (@Sendable (AgentProvider, [CachedModelInfo]) async -> Void)?

    /// #640: the probe's lifecycle state. Equatable so SwiftUI skips body
    /// re-renders when the state hasn't changed (e.g. `.idle` → `.idle`).
    enum ModelRefreshState: Equatable {
        case idle
        case loading
        case ready([CachedModelInfo])
        case error(String)
    }

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
        onSave: @escaping (AgentProvider, String?) -> Void,
        onRefreshModels: (@Sendable (AgentProvider, [CachedModelInfo]) async -> Void)? = nil
    ) {
        self.originalID = provider.id
        self._label = State(initialValue: provider.label)
        self._commandText = State(initialValue: provider.command.map(ShellWords.join) ?? "")
        self._envRows = State(initialValue: provider.env
            .sorted(by: { $0.key < $1.key })
            .map { EnvRow(key: $0.key, value: $0.value) })
        self._apiKey = State(initialValue: "")
        self._selectedModelId = State(initialValue: selectedModelId)
        self._cachedModels = State(initialValue: cachedModels)
        self.credentialStore = credentialStore
        self.onSave = onSave
        self.onRefreshModels = onRefreshModels
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
                            refreshModels()
                        }
                        .disabled(onRefreshModels == nil)
                        .help("Fetches the models this provider advertises. Requires the executable on PATH.")
                        Spacer()
                        switch modelRefreshState {
                        case .idle:
                            if cachedModels.isEmpty {
                                Text("No models captured yet")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .loading:
                            ProgressView()
                                .controlSize(.small)
                            Text("Discovering models…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .ready:
                            // The picker above already shows the count; no extra
                            // caption needed (keeps the row tight).
                            EmptyView()
                        case .error(let message):
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
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

    /// #640: drive the ACP model-discovery probe for THIS provider. Mirrors
    /// Paseo's `refreshProvider`
    /// (`provider-snapshot-manager.ts:716-787`): an availability pre-check,
    /// then a throwaway `initialize` + `session/new` probe (60s timeout), then
    /// on success persist + repaint; on failure set `.error` but keep the
    /// last-known list. Runs OFF the main actor (the probe is `Sendable`);
    /// crosses back to `@MainActor` for the persist + UI update.
    ///
    /// `modelRefreshState` transitions: `idle`/`ready`/`error` → `loading`
    /// → `ready` (success) / `error` (failure). `cachedModels` is replaced
    /// ONLY on success — a failure keeps the last-known list visible (Paseo
    /// parity: `provider-snapshot-manager.ts:773-786` overwrites status/error
    /// fields only).
    private func refreshModels() {
        // Availability pre-check (Paseo parity, :748-756 — `client.isAvailable`).
        // This is the SSW analogue: PathPreflight on the login-shell PATH.
        // Done on-main with the `isAvailable` state already computed by
        // `refreshAvailability()` — no spawn if the executable isn't found.
        guard isAvailable else {
            modelRefreshState = .error("Executable not found on PATH")
            return
        }
        // Reviewer finding #4: build the provider from the editor's current
        // state, mirroring `save()`'s construction verbatim — the probe needs
        // the resolved command path (PATH resolution happens internally in
        // `resolveSpawnConfig` via `providerHints`). `enabled`/`isDefault` are
        // preserved by the parent on Save; the probe doesn't read them.
        let words = ShellWords.split(commandText)
        let env: [String: String] = envRows.reduce(into: [:]) { result, row in
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return }
            result[key] = row.value
        }
        let providerForProbe = AgentProvider(
            id: originalID,
            label: label.trimmingCharacters(in: .whitespaces),
            command: words.isEmpty ? nil : words,
            env: env,
            enabled: true,
            isDefault: false)
        let apiKeyForProbe = apiKey.isEmpty ? nil : apiKey

        modelRefreshState = .loading
        DebugLog.agent("ProviderEditorView.refreshModels: starting probe provider=\(originalID)")
        Task {
            // The probe struct captures only Sendable config; the SDK Client
            // actor is the concurrency boundary. All subprocess I/O runs here,
            // off-main.
            let probe = ACPProviderModelProbe(
                provider: providerForProbe,
                resolvedCommand: words,
                apiKey: apiKeyForProbe)
            let outcome: Result<[CachedModelInfo], Error>
            do {
                let models = try await probe.discoverModels()
                if ACPProviderModelProbe.shouldThrowNoModels(models) {
                    // The probe completed successfully but the agent advertised
                    // no models (older agents). Surface a specific error rather
                    // than wiping the cache.
                    DebugLog.agent("ProviderEditorView.refreshModels: probe OK but no models advertised provider=\(originalID)")
                    outcome = .failure(ACPProviderModelProbeError.noModelsAdvertised)
                } else {
                    DebugLog.agent("ProviderEditorView.refreshModels: probe OK models=\(models.count) provider=\(originalID)")
                    outcome = .success(models)
                }
            } catch {
                DebugLog.agent("ProviderEditorView.refreshModels: probe failed provider=\(originalID): \(error.localizedDescription)")
                outcome = .failure(error)
            }
            // Cross back to @MainActor for the persist + UI update.
            await MainActor.run {
                switch outcome {
                case .success(let models):
                    cachedModels = models
                    modelRefreshState = .ready(models)
                    // Persist durably — survives even if the user never clicks
                    // Save (matches the launcher's post-spawn
                    // `cacheDiscoveredModels` semantics).
                    if let onRefreshModels {
                        Task {
                            await onRefreshModels(providerForProbe, models)
                        }
                    }
                case .failure(let error):
                    // LAST-KNOWN list retained — only the status/error fields
                    // change (Paseo parity). The model picker keeps showing
                    // `cachedModels`; only the inline status updates.
                    let message: String
                    if let probeErr = error as? ACPProviderModelProbeError {
                        message = probeErr.localizedDescription
                    } else {
                        message = error.localizedDescription
                    }
                    modelRefreshState = .error(message)
                }
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
