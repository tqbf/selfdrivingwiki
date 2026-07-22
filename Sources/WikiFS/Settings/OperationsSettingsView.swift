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
            // separate ACP sessions. Each phase resolves its OWN provider + model
            // (#727: `providerChain(forStage:)` per phase). When phases share a
            // provider they reuse one warm subprocess and the Executor inherits
            // the Planner's context; pinning different providers spawns separate
            // subprocesses for those phases.
            Section {
                ForEach(ACPIngestStage.allCases, id: \.rawValue) { stage in
                    StageProviderModelPicker(
                        stageKey: stage.rawValue,
                        config: $config,
                        containerDirectory: containerDirectory,
                        label: stage.label)
                }
            } header: {
                Text("Ingest Phases")
            } footer: {
                Text("Each phase can run on its own provider and model. Leaving them on the same provider is more efficient — the phases share a warm subprocess and the Executor inherits the Planner's context. “Default” uses the global default provider; “Same as provider” uses that provider's Default Model.")
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

}
