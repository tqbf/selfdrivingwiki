import Testing
@testable import WikiFSCore

@Suite struct ChatCatalogSelectionResolverTests {
    private let providerA = AgentProvider(
        id: ProviderID(rawValue: "a"), label: "A", enabled: true, isDefault: true)
    private let providerB = AgentProvider(
        id: ProviderID(rawValue: "b"), label: "B", enabled: true, isDefault: false)
    private let aFirst = CachedModelInfo(modelId: ModelID(rawValue: "a-first"), name: "A First")
    private let aDefault = CachedModelInfo(
        modelId: ModelID(rawValue: "a-default"), name: "A Default", isDefault: true)
    private let bModel = CachedModelInfo(
        modelId: ModelID(rawValue: "b-model"), name: "B Model", isDefault: true)

    private var config: AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [providerA, providerB],
            providerModels: [
                providerA.id.rawValue: [aFirst, aDefault],
                providerB.id.rawValue: [bModel],
            ],
            selectedModelIds: [:],
            stageProviderIds: ["chat": providerB.id])
    }

    @Test func providerOnlyOverrideUsesDiscoveredDefaultModel() {
        let selection = config.resolvedChatCatalogSelection(
            chatOverrideProviderID: providerA.id,
            chatOverrideModelID: nil)
        #expect(selection.provider.id == providerA.id)
        #expect(selection.model?.modelId == aDefault.modelId)
    }

    @Test func nilOverrideUsesStageProviderAndItsDefaultModel() {
        let selection = config.resolvedChatCatalogSelection()
        #expect(selection.provider.id == providerB.id)
        #expect(selection.model?.modelId == bModel.modelId)
    }

    @Test func explicitModelOverrideWinsWithinProvider() {
        let selection = config.resolvedChatCatalogSelection(
            chatOverrideProviderID: providerA.id,
            chatOverrideModelID: aFirst.modelId)
        #expect(selection.model?.modelId == aFirst.modelId)
    }

    @Test func missingCatalogReturnsNilModel() {
        let missing = AgentProvider(
            id: ProviderID(rawValue: "missing"), label: "Missing", enabled: true, isDefault: true)
        let selection = AgentProvidersConfig(providers: [missing]).resolvedChatCatalogSelection()
        #expect(selection.provider.id == missing.id)
        #expect(selection.model == nil)
    }
}
