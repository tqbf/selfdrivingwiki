import SwiftUI
import WikiFSCore

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
///   the Summary tab passes `"Default (first few sentences)"` to convey the
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

    /// Friendly name for the "Same as provider" option — shows the concrete
    /// model id the stage will actually use, so the user can see the effective
    /// resolution at a glance.
    private var fallbackLabel: String {
        config.selectedModelId(forProvider: resolvedProvider.id) ?? "default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("\(label) Provider", selection: providerBinding) {
                Text(defaultOptionLabel).tag("")
                ForEach(config.enabledProviders) { p in
                    Text(p.label).tag(p.id)
                }
            }

            Picker("\(label) Model", selection: modelBinding) {
                if resolvedModels.isEmpty {
                    Text("Chat with this provider to discover models").tag("")
                } else {
                    Text("Same as provider (\(fallbackLabel))").tag("")
                    ForEach(resolvedModels, id: \.modelId) { model in
                        Text(model.displayLabel).tag(model.modelId)
                    }
                }
            }
            .disabled(resolvedModels.isEmpty)
            .help(resolvedModels.isEmpty
                  ? "Chat with this provider once to discover its models."
                  : "Pick a model for the \(label) stage. “Same as provider” uses the provider's selected model.")
        }
    }

    /// Reads/writes `config.stageProviderIds[stageKey]`. On set, routes through
    /// `settingStageProvider(_:forStage:)` (which ALSO clears the stage's stale
    /// model override when the provider changes — §2.2.3), then persists.
    private var providerBinding: Binding<String> {
        Binding(
            get: { config.stageProviderIds[stageKey] ?? "" },
            set: { newID in
                let updated = config.settingStageProvider(
                    newID.isEmpty ? nil : newID,
                    forStage: stageKey)
                save(updated)
            })
    }

    /// Reads/writes `config.ingestStageModelIds[stageKey]`. On set, routes
    /// through `settingIngestStageModel(_:forStage:)`, then persists.
    private var modelBinding: Binding<String> {
        Binding(
            get: { config.ingestStageModelIds[stageKey] ?? "" },
            set: { newID in
                let updated = config.settingIngestStageModel(
                    newID.isEmpty ? nil : newID,
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
