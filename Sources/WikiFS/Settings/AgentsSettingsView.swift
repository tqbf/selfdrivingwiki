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

/// Settings → **Agents** tab. A two-pane source-list layout over
/// `AgentProvidersConfig`:
///
/// - **Sidebar**: the editable provider list.
/// - **Detail**: an INLINE editor (command, environment, model) for the
///   selected provider — the old modal "Edit…" sheet is gone.
///
/// The global Chat / Ingestion / Lint / Summary role pins live in their OWN
/// top-level Settings tab (`OperationsSettingsView`) — they pick *any* provider
/// per operation, so they don't belong inside a single provider's detail pane.
///
/// Persists via `AgentProvidersConfig.save(to:)` on every edit — no explicit
/// save step, mirroring `ZoteroSettingsView`.
struct AgentsSettingsView: View {
    @State private var config: AgentProvidersConfig
    @State private var selectedProviderID: String?
    @State private var providerPendingDeletion: AgentProvider?
    /// #663: drives the `AddProviderSheet` — a non-destructive, catalog-driven
    /// add flow. Cancel = no change (AC.2).
    @State private var showAddSheet = false

    /// The operation panes shown in `OperationsSettingsView`, each owning its
    /// stages. The Summary tab (`plans/chat-summary.md` §5.2) is the per-message
    /// summarizer stage pin. Declared here (rather than in `OperationsSettingsView`)
    /// so both views share one source of truth for the operation set.
    enum OperationTab: String, CaseIterable, Identifiable {
        case chat, ingestion, lint, summary
        var id: String { rawValue }
        var label: String {
            switch self {
            case .chat:      return "Chat"
            case .ingestion: return "Ingestion"
            case .lint:      return "Lint"
            case .summary:   return "Summary"
            }
        }
    }

    let containerDirectory: URL

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        let loaded = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        _config = State(initialValue: loaded)
        _selectedProviderID = State(initialValue: loaded.providers.first?.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            providersSection
                .frame(width: 260)

            Divider()

            detailPane
        }
        .frame(minWidth: 780, minHeight: 520, alignment: .top)
        // Pick up provider/model changes made while this tab was hidden (the
        // Settings TabView keeps every tab alive, so `init` runs only once).
        .onAppear { config = AgentProvidersConfig.loadOrSeed(from: containerDirectory) }
        // #663: the Add Provider sheet. Non-destructive (nothing is written
        // until an Add button is pressed — AC.2). On add, the provider is
        // appended and selected so its inline detail pane opens for the user
        // to pick a model / Refresh Models.
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet(
                existingIDs: Set(config.providers.map(\.id)),
                onAdd: { provider in appendProvider(provider) },
                // The provider is already appended + selected by `onAdd`; the
                // inline detail pane is where the user picks a model now (no
                // modal editor). This callback stays for the sheet's contract.
                onAddNeedsEditor: { provider in
                    showAddSheet = false
                    selectedProviderID = provider.id
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
            Text("This removes the provider from the app. You can add it again later.")
        }
    }

    // MARK: - Detail routing

    @ViewBuilder
    private var detailPane: some View {
        if let provider = selectedProvider {
            ProviderDetailPane(
                provider: provider,
                config: $config,
                containerDirectory: containerDirectory)
                // Re-seed the pane's local edit state when the SELECTED provider
                // changes, but not when the same provider's config mutates (so
                // inline edits survive a save round-trip).
                .id(provider.id)
        } else {
            detailPlaceholder
        }
    }

