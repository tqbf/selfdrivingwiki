import SwiftUI
import WikiFSCore

enum StageProviderSelectionState: Equatable {
    case inherited
    case pinnedEnabled(id: String)
    case pinnedDisabled(id: String, label: String)
    case pinnedMissing(id: String)

    static func resolve(config: AgentProvidersConfig, stageKey: String) -> StageProviderSelectionState {
        guard let providerID = config.stageProviderIds[stageKey], !providerID.rawValue.isEmpty else {
            return .inherited
        }
        let pinnedID = providerID.rawValue
        guard let provider = config.provider(id: providerID) else {
            return .pinnedMissing(id: pinnedID)
        }
        guard provider.enabled else {
            return .pinnedDisabled(id: pinnedID, label: provider.label)
        }
        return .pinnedEnabled(id: pinnedID)
    }

    var isUnavailable: Bool {
        switch self {
        case .pinnedDisabled, .pinnedMissing:
            return true
        case .inherited, .pinnedEnabled:
            return false
        }
    }
}

/// The effective meaning of the model-picker inheritance option. Kept pure so
/// the UI cannot accidentally label an agent-default choice as a missing model.
enum StageModelInheritanceState: Equatable {
    case selectedModel(ModelID)
    case agentDefault

    static func resolve(config: AgentProvidersConfig, stageKey: String) -> StageModelInheritanceState {
        let provider = config.provider(forStage: stageKey)
        if let modelID = config.selectedModelId(forProvider: provider.id) {
            return .selectedModel(modelID)
        }
        return .agentDefault
    }

    var optionLabel: String {
        switch self {
        case .selectedModel(let modelID):
            return "Same as provider (\(modelID.rawValue))"
        case .agentDefault:
            return "Same as provider (agent default)"
        }
    }
}

/// A provider + model picker for a single agent stage/operation
/// (`plans/agent-settings-tabs.md` §2.2/§6). Reused for the Chat Model,
/// Planner/Executor/Finalizer Models, and Lint Model rows in the nested
/// Chat/Ingestion/Lint tab view, and for the per-message Summary Model row in
/// the Summary tab (`plans/chat-summary.md` §5.2).
///
/// - `stageKey`: stable string key into the per-stage overrides
///   (`"chat"`, `"planner"`, `"executor"`, `"finalizer"`, `"lint"`,
///   `"summarizer"`). For ingest stages this is `ACPIngestStage.rawValue`.
/// - `config`: the live config (binding so edits flow back to the parent's
///   `@State`).
/// - `containerDirectory`: for persistence (save on every change).
/// - `label`: human-readable stage label shown as the row title.
/// - `defaultOptionLabel`: the text shown for the sentinel `""` first option
///   in the provider dropdown. Defaults to `"Default"` (inherit the global
///   default provider). **Stage-specific semantic for `"summarizer"`**: an empty
///   pin means "no model — truncation" (NOT "inherit the global provider"), so
///   the Summary tab passes `"No AI (first few sentences)"` to convey the
///   actual behavior (`plans/chat-summary.md` §5.2).
///
/// The provider dropdown includes a **"Default"** first option (sentinel `""` =
/// inherit the global default provider). The model dropdown is **dependent** on
/// the resolved provider's cached model list, and includes a **"Same as
/// provider"** first option (sentinel `""` = the resolved provider's
/// `selectedModelId`). Changing the provider pin clears the stage's stale model
/// override (handled in `AgentProvidersConfig.settingStageProvider(_:forStage:)`).
struct StageProviderModelPicker: View {
    let stageKey: String
    @Binding var config: AgentProvidersConfig
    let containerDirectory: URL
    let label: String
    var defaultOptionLabel: String = "Default"

    private var selectionState: StageProviderSelectionState {
        StageProviderSelectionState.resolve(config: config, stageKey: stageKey)
    }

    /// Summary's inherited provider is the explicit no-model mode: summaries
    /// are produced by truncating locally.
    private var isNoProviderSummary: Bool {
        stageKey == "summarizer" && selectionState == .inherited
    }

    /// The effective provider for this stage (pinned when set + enabled, else
    /// the global default). Drives the model dropdown's contents.
    private var resolvedProvider: AgentProvider {
        config.provider(forStage: stageKey)
    }

    /// The cached models advertised by the resolved provider. Empty when none
    /// have been captured yet → the model picker is disabled with a guidance
    /// placeholder.
    private var resolvedModels: [CachedModelInfo] {
        config.cachedModels(forProvider: resolvedProvider.id)
    }

    private var modelInheritanceState: StageModelInheritanceState {
        StageModelInheritanceState.resolve(config: config, stageKey: stageKey)
    }

    /// The Summary tab's provider pin is load-bearing: a non-empty but
    /// unavailable pin keeps model mode selected, so the UI must surface the
    /// invalid state instead of pretending the fallback provider is in force.
    private var shouldDisableModelPickerForUnavailablePin: Bool {
        stageKey == "summarizer" && selectionState.isUnavailable
    }

    private var modelPickerPlaceholder: String {
        shouldDisableModelPickerForUnavailablePin
            ? "Selected provider unavailable"
            : "Chat with this provider to discover models"
    }

