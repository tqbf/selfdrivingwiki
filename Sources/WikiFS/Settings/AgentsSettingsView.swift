import SwiftUI
import WikiFSCore
import WikiFSEngine

/// #663: structured model-status classifier for `providerRow`. The
/// `nonisolated static func modelStatus(for:in:)` below returns one of these
/// so the row can branch without re-deriving. PURE so it is unit-tested
/// directly (`AgentsSettingsViewModelStatusTests`).
enum ModelStatus: Equatable {
    /// The provider is disabled — no status line (the `○` switch glyph conveys it).
    case disabled
    /// The provider has a `selectedModelId` + the friendly name (the chosen
    /// model from the cache, or the raw model id when the cache is stale).
    case selected(name: String)
    /// Enabled + no model + no cached models. The orange "chat with this
    /// provider once to discover models" guidance line.
    case noneCaptured
    /// Enabled + no model + cached models exist. The orange "pick one before
    /// running" guidance line.
    case noSelectionPickable
}

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
    /// #663: drives the `AddProviderSheet`. Replaces the old `Menu` of
    /// hardcoded seed buttons (Add Claude / Add Hermes / Add OpenCode) with
    /// a non-destructive, catalog-driven sheet. Cancel = no change (AC.2).
    @State private var showAddSheet = false
    /// #663: tracks whether the editor was opened from the Add flow (true)
    /// or from Edit…/double-click on an EXISTING provider (false). When true,
    /// the editor's Cancel button removes the freshly-added provider from
    /// `config.providers` — a newly-added provider with no model MUST NOT
    /// persist in the list (otherwise the row sits with a "No model captured
    /// yet" warning and the launcher refuses to spawn).
    @State private var isAddingNewProvider = false
    /// Per-view collapse state for the `CollapsibleDetailHeader`. Starts
    /// expanded — a Settings panel is something the user opened to interact
    /// with, so showing the form by default (rather than hiding it behind a
    /// chevron) avoids a friction click on every visit.
    @State private var isExpanded = true

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
        // Collapsible title bar matching `PageDetailView` / `SourceDetailView`
        // / `ChatView`. Collapsed shows just the "Agents" title row; expanded
        // reveals the Form below. The title is non-editable (a fixed label
        // for the whole settings tab), so `isTitleDisabled` pins it.
        CollapsibleDetailHeader(
            systemImage: "cpu",
            title: "Agents",
            isTitleDisabled: true,
            isExpanded: $isExpanded,
            onTitleCommit: { _ in }
        ) {
            Form {
                providersSection
            }
            .formStyle(.grouped)
            .frame(minWidth: 560, minHeight: 520)
            // #663: the Add Provider sheet. Non-destructive (nothing is written
            // until an Add button is pressed — AC.2). The handoff to the editor
            // uses `DispatchQueue.main.async` (see correction §5): letting this
            // sheet finish dismissing before the editor presents avoids the
            // SwiftUI hazard where the second sheet silently fails when the
            // first is mid-dismissal.
            .sheet(isPresented: $showAddSheet) {
                AddProviderSheet(
                    existingIDs: Set(config.providers.map(\.id)),
                    onAdd: { provider in appendProvider(provider) },
                    onAddNeedsEditor: { provider in
                        showAddSheet = false
                        // #663: this provider was just appended by `onAdd`
                        // above with no selected model. Mark it as a fresh add
                        // so the editor's Cancel button removes it (see
                        // `ProviderEditorView` Cancel handler).
                        DispatchQueue.main.async {
                            isAddingNewProvider = true
                            editingProvider = provider
                        }
                    })
            }
            .sheet(item: $editingProvider) { provider in
                ProviderEditorView(
                    provider: provider,
                    cachedModels: config.cachedModels(forProvider: provider.id),
                    selectedModelId: config.selectedModelId(forProvider: provider.id) ?? "",
                    isAddingNew: isAddingNewProvider,
                    credentialStore: credentialStore,
                    onSave: { updated, selectedModelId in
                        applyEdit(updated, selectedModelId: selectedModelId)
                        isAddingNewProvider = false
                    },
                    onDelete: {
                        // Cancel on a freshly-added provider: remove it from
                        // `config.providers` (no confirmation needed — it has
                        // no model and was just appended; its API key, if any,
                        // is left in the Keychain for a future add).
                        if let pending = editingProvider {
                            removeProvider(pending)
                        }
                        isAddingNewProvider = false
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
    }

    // MARK: - Providers section

    private var providersSection: some View {
        Section {
            if config.providers.isEmpty {
                // Defensive — `loadOrSeed` guarantees at least one provider,
                // but a hand-edited/corrupt file could empty the list.
                ProvidersEmptyState { showAddSheet = true }
                    .frame(minHeight: 200)
                    .listRowBackground(Color.clear)
            } else {
                List(config.providers, selection: $selectedProviderID) { provider in
                    providerRow(provider)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selectedProviderID = provider.id
                            isAddingNewProvider = false
                            editingProvider = provider
                        }
                }
                .frame(minHeight: 160)
                .listStyle(.inset)

                HStack {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Provider", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)

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
                            isAddingNewProvider = false
                            editingProvider = provider
                        }
                    }
                    .disabled(selectedProvider == nil)
                }
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
        HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding(for: provider))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.label)
                        .fontWeight(.medium)
                    ProviderStatusBadges(provider: provider)
                }
                Text(provider.command.map(ShellWords.join) ?? "—")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Model status line (§3.2) — drives a green dot with the
                // model name, or an orange warning matching `modelWarning`.
                // The pure `modelStatus(for:in:)` classifier below is the
                // unit-tested seam; the `modelWarning(for:in:)` sibling is
                // kept for the existing `AgentsSettingsViewWarningTests`
                // suite (correction §6 — both coexist).
                switch Self.modelStatus(for: provider, in: config) {
                case .selected(let name):
                    Label(name, systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .noSelectionPickable:
                    Label("No model selected — pick one before running",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                case .noneCaptured:
                    Label("No model captured yet — chat with this provider once to discover models",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                case .disabled:
                    EmptyView()
                }
            }
            .opacity(provider.enabled ? 1.0 : 0.55)

            Spacer()
        }
        .padding(.vertical, 4)
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

    /// #663: the structured classifier the restructured `ProviderRow` reads.
    /// Sibling to `modelWarning(for:in:)` — both coexist (correction §6) so
    /// the existing `AgentsSettingsViewWarningTests` (which pin the warning
    /// STRING) stay load-bearing while the new row can branch on the
    /// structured enum.
    ///
    /// Same contract + same `nonisolated static` shape so the new tests
    /// (`AgentsSettingsViewModelStatusTests`) can call it without rendering.
    /// - `.disabled` is returned for a disabled provider (the row shows no
    ///   status line — the leading `○` switch glyph already conveys it).
    /// - `.selected(name)` when the provider has a `selectedModelId`.
    /// - `.noneCaptured` when no model cache exists yet (first-spawn state).
    /// - `.noSelectionPickable` when a cache exists but no selection was made.
    nonisolated static func modelStatus(for provider: AgentProvider, in config: AgentProvidersConfig) -> ModelStatus {
        guard provider.enabled else { return .disabled }
        if let modelId = config.selectedModelId(forProvider: provider.id),
           !modelId.isEmpty {
            // Resolve a friendly name if the model is in the cache; fall back
            // to the raw id so the dot+label still renders definitively.
            let name = config.cachedModels(forProvider: provider.id)
                .first(where: { $0.modelId == modelId })?.name ?? modelId
            return .selected(name: name)
        }
        let models = config.cachedModels(forProvider: provider.id)
        if models.isEmpty { return .noneCaptured }
        return .noSelectionPickable
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

    /// #663: non-destructive append — replaces `addSeed(_:)` and the
    /// pre-persist tail of `addCustom()`. Called by `AddProviderSheet`'s
    /// `onAdd`. Persists the provider immediately (the row appears in the
    /// list as soon as the sheet dismisses); the editor ALWAYS opens
    /// separately via the `onAddNeedsEditor` callback so the user is forced
    /// to pick a model before the provider is usable.
    ///
    /// Dedup: a provider with the same id is NOT replaced — the call is a
    /// no-op (the `AddProviderSheet` already hides already-added agents
    /// behind a "✓ Added" chip, so this is a defensive guard against a
    /// race between the sheet snapshot and a fast double-click).
    private func appendProvider(_ provider: AgentProvider) {
        guard !config.providers.contains(where: { $0.id == provider.id }) else {
            selectedProviderID = provider.id
            return
        }
        var updated = config
        updated.providers.append(provider)
        save(AgentProvidersConfig(
            providers: updated.providers,
            providerModels: updated.providerModels,
            selectedModelIds: updated.selectedModelIds,
            favoriteModelIds: updated.favoriteModelIds))
        selectedProviderID = provider.id
    }

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { providerPendingDeletion != nil },
            set: { if !$0 { providerPendingDeletion = nil } })
    }

    /// #663: removes a provider from `config.providers` and re-normalizes
    /// (promotes a new default if the deleted one was default). Shared by
    /// the delete-confirmation flow (`confirmDelete`) and the editor's
    /// Cancel-on-new-provider path. No confirmation dialog — callers decide
    /// whether to gate behind a confirmation (`providerPendingDeletion`).
    private func removeProvider(_ provider: AgentProvider) {
        guard config.providers.contains(where: { $0.id == provider.id }) else { return }
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
    }

    private func confirmDelete() {
        guard let provider = providerPendingDeletion else { return }
        removeProvider(provider)
        providerPendingDeletion = nil
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

    /// #663: progressive disclosure for Environment + Authentication. The
    /// common-case editor shows only Command + Model; the env/apiKey fields
    /// collapse under "Advanced" until the user has either env vars OR a
    /// stored key (auto-expanded via `onAppear` so existing config is never
    /// hidden). The `onAppear` assignment may cause a one-frame collapsed→
    /// expanded flash on providers that have env/key — acceptable per
    /// correction §7 (Low). A future two-pass `init` could compute it up
    /// front, but the apiKey load already needs `onAppear` (Keychain is a
    /// synchronous-actor hop on first read), so the timing is similar.
    @State private var showAdvanced = false

    let credentialStore: any ACPCredentialStore
    let onSave: (AgentProvider, String?) -> Void
    /// #663: invoked when the user cancels the editor on a freshly-added
    /// provider (only fired when `isAddingNew == true`). The parent removes
    /// the provider from `config.providers` — a newly-added provider with no
    /// model MUST NOT persist in the list.
    let onDelete: (() -> Void)?
    /// #640: durable-persist callback for discovered models. The probe calls
    /// this on success so the discovered list lands in `agent-providers.json`
    /// immediately (survives the user never clicking Save — same behavior as
    /// the launcher's post-spawn `cacheDiscoveredModels`). nil when the parent
    /// does not support refresh (kept optional for the hosted-test seam).
    let onRefreshModels: (@Sendable (AgentProvider, [CachedModelInfo]) async -> Void)?

    /// #663: true when this editor was opened from the Add flow (the provider
    /// was just appended with no model). Drives the Cancel button: when true,
    /// Cancel removes the provider from `config.providers` via `onDelete`;
    /// when false (Edit…/double-click on an existing provider), Cancel keeps
    /// the provider as-is.
    let isAddingNew: Bool

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
        isAddingNew: Bool = false,
        credentialStore: any ACPCredentialStore,
        onSave: @escaping (AgentProvider, String?) -> Void,
        onDelete: (() -> Void)? = nil,
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
        self.isAddingNew = isAddingNew
        self.credentialStore = credentialStore
        self.onSave = onSave
        self.onDelete = onDelete
        self.onRefreshModels = onRefreshModels
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // #663: reorder so the COMMON case is at the top — Command
                // → Model → Advanced (Environment + Authentication). The old
                // order had Environment between Command and Authentication,
                // cluttering the editor for providers that have neither.
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
                        case .ready(let models):
                            // #663: show a compact "N models" caption next
                            // to Refresh so the count is always legible (was
                            // EmptyView — the picker's count was the only
                            // signal, which disappeared when collapsed).
                            Label("\(models.count) models", systemImage: "circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                DisclosureGroup(isExpanded: $showAdvanced) {
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
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.headline)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    // #663: a freshly-added provider with no model MUST NOT
                    // persist in the list — fire the parent's `onDelete`
                    // callback so it's removed before the sheet dismisses.
                    // Editing an EXISTING provider (Cancel) keeps it as-is.
                    if isAddingNew {
                        onDelete?()
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    // #663: a provider cannot be saved without a selected model
                    // — otherwise the row sits with a "No model captured yet"
                    // warning and the launcher refuses to spawn
                    // (`SpawnModelGuard`). The "Provider default" picker option
                    // (tag "") counts as no selection: it leaves the provider
                    // with no selectedModelId.
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || selectedModelId.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear {
            apiKey = credentialStore.apiKey(forProvider: originalID) ?? ""
            // #663: auto-expand Advanced when provider already has env vars
            // OR a stored API key, so the user doesn't have to hunt for
            // existing config (§3.4). envRows is already initialized before
            // onAppear from `provider.env`; apiKey is set just above. NB:
            // this may cause a one-frame collapsed→expanded flash on env/key
            // providers — see the `showAdvanced` declaration comment.
            showAdvanced = showAdvanced
                || !envRows.allSatisfy { $0.key.trimmingCharacters(in: .whitespaces).isEmpty && $0.value.isEmpty }
                || !apiKey.isEmpty
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
        // PATH-resolve the executable BEFORE constructing the probe — the
        // probe (and `AgentBackendFactory.providerHints` /
        // `ACPBackend.resolveSpawnConfig` downstream) expects
        // `resolvedCommand[0]` to be an ABSOLUTE PATH. The swift-acp SDK's
        // `Process.launch()` does NOT do PATH lookup, and a GUI app's process
        // PATH is the launchd-minimal one (usually lacks `/opt/homebrew/bin`),
        // so passing the bare exe name reproduces the bug where the green
        // "Executable found on PATH" chip stays lit but Refresh Models fails
        // with "file <exe> doesn't exist". `AgentLauncher.
        // resolveACPProviderSpawn` does this same PATH hop on the real spawn
        // path; the probe must match (#640).
        //
        // NB: `AgentProvider.command` (what `save()` stores) is the BARE argv
        // — resolution is a spawn-time concern, not a stored-config concern.
        // The probe takes both: `provider` (bare, matching `save()`) and
        // `resolvedCommand` (resolved, matching the spawn contract).
        let words = ShellWords.split(commandText)
        let exe = words.first ?? ""
        guard !exe.isEmpty else {
            isAvailable = false
            modelRefreshState = .error("Executable not found on PATH")
            return
        }
        modelRefreshState = .loading
        DebugLog.agent("ProviderEditorView.refreshModels: starting probe provider=\(originalID)")
        Task {
            // `PathPreflight.resolveOnLoginShell` spawns `/bin/zsh -lc
            // 'echo $PATH'` (blocking I/O) — run it OFF the main actor,
            // mirroring `refreshAvailability()`'s detached task. Re-resolve
            // here instead of trusting the `onAppear`-time `isAvailable` state
            // (the user's PATH could have changed in the meantime).
            let resolved = await Task.detached {
                PathPreflight.resolveOnLoginShell(executable: exe)
            }.value
            let resolvedWords: [String]
            switch resolved {
            case .found(let absolutePath):
                resolvedWords = [absolutePath] + Array(words.dropFirst())
                await MainActor.run { isAvailable = true }
            case .missing(let reason):
                await MainActor.run {
                    isAvailable = false
                    modelRefreshState = .error(reason)
                }
                return
            }
            // Reviewer finding #4: build the provider from the editor's
            // current state, mirroring `save()`'s construction verbatim.
            // `enabled`/`isDefault` are preserved by the parent on Save;
            // the probe doesn't read them. `command` is the BARE argv (what
            // `save()` stores); the resolved argv is passed separately as
            // `resolvedCommand` below.
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

            // The probe struct captures only Sendable config; the SDK Client
            // actor is the concurrency boundary. All subprocess I/O runs here,
            // off-main.
            let probe = ACPProviderModelProbe(
                provider: providerForProbe,
                resolvedCommand: resolvedWords,
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
