import SwiftUI
import WikiFSCore

/// Settings → **Operations** tab. The global Chat / Ingestion / Lint / Summary
/// role pins: each pins which provider + model runs that operation. These are
/// GLOBAL config (independent of any single provider), so they live in their own
/// top-level tab — a provider dropdown showing *any* provider is exactly right
/// here, unlike inside a single provider's detail pane.
///
/// Owns its own `AgentProvidersConfig` copy (like the other settings tabs) and
/// persists via `AgentProvidersConfig.save(to:)` on every edit. Reloads on
/// appear so provider/model changes made in the Agents tab are reflected (the
/// Settings `TabView` keeps every tab alive, so `init` runs only once).
struct OperationsSettingsView: View {
    @State private var config: AgentProvidersConfig
    let containerDirectory: URL

    @State private var selectedOperationTab: AgentsSettingsView.OperationTab = .chat

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        _config = State(initialValue: AgentProvidersConfig.loadOrSeed(from: containerDirectory))
    }

    var body: some View {
        // A single grouped Form — the Settings window centers and insets it,
        // matching the other tabs (Zotero/Extraction). The segmented operation
        // switcher is the first section; the selected operation's pins follow.
        Form {
            Section {
                HStack {
                    Spacer(minLength: 0)
                    Picker("Operation", selection: $selectedOperationTab) {
                        ForEach(AgentsSettingsView.OperationTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            } footer: {
                Text(selectedOperationTab.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            operationSections
        }
        .formStyle(.grouped)
        .onAppear { config = AgentProvidersConfig.loadOrSeed(from: containerDirectory) }
    }

    @ViewBuilder
    private var operationSections: some View {
        switch selectedOperationTab {
        case .chat:
            Section {
                StageProviderModelPicker(
                    stageKey: "chat",
                    config: $config,
                    containerDirectory: containerDirectory,
                    label: "Chat Model")
            } header: {
                Text("Chat Model")
            } footer: {
                Text("Provider and model for new chat sessions. “Default” uses the global default provider; “Same as provider” uses that provider's selected model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ingestion:
            // Ingestion runs three phases (Planner → Executor → Finalizer) as
            // separate sessions on ONE shared subprocess, built from a single
            // provider. So there's one provider pin for the whole import, then
            // an independently-honored model per phase.
            Section {
                Picker("Provider", selection: ingestionProviderBinding) {
                    Text("Default").tag("")
                    ForEach(config.enabledProviders) { provider in
                        Text(provider.label).tag(provider.id)
                    }
                }

                ForEach(ACPIngestStage.allCases, id: \.rawValue) { stage in
                    ingestModelPicker(for: stage)
                }
            } header: {
                Text("Ingestion")
            } footer: {
                Text("All three phases run on one provider (Planner / Executor / Finalizer share a subprocess). Each phase can use a different model — e.g. a cheaper one for the Executor. “Same as provider” uses the provider's Default Model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .lint:
            Section {
                StageProviderModelPicker(
                    stageKey: "lint",
                    config: $config,
                    containerDirectory: containerDirectory,
                    label: "Lint Model")
            } header: {
                Text("Lint Model")
            } footer: {
                Text("Provider and model for wiki lint runs. “Default” uses the global default provider; “Same as provider” uses that provider's selected model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .summary:
            Section {
                StageProviderModelPicker(
                    stageKey: "summarizer",
                    config: $config,
                    containerDirectory: containerDirectory,
                    label: "Summary Model",
                    defaultOptionLabel: "Default (first few sentences)")
            } header: {
                Text("Message Summary")
            } footer: {
                Text("“Default (first few sentences)” is free truncation — no model call. Pin a provider + model to summarize each assistant message with an LLM (computed once, cached).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Ingestion (single provider, per-phase model)

    /// The provider that runs the whole import. Reads the planner pin (the
    /// shared subprocess is built from it) and, on change, sets the SAME pin for
    /// all three phases so resolution is uniform — they genuinely share one
    /// subprocess only when they resolve to the same provider.
    private var ingestionProviderBinding: Binding<String> {
        Binding(
            get: { config.stageProviderIds[ACPIngestStage.planner.rawValue] ?? "" },
            set: { newID in
                var updated = config
                for stage in ACPIngestStage.allCases {
                    updated = updated.settingStageProvider(
                        newID.isEmpty ? nil : newID, forStage: stage.rawValue)
                }
                save(updated)
            })
    }

    /// The resolved ingestion provider (its cached models feed the per-phase
    /// model pickers).
    private var ingestionProvider: AgentProvider {
        config.provider(forStage: ACPIngestStage.planner.rawValue)
    }

    /// A model-only picker for one ingest phase. Options come from the ingestion
    /// provider's discovered models; `""` = "Same as provider" (the provider's
    /// Default Model).
    @ViewBuilder
    private func ingestModelPicker(for stage: ACPIngestStage) -> some View {
        let models = config.cachedModels(forProvider: ingestionProvider.id)
        let fallback = config.selectedModelId(forProvider: ingestionProvider.id) ?? "default"
        Picker("\(stage.label) Model", selection: ingestModelBinding(for: stage)) {
            if models.isEmpty {
                Text("Refresh this provider's models in the Providers tab").tag("")
            } else {
                Text("Same as provider (\(fallback))").tag("")
                ForEach(models, id: \.modelId) { model in
                    Text(model.displayLabel).tag(model.modelId)
                }
            }
        }
        .disabled(models.isEmpty)
    }

    private func ingestModelBinding(for stage: ACPIngestStage) -> Binding<String> {
        Binding(
            get: { config.ingestStageModelIds[stage.rawValue] ?? "" },
            set: { newID in
                save(config.settingIngestStageModel(
                    newID.isEmpty ? nil : newID, forStage: stage.rawValue))
            })
    }

    // MARK: - Persistence

    private func save(_ updated: AgentProvidersConfig) {
        config = updated
        do {
            try updated.save(to: containerDirectory)
        } catch {
            DebugLog.store("OperationsSettingsView save failed: \(error.localizedDescription)")
        }
    }
}