    private var modelPickerHelpText: String {
        if let unavailableProviderMessage {
            return unavailableProviderMessage
        }
        return resolvedModels.isEmpty
            ? "Chat with this provider once to discover its models."
            : "Pick a model for the \(label) stage. “Same as provider” uses the provider's selected model."
    }

    private var unavailableOptionLabel: String? {
        switch selectionState {
        case .pinnedDisabled(_, let providerLabel):
            return "\(providerLabel) (disabled)"
        case .pinnedMissing(let providerID):
            return "\(providerID) (missing)"
        case .inherited, .pinnedEnabled:
            return nil
        }
    }

    private var unavailableOptionTag: String? {
        switch selectionState {
        case .pinnedDisabled(let providerID, _), .pinnedMissing(let providerID):
            return providerID
        case .inherited, .pinnedEnabled:
            return nil
        }
    }

    private var unavailableProviderMessage: String? {
        switch selectionState {
        case .pinnedDisabled(_, let providerLabel):
            if stageKey == "summarizer" {
                return "Selected provider “\(providerLabel)” is disabled. Summary generation will stay unavailable until you re-enable it, pick another provider, or choose \(defaultOptionLabel)."
            }
            return "Selected provider “\(providerLabel)” is disabled. This stage is currently falling back to the default provider until you re-enable it or pick another provider."
        case .pinnedMissing(let providerID):
            if stageKey == "summarizer" {
                return "Selected provider “\(providerID)” no longer exists. Summary generation will stay unavailable until you pick another provider or choose \(defaultOptionLabel)."
            }
            return "Selected provider “\(providerID)” no longer exists. This stage is currently falling back to the default provider until you pick another provider."
        case .inherited, .pinnedEnabled:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("\(label) Provider", selection: providerBinding) {
                Text(defaultOptionLabel).tag("")
                if let unavailableOptionLabel, let unavailableOptionTag {
                    Text(unavailableOptionLabel).tag(unavailableOptionTag)
                }
                ForEach(config.enabledProviders) { p in
                    Text(p.label).tag(p.id.rawValue)
                }
            }

            if !isNoProviderSummary {
                Picker("\(label) Model", selection: modelBinding) {
                    if shouldDisableModelPickerForUnavailablePin || resolvedModels.isEmpty {
                        Text(modelPickerPlaceholder).tag("")
                    } else {
                        Text(modelInheritanceState.optionLabel).tag("")
                        ForEach(resolvedModels, id: \.modelId) { model in
                            Text(model.displayLabel).tag(model.modelId.rawValue)
                        }
                    }
                }
                .disabled(shouldDisableModelPickerForUnavailablePin || resolvedModels.isEmpty)
                .help(modelPickerHelpText)
            }

            if let unavailableProviderMessage {
                Text(unavailableProviderMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // #612: info-tone nudge when the stage's resolved model (pinned or
            // inherited from the provider) is a known free-tier model (e.g.
            // opencode/big-pickle). NOT a prohibition — the user can still
            // select it; this is a gentle steer toward a stronger model. Uses
            // `.secondary` (muted info tone), NOT `.orange` (warning).
            if let nudge = freeTierNudge {
                Text(nudge)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// #612: the free-tier nudge message for this stage's resolved model, or
    /// `nil` when the model is not a known free-tier model. Resolves through
    /// `config.modelId(forStage:)` so it fires whether the user pinned a
    /// specific model OR left "Same as provider" and the provider's own
    /// `selectedModelId` is free-tier. PURE (reads only the config).
    private var freeTierNudge: String? {
        FreeTierModelNudge.message(for: config.modelId(forStage: stageKey))
    }

    /// Reads/writes `config.stageProviderIds[stageKey]`. On set, routes through
    /// `settingStageProvider(_:forStage:)` (which ALSO clears the stage's stale
    /// model override when the provider changes — §2.2.3), then persists.
    private var providerBinding: Binding<String> {
        Binding(
            get: { config.stageProviderIds[stageKey]?.rawValue ?? "" },
            set: { newID in
                let updated = config.settingStageProvider(
                    newID.isEmpty ? nil : ProviderID(rawValue: newID),
                    forStage: stageKey)
                save(updated)
            })
    }

    /// Reads/writes `config.ingestStageModelIds[stageKey]`. On set, routes
    /// through `settingIngestStageModel(_:forStage:)`, then persists.
    private var modelBinding: Binding<String> {
        Binding(
            get: { config.ingestStageModelIds[stageKey]?.rawValue ?? "" },
            set: { newID in
                let updated = config.settingIngestStageModel(
                    newID.isEmpty ? nil : ModelID(rawValue: newID),
                    forStage: stageKey)
                save(updated)
            })
    }

    /// Persist the updated config: write back to the parent's `@State` binding
    /// AND save the sidecar. House rule: never bare `try?` — the write may fail
    /// (read-only mount, permission) and the failure must be visible in
    /// Console.app.
    private func save(_ updated: AgentProvidersConfig) {
        config = updated
        do {
            try updated.save(to: containerDirectory)
        } catch {
            DebugLog.store("StageProviderModelPicker save failed (stage=\(stageKey)): \(error.localizedDescription)")
        }
    }
}
