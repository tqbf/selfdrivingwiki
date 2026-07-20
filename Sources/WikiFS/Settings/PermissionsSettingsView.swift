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
/// **Per-stage model selection (per-stage-model-selection plan, replaces the
/// removed #704 per-op provider pin section):** the "Ingest Stage Models"
/// section picks a different MODEL for each ingest phase (planner /
/// executor / finalizer) within ONE provider. The whole ingest run resolves
/// ONE provider via `selectedProvider()`; per-stage only varies the model id
/// within that provider's catalog (e.g. `glm-5.2` planner → `glm-5.2-fast`
/// executors → `glm-5.2-short` finalizer — same provider). "Same as provider"
/// (empty) is the default → every stage uses the provider's
/// `selectedModelId` (the #604 collapsed behavior — no behavior change for
/// existing users).
struct PermissionsSettingsView: View {
    @AppStorage(AgentLauncher.PermissionModeKey.chat)   private var chatModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.ingest) private var ingestModeRaw = PermissionPolicy.bypass.rawValue
    @AppStorage(AgentLauncher.PermissionModeKey.lint)   private var lintModeRaw   = PermissionPolicy.bypass.rawValue
    @AppStorage(AppDelegate.confirmQuitKey) private var confirmBeforeQuitting = true

    /// The provider config — loaded fresh on appear so a Settings edit on the
    /// Agents tab is visible the next time the Permissions tab renders.
    /// Mirrors `AgentsSettingsView`'s `@State config` shape.
    @State private var config: AgentProvidersConfig

    private let containerDirectory: URL

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        let loaded = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        _config = State(initialValue: loaded)
    }

    var body: some View {
        Form {
            permissionSection
            appBehaviorSection
            ingestStageModelSection
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

    // MARK: - Per-stage model selection (per-stage-model-selection plan §5)

    /// Per-ingest-stage model picker. Each ingest phase (planner / executor /
    /// finalizer) can pick a different MODEL from the resolved provider's
    /// cached catalog (same provider across all three — per-stage selects a
    /// model variant, NOT a provider). "Same as provider" (empty) is the
    /// default → that stage uses the provider's `selectedModelId` (the #604
    /// collapsed behavior — no behavior change for existing users).
    ///
    /// Reuses the existing `Picker` pattern from `AgentsSettingsView.swift`'s
    /// per-provider model picker (`Provider default` / `Agent default` rows,
    /// reads `cachedModels(forProvider:)`).
    private var ingestStageModelSection: some View {
        let provider = config.selectedProvider()           // ONE provider across all stages
        let models = config.cachedModels(forProvider: provider.id)
        let fallbackLabel = config.selectedModelId(forProvider: provider.id) ?? "default"
        return Section {
            ForEach(ACPIngestStage.allCases, id: \.rawValue) { stage in
                Picker("\(stage.label) Model", selection: Binding(
                    get: { config.ingestStageModelIds[stage.rawValue] ?? "" },
                    set: { newID in setStageModel(stage, newID.isEmpty ? nil : newID) }
                )) {
                    Text("Same as provider (\(fallbackLabel))").tag("")
                    ForEach(models, id: \.modelId) { model in
                        Text(model.displayLabel).tag(model.modelId)
                    }
                }
                .disabled(models.isEmpty)
                .help(models.isEmpty
                      ? "Chat with this provider once to discover its models."
                      : "Pick a different model for the \(stage.label) phase. Empty uses the provider's selected model.")
            }
        } header: {
            Text("Ingest Stage Models")
        } footer: {
            Text("Pick a different model for each ingest phase (\(provider.label)) — e.g. a small model for Executors and a large model for the Planner. “Same as provider” uses the provider's selected model (the legacy behavior).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    /// Set + persist the per-stage model id for `stage` (or clear it when
    /// `modelId` is nil/empty). Mirrors `AgentsSettingsView.applyEdit`'s
    /// `settingSelectedModel(_:forProvider:)` call — load→mutate→save shape +
    /// the same `do/catch + DebugLog` house-rule error path.
    private func setStageModel(_ stage: ACPIngestStage, _ modelId: String?) {
        config = config.settingIngestStageModel(modelId, forStage: stage.rawValue)
        persist()
    }

    private func refresh() {
        let loaded = AgentProvidersConfig.loadOrSeed(from: containerDirectory)
        config = loaded
    }

    /// Persist the in-memory config to `agent-providers.json`. Uses
    /// `do/catch + DebugLog` per the house rule against bare `try?` (a silent
    /// failure would silently revert the user's per-stage model assignment on
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
