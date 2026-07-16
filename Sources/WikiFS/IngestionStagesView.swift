import SwiftUI
import WikiFSCore

/// Reusable view for configuring ingestion stage assignments — which provider
/// and model handle each stage (planner / executor / finalizer) of the
/// ingestion pipeline. Extracted from `AgentsSettingsView` so it can appear
/// both in Settings → Agents and in the Agent Queue activity window's gear
/// button sheet (issue #449).
///
/// Loads its own `AgentProvidersConfig` from `containerDirectory` and
/// auto-saves on every edit, mirroring the persistence pattern of
/// `AgentsSettingsView`.
struct IngestionStagesView: View {
    @State private var config: AgentProvidersConfig

    let containerDirectory: URL

    init(containerDirectory: URL) {
        self.containerDirectory = containerDirectory
        _config = State(initialValue: AgentProvidersConfig.loadOrSeed(from: containerDirectory))
    }

    var body: some View {
        Form {
            Section {
                stageRow(.planner, label: "Planner")
                stageRow(.executor, label: "Executor")
                stageRow(.finalizer, label: "Finalizer")
            } header: {
                Text("Ingestion Stages")
            } footer: {
                Text("Unset stages use the default provider and its selected model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 200)
    }

    // MARK: - Stage rows

    private func stageRow(_ stage: IngestStage, label: String) -> some View {
        let assignment = config.stageAssignments[stage]
        let providerId = assignment?.providerId
        let provider = providerId.flatMap { config.provider(id: $0) }

        return HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)

            Picker("", selection: providerPickerBinding(for: stage)) {
                Text("App default").tag(Optional<String>.none)
                ForEach(config.enabledProviders) { provider in
                    Text(provider.label).tag(Optional(provider.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Picker("", selection: modelPickerBinding(for: stage)) {
                Text("Provider default").tag(Optional<String>.none)
                ForEach(provider.map { config.cachedModels(forProvider: $0.id) } ?? []) { model in
                    Text(model.name).tag(Optional(model.modelId))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(provider == nil)
        }
    }

    private func providerPickerBinding(for stage: IngestStage) -> Binding<String?> {
        Binding(
            get: { config.stageAssignments[stage]?.providerId },
            set: { newValue in
                var assignments = config.stageAssignments
                if let newValue {
                    assignments[stage] = StageAssignment(providerId: newValue, modelId: nil)
                } else {
                    assignments.removeValue(forKey: stage)
                }
                save(AgentProvidersConfig(
                    providers: config.providers,
                    providerModels: config.providerModels,
                    selectedModelIds: config.selectedModelIds,
                    favoriteModelIds: config.favoriteModelIds,
                    stageAssignments: assignments))
            })
    }

    private func modelPickerBinding(for stage: IngestStage) -> Binding<String?> {
        Binding(
            get: { config.stageAssignments[stage]?.modelId },
            set: { newValue in
                guard let providerId = config.stageAssignments[stage]?.providerId else { return }
                var assignments = config.stageAssignments
                assignments[stage] = StageAssignment(providerId: providerId, modelId: newValue)
                save(AgentProvidersConfig(
                    providers: config.providers,
                    providerModels: config.providerModels,
                    selectedModelIds: config.selectedModelIds,
                    favoriteModelIds: config.favoriteModelIds,
                    stageAssignments: assignments))
            })
    }

    // MARK: - Persistence

    private func save(_ updated: AgentProvidersConfig) {
        config = updated
        try? config.save(to: containerDirectory)
    }
}
