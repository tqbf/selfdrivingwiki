import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Settings → **Permissions** tab.
///
/// Previously lived as `permissionSection` inside `AgentsSettingsView`; split
/// into its own tab so the Agents tab (provider list) no longer pushes the
/// permission pickers below the fold when there are more than ~3 providers
/// (the Form clipped without scrolling, hiding the permissions entirely).
///
/// The `@AppStorage` keys (`AgentLauncher.PermissionModeKey.chat/ingest/lint`)
/// are independent of the view, so the same bindings work here as they did
/// inline in `AgentsSettingsView`. See `plans/acp-permissions.md` §5.1 for
/// the rationale behind three independent per-operation pickers (pre-split, a
/// single shared key fed chat + ingest + lint — a user who chose `alwaysAsk`
/// for chat got the same gating on unattended ingest/lint, guaranteeing a
/// stall on the first prompt needing a permission).
///
/// Extraction is intentionally NOT a kind here — it keeps its `.bypass`
/// default on `ACPExtractionClient`.
///
/// Also hosts the "Ask before quitting" toggle in the "App Behavior" section.
/// That toggle previously lived on a standalone General tab; the General tab
/// was removed for not justifying a whole tab, and the About tab was removed
/// shortly after for the same reason (only version info, which is already
/// surfaced in the app's standard About window). The toggle landed here
/// because permissions is the closest semantically to "app behavior" — it's
/// the only Settings tab whose controls affect the app's runtime behavior
/// rather than per-wiki content.
///
/// **Per-operation provider assignment (per-op-provider):** the "Provider
/// Assignment" section pins a separate provider to each operation (chat /
/// ingest / lint), with a per-provider model picker. A nil pin = "use the
/// default provider" (the legacy behavior — all three routes fall back to
/// the provider marked `isDefault`). The model picker reads/writes the
/// PER-PROVIDER model selection — so two operations pinned to the same
/// provider share its selected model (acceptable per the spec; a future
/// per-op-per-provider model override would require a shape change).
struct PermissionsSettingsView: View {
    @AppStorage(AgentLauncher.PermissionModeKey.chat)   private var chatModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.ingest) private var ingestModeRaw = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.lint)   private var lintModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AppDelegate.confirmQuitKey) private var confirmBeforeQuitting = true

    /// The provider config — loaded fresh on appear so a Settings edit on the
    /// Agents tab is visible the next time the Permissions tab renders.
    /// Mirrors `AgentsSettingsView`'s `@State config` shape.
    @State private var config: AgentProvidersConfig

    /// The per-operation provider id bindings. `nil` = "use default provider"
    /// (the legacy behavior). Bound to the config's `chatProviderId` /
    /// `ingestProviderId` / `lintProviderId` fields via the `setXxxProvider`
    /// launcher wrappers; persisted to `agent-providers.json` on every change.
    @State private var chatProviderId: String?
    @State private var ingestProviderId: String?
    @State private var lintProviderId: String?

    private let containerDirectory: URL

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        let loaded = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        _config = State(initialValue: loaded)
        _chatProviderId = State(initialValue: loaded.chatProviderId)
        _ingestProviderId = State(initialValue: loaded.ingestProviderId)
        _lintProviderId = State(initialValue: loaded.lintProviderId)
    }

    var body: some View {
        Form {
            permissionSection
            appBehaviorSection
            providerAssignmentSection
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    // MARK: - Permission section (unchanged shape, just moved out of body)

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

    // MARK: - App behavior section ("Ask before quitting")

    /// "Ask before quitting" toggle. Previously lived on a standalone General
    /// tab; that tab was removed (not justifying a whole tab) and the toggle
    /// landed here (see class docstring).
    private var appBehaviorSection: some View {
        Section("App Behavior") {
            Toggle("Ask before quitting", isOn: $confirmBeforeQuitting)
                .help(
                    "When enabled, Self Driving Wiki asks for confirmation "
                    + "before quitting — ⌘Q, or closing the last window with ⌘W."
                )
        }
    }

    // MARK: - Provider assignment section (per-op-provider)

    /// Per-operation provider + model pickers. Each operation can pin its OWN
    /// provider (independent of the default). The model picker writes the
    /// PER-PROVIDER model selection — so when two operations share a provider,
    /// they share its model. The "— Default —" row clears the pin (routes to
    /// `defaultProvider`); the "— Agent default —" row clears the model pin
    /// (lets the agent's first-listed model be used — the same as today).
    private var providerAssignmentSection: some View {
        Section {
            operationRow(
                label: "Chat",
                providerID: $chatProviderId,
                onProviderChange: { setChatProvider($0) })
            operationRow(
                label: "Ingest",
                providerID: $ingestProviderId,
                onProviderChange: { setIngestProvider($0) })
            operationRow(
                label: "Lint",
                providerID: $lintProviderId,
                onProviderChange: { setLintProvider($0) })
        } header: {
            Text("Provider Assignment")
        } footer: {
            Text("Pin a different provider to each operation. “Default” uses the provider marked default in the Agents tab (the legacy behavior). When a provider is deleted, any operation still pinned to it silently falls back to the default — no dangling references. The model picker writes the per-provider selection, so two operations pinned to the same provider share its model.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One operation row: a Provider picker + a Model picker. The Model picker
    /// reads the cached models for the operation's chosen provider (or the
    /// default provider when the pin is nil), mirroring the chat composer's
    /// per-provider selection seam.
    private func operationRow(
        label: String,
        providerID: Binding<String?>,
        onProviderChange: @escaping @MainActor (String?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)

            // The resolved provider for this operation — used to list models
            // and to persist the model selection. When the pin is nil OR stale
            // (points at a deleted provider), `providerForXxx()` returns
            // `defaultProvider` — so the model picker always shows a real list.
            let resolved: AgentProvider = {
                switch label {
                case "Chat":   return config.providerForChat()
                case "Ingest": return config.providerForIngest()
                case "Lint":   return config.providerForLint()
                default:        return config.defaultProvider
                }
            }()

            Picker("\(label) Provider", selection: Binding(
                get: { providerID.wrappedValue ?? "" },
                set: { newID in onProviderChange(newID.isEmpty ? nil : newID) }
            )) {
                Text("Default (\(config.defaultProvider.label))").tag("")
                ForEach(config.enabledProviders, id: \.id) { provider in
                    Text(provider.label).tag(provider.id)
                }
            }

            let models = config.cachedModels(forProvider: resolved.id)
            let currentModel = config.selectedModelId(forProvider: resolved.id)
            Picker("\(label) Model", selection: Binding(
                get: { currentModel ?? "" },
                set: { newID in setModel(newID.isEmpty ? nil : newID, for: resolved.id) }
            )) {
                if models.isEmpty {
                    Text("Chat with this provider once to discover models").tag("")
                } else {
                    Text("Agent default").tag("")
                    ForEach(models, id: \.modelId) { model in
                        Text(model.displayLabel).tag(model.modelId)
                    }
                }
            }
            .disabled(models.isEmpty)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func setChatProvider(_ id: String?) {
        config = config.settingChatProvider(id: id)
        chatProviderId = id
        persist()
    }

    private func setIngestProvider(_ id: String?) {
        config = config.settingIngestProvider(id: id)
        ingestProviderId = id
        persist()
    }

    private func setLintProvider(_ id: String?) {
        config = config.settingLintProvider(id: id)
        lintProviderId = id
        persist()
    }

    /// Set the per-provider model selection. The selection is keyed by
    /// PROVIDER (not per-operation) — every operation pinned to this provider
    /// will see the same model. Mirrors `AgentsSettingsView.applyEdit`'s
    /// `settingSelectedModel(_:forProvider:)` call.
    private func setModel(_ modelId: String?, for providerId: String) {
        config = config.settingSelectedModel(modelId, forProvider: providerId)
        persist()
    }

    private func refresh() {
        let loaded = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        config = loaded
        chatProviderId = loaded.chatProviderId
        ingestProviderId = loaded.ingestProviderId
        lintProviderId = loaded.lintProviderId
    }

    /// Persist the in-memory config to `agent-providers.json`. Uses
    /// `do/catch + DebugLog` per the house rule against bare `try?` (a silent
    /// failure would silently revert the user's per-op provider assignment on
    /// next launch — exactly the kind of bug the rule exists to prevent).
    private func persist() {
        do {
            try config.save(to: containerDirectory)
        } catch {
            DebugLog.store("PermissionsSettingsView persist failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    PermissionsSettingsView(
        containerDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-agent-providers", isDirectory: true))
        .frame(width: 460, height: 600)
}