    private var detailPlaceholder: some View {
        ContentUnavailableView(
            "Select a provider",
            systemImage: "cpu",
            description: Text("Choose a provider from the list to view its details.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Providers section (sidebar)

    private var providersSection: some View {
        VStack(spacing: 0) {
            if config.providers.isEmpty {
                // Defensive — `loadOrSeed` guarantees at least one provider,
                // but a hand-edited/corrupt file could empty the list.
                ProvidersEmptyState { showAddSheet = true }
            } else {
                List(selection: $selectedProviderID) {
                    Section("Providers") {
                        ForEach(config.providers) { provider in
                            providerRow(provider)
                                .tag(provider.id)
                        }
                    }
                }
                .listStyle(.sidebar)

                providerActionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The source-list footer gutter: a compact `+` / `−` pair, pinned below
    /// the List (a sibling in the VStack) so it never scrolls off. "Make
    /// Default" moved into the provider detail pane (it's contextual to the
    /// selected provider); editing is inline, so there's no Edit button here.
    private var providerActionBar: some View {
        HStack(spacing: 0) {
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .help("Add a provider")

            Divider().frame(height: 14)

            Button {
                if let provider = selectedProvider {
                    providerPendingDeletion = provider
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selectedProvider == nil || config.providers.count <= 1)
            .help("Remove the selected provider")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Divider(), alignment: .top)
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
            }
            .opacity(provider.enabled ? 1.0 : 0.55)

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model status (pure classifiers, unit-tested)

    /// Returns a warning string when `provider` is enabled, has no selected
    /// model, and the launcher will therefore refuse to spawn it (see
    /// `SpawnModelGuard`). Returns `nil` for disabled providers and providers
    /// with a selected model. PURE + STATIC so it can be unit-tested without
    /// rendering.
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
    /// Sibling to `modelWarning(for:in:)` — both coexist so the existing
    /// warning-string tests stay load-bearing while callers can branch on the
    /// structured enum.
    nonisolated static func modelStatus(for provider: AgentProvider, in config: AgentProvidersConfig) -> ModelStatus {
        guard provider.enabled else { return .disabled }
        if let modelId = config.selectedModelId(forProvider: provider.id),
           !modelId.isEmpty {
            let name = config.cachedModels(forProvider: provider.id)
                .first(where: { $0.modelId == modelId })?.name ?? modelId
            return .selected(name: name)
        }
        let models = config.cachedModels(forProvider: provider.id)
        if models.isEmpty { return .noneCaptured }
        return .noSelectionPickable
    }

    // MARK: - Bindings / helpers

    private func enabledBinding(for provider: AgentProvider) -> Binding<Bool> {
        Binding(
            get: { provider.enabled },
            set: { newValue in
                var updated = config
                if let idx = updated.providers.firstIndex(where: { $0.id == provider.id }) {
                    updated.providers[idx].enabled = newValue
                }
                // §4f: route through `replacingProviders` so `maxConcurrent`
                // AND `ingestStageModelIds` survive — the memberwise init's
                // defaulted fields silently wiped them on every enable toggle.
                save(config.replacingProviders(updated.providers))
            })
    }

    private var selectedProvider: AgentProvider? {
        guard let id = selectedProviderID else { return nil }
        return config.provider(id: id)
    }

    // MARK: - Add / delete

    /// #663: non-destructive append — called by `AddProviderSheet`'s `onAdd`.
    /// Persists immediately (the row appears as soon as the sheet dismisses)
    /// and selects the new provider so its inline detail pane opens.
    private func appendProvider(_ provider: AgentProvider) {
        guard !config.providers.contains(where: { $0.id == provider.id }) else {
            selectedProviderID = provider.id
            return
        }
        var updated = config
        updated.providers.append(provider)
        save(config.replacingProviders(updated.providers))
        selectedProviderID = provider.id
    }

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { providerPendingDeletion != nil },
            set: { if !$0 { providerPendingDeletion = nil } })
    }

    /// #663: removes a provider and re-normalizes (promotes a new default if
    /// the deleted one was default).
    private func removeProvider(_ provider: AgentProvider) {
        guard config.providers.contains(where: { $0.id == provider.id }) else { return }
        var updated = config
        updated.providers.removeAll { $0.id == provider.id }
        save(config.replacingProviders(updated.providers))
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
        do {
            try updated.save(to: containerDirectory)
        } catch {
            // House rule: never bare `try?`. Log so failures are visible.
            DebugLog.store("Failed to save agent-providers config: \(error.localizedDescription)")
        }
    }
}

// MARK: - Provider detail pane (right panel, inline editor)

/// The right-side detail pane for a selected provider. Everything is edited
/// INLINE here (no modal sheet): the enable toggle, "Make Default", the command
/// (with a PATH-availability chip), the model picker + Refresh Models, and the
/// environment variables. API keys were removed from this surface entirely.
///
/// Local edit state (`label`, `commandText`, `envRows`) is seeded once from the
/// provider at `init`; the parent tears this view down with `.id(provider.id)`
/// when the SELECTED provider changes, so switching providers re-seeds while an
/// in-place config save does not. Edits are committed back to the parent's
/// `config` binding (and persisted to the sidecar) on change.
private struct ProviderDetailPane: View {
    let provider: AgentProvider
    @Binding var config: AgentProvidersConfig
    let containerDirectory: URL

    @State private var label: String
    @State private var commandText: String
    /// Bash-style `KEY=value` text (one per line; `#` comments ignored). A
    /// multiline box is friendlier than KEY/value rows for the common case:
    /// pasting a block of variables. Seeded with the provider's suggested
    /// variables as `#` comments when the provider has no env set yet.
    @State private var envText: String
    @State private var isAvailable: Bool = false
    @State private var modelRefreshState: ModelRefreshState = .idle

    /// The probe's lifecycle state. Equatable so SwiftUI skips body re-renders
    /// when the state hasn't changed.
    enum ModelRefreshState: Equatable {
        case idle
        case loading
        case ready([CachedModelInfo])
        case error(String)
    }

    init(provider: AgentProvider, config: Binding<AgentProvidersConfig>, containerDirectory: URL) {
        self.provider = provider
        self._config = config
        self.containerDirectory = containerDirectory
        self._label = State(initialValue: provider.label)
        self._commandText = State(initialValue: provider.command.map(ShellWords.join) ?? "")
        self._envText = State(initialValue: EnvVarText.seed(for: provider))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                providerHeader
                configForm
                helperText
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { refreshAvailability() }
    }

    // MARK: - Header

    private var providerHeader: some View {
        HStack(spacing: 10) {
            // Just the name + Default badge — the command lives in the editable
            // Command field below, so repeating it here would be redundant.
            HStack(spacing: 6) {
                Text(label.isEmpty ? provider.label : label)
                    .font(.title3)
                    .fontWeight(.semibold)
                ProviderStatusBadges(provider: provider)
            }
            .opacity(provider.enabled ? 1.0 : 0.55)

            Spacer()

            if !provider.isDefault {
                Button("Make Default") {
                    saveConfig(config.settingDefault(id: provider.id))
                }
                .help("Use this provider when an operation isn't pinned to a specific one.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Config form

    private var configForm: some View {
        Form {
            Section {
                TextField("Name", text: $label)
                    .onChange(of: label) { commitProviderConfig() }

                VStack(alignment: .leading, spacing: 5) {
                    TextField("Command", text: $commandText, prompt: Text("bun x @agentclientprotocol/claude-agent-acp"))
                        .fontDesign(.monospaced)
                        .onChange(of: commandText) {
                            commitProviderConfig()
                            refreshAvailability()
                        }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isAvailable ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(isAvailable ? "Executable found on PATH" : "Not found on PATH")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                defaultModelRow

                if case .error(let message) = modelRefreshState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("A single command line. Quote arguments containing spaces. Default Model is the model this provider runs unless an operation pins a different one; Refresh rediscovers the models it advertises.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            environmentSection
        }
        .formStyle(.grouped)
    }

    /// A single "Default Model" row: the provider's default model + a refresh
    /// button to (re)discover the advertised model list. Operations can override
    /// this per-operation; when they don't ("Same as provider"), this is what
    /// runs.
    @ViewBuilder
    private var defaultModelRow: some View {
        let cachedModels = config.cachedModels(forProvider: provider.id)
        LabeledContent("Default Model") {
            HStack(spacing: 8) {
                Picker("Default Model", selection: modelBinding) {
                    Text("Agent default").tag("")
                    ForEach(cachedModels, id: \.modelId) { model in
                        Text(model.displayLabel).tag(model.modelId)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                if modelRefreshState == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        refreshModels()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help("Rediscover the models this provider advertises (requires the executable on PATH).")
                }
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { config.selectedModelId(forProvider: provider.id) ?? "" },
            set: { newID in
                saveConfig(config.settingSelectedModel(
                    newID.isEmpty ? nil : newID,
                    forProvider: provider.id))
            })
    }

    // MARK: - Environment (#738)

    private var environmentSection: some View {
        let malformed = EnvVarText.malformedLines(envText)
        return Section {
            TextEditor(text: $envText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .onChange(of: envText) { commitProviderConfig() }
        } header: {
            Text("Environment")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("One KEY=value per line — paste a block of variables directly. Lines starting with # are ignored. Non-secret configuration only (stored in plain JSON).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !malformed.isEmpty {
                    Text("Ignoring \(malformed.count) line\(malformed.count == 1 ? "" : "s") without a KEY=value: \(malformed.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Helper text

    private var helperText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Command, environment, and model apply when this provider runs. Use the Operations item in the sidebar to pin which provider runs Chat, Ingestion, Lint, and Summary.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Providers are stored in agent-providers.json in the app's container.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    // MARK: - Commit / persistence

    /// Build an `AgentProvider` from the pane's local edit state and merge it
    /// back into `config.providers` (preserving `enabled`/`isDefault`, which the
    /// toggle and "Make Default" own), then persist. Called on every field
    /// change — the sidecar is tiny and written atomically.
    private func commitProviderConfig() {
        guard let idx = config.providers.firstIndex(where: { $0.id == provider.id }) else { return }
        let existing = config.providers[idx]
        let cleanLabel = label.trimmingCharacters(in: .whitespaces)
        let env = EnvVarText.parse(envText)
        let command = ShellWords.split(commandText)
        var providers = config.providers
        providers[idx] = AgentProvider(
            id: existing.id,
            label: cleanLabel.isEmpty ? existing.label : cleanLabel,
            command: command.isEmpty ? nil : command,
            env: env,
            enabled: existing.enabled,
            isDefault: existing.isDefault)
        saveConfig(config.replacingProviders(providers))
    }

    private func saveConfig(_ updated: AgentProvidersConfig) {
        config = updated
        do {
            try updated.save(to: containerDirectory)
        } catch {
            DebugLog.store("ProviderDetailPane save failed (provider=\(provider.id)): \(error.localizedDescription)")
        }
    }

    // MARK: - PATH availability + model discovery

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

    /// #640: drive the ACP model-discovery probe for THIS provider. PATH-resolve
    /// the executable to an ABSOLUTE path first (the SDK's `Process.launch()`
    /// does no PATH lookup and a GUI app's PATH is the launchd-minimal one).
    /// Runs OFF the main actor; crosses back to `@MainActor` to persist +
    /// repaint. On success the discovered models are persisted durably (survives
    /// the user never touching the picker); on failure the last-known list is
    /// kept and only the status line changes.
    private func refreshModels() {
        let words = ShellWords.split(commandText)
        let exe = words.first ?? ""
        guard !exe.isEmpty else {
            isAvailable = false
            modelRefreshState = .error("Executable not found on PATH")
            return
        }
        modelRefreshState = .loading
        DebugLog.agent("ProviderDetailPane.refreshModels: starting probe provider=\(provider.id)")
        let providerID = provider.id
        let env = EnvVarText.parse(envText)
        let cleanLabel = label.trimmingCharacters(in: .whitespaces)
        Task {
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
            let providerForProbe = AgentProvider(
                id: providerID,
                label: cleanLabel,
                command: words.isEmpty ? nil : words,
                env: env,
                enabled: true,
                isDefault: false)
            let probe = ACPProviderModelProbe(
                provider: providerForProbe,
                resolvedCommand: resolvedWords,
                apiKey: nil)
            let outcome: Result<[CachedModelInfo], Error>
            do {
                let models = try await probe.discoverModels()
                if ACPProviderModelProbe.shouldThrowNoModels(models) {
                    DebugLog.agent("ProviderDetailPane.refreshModels: probe OK but no models advertised provider=\(providerID)")
                    outcome = .failure(ACPProviderModelProbeError.noModelsAdvertised)
                } else {
                    DebugLog.agent("ProviderDetailPane.refreshModels: probe OK models=\(models.count) provider=\(providerID)")
                    outcome = .success(models)
                }
            } catch {
                DebugLog.agent("ProviderDetailPane.refreshModels: probe failed provider=\(providerID): \(error.localizedDescription)")
                outcome = .failure(error)
            }
            await MainActor.run {
                switch outcome {
                case .success(let models):
                    modelRefreshState = .ready(models)
                    // Persist durably — survives even if the user never changes
                    // the picker (matches the launcher's post-spawn cache).
                    saveConfig(config.settingCachedModels(models, forProvider: providerID))
                case .failure(let error):
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
}

// MARK: - Environment text format

/// Pure helpers for the provider Environment text box: parse/serialize
/// bash-style `KEY=value` lines, detect malformed lines, and build the
/// commented seed shown for a provider with no env set yet. Kept as a
/// `fileprivate enum` of static funcs so it's easy to reason about (and unit
/// test) without any SwiftUI.
enum EnvVarText {
    /// Parse `KEY=value` lines into an env dict. Blank lines and `#` comments
    /// are skipped; a leading `export ` is stripped; the value has matching
    /// surrounding single/double quotes removed. Last duplicate key wins.
    static func parse(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in assignments(in: text) {
            env[key] = value
        }
        return env
    }

    /// Non-comment, non-blank lines that don't parse to a `KEY=value` (no `=`,
    /// or an empty key). Surfaced as a gentle "ignoring N lines" hint.
    static func malformedLines(_ text: String) -> [String] {
        var bad: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if assignment(from: line) == nil { bad.append(line) }
        }
        return bad
    }

    /// Serialize an env dict to sorted `KEY=value` lines.
    static func format(_ env: [String: String]) -> String {
        env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    /// The initial text-box contents for a provider: its existing env as
    /// `KEY=value` lines, or — when it has none — a commented scaffold that
    /// lists the provider's suggested variables so they're discoverable
    /// without leaving the field.
    static func seed(for provider: AgentProvider) -> String {
        if !provider.env.isEmpty { return format(provider.env) }
        var lines = ["# One KEY=value per line. Lines starting with # are ignored."]
        if let hints = EnvVarHints.hints(forProviderID: provider.id), !hints.isEmpty {
            lines.append("#")
            lines.append("# Common variables for this provider:")
            for hint in hints {
                lines.append("# \(hint.key)=   # \(hint.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    /// All valid `(key, value)` assignments in `text`, in order.
    private static func assignments(in text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let pair = assignment(from: line) { result.append(pair) }
        }
        return result
    }

    /// Parse one already-trimmed, non-comment line into `(key, value)`, or
    /// `nil` when it isn't a well-formed assignment.
    private static func assignment(from line: String) -> (String, String)? {
        var body = line
        if body.hasPrefix("export ") {
            body = String(body.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        }
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let key = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = stripQuotes(String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        return (key, value)
    }

    /// Remove one layer of matching surrounding single/double quotes.
    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
