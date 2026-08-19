#if os(macOS)
import Testing
@testable import WikiFS
import WikiFSEngine
import WikiFSCore

@Suite struct ThinkingEffortPresentationTests {
    private let provider = AgentProvider(
        id: ProviderID(rawValue: "provider"),
        label: "Provider",
        enabled: true,
        isDefault: true)

    private func model(
        choices: [(String, String)] = [("low", "Low"), ("high", "High")],
        defaultID: String = "low"
    ) -> CachedModelInfo {
        CachedModelInfo(
            modelId: ModelID(rawValue: "model"),
            name: "Model",
            thinkingOptionCatalog: ThinkingOptionCatalog(
                configOptionID: ChatConfigurationOptionID(rawValue: "reasoning_mode"),
                choices: choices.map {
                    ThinkingOptionCatalogChoice(
                        id: ChatConfigurationValueID(rawValue: $0.0), label: $0.1)
                },
                defaultValueID: ChatConfigurationValueID(rawValue: defaultID)),
            isDefault: true)
    }

    private func config(model: CachedModelInfo) -> AgentProvidersConfig {
        AgentProvidersConfig(
            providers: [provider],
            providerModels: [provider.id.rawValue: [model]],
            selectedModelIds: [provider.id.rawValue: model.modelId])
    }

    @Test func idleRestoredChatUsesCatalogWithoutLiveOption() {
        let state = ThinkingEffortPresentation.resolve(
            config: config(model: model()),
            providerID: provider.id,
            modelID: ModelID(rawValue: "model"),
            configuredID: ChatConfigurationValueID(rawValue: "high"),
            liveOption: nil)

        #expect(state.shouldRender)
        #expect(state.effectiveLabel == "High")
        #expect(state.configOptionID == ChatConfigurationOptionID(rawValue: "reasoning_mode"))
    }

    @Test func staleConfiguredIntentShowsCatalogFallback() {
        let state = ThinkingEffortPresentation.resolve(
            config: config(model: model()),
            providerID: provider.id,
            modelID: ModelID(rawValue: "model"),
            configuredID: ChatConfigurationValueID(rawValue: "maximum"),
            liveOption: nil)

        #expect(state.effectiveLabel == "Low")
        #expect(state.isUsingFallback)
    }

    @Test func hidesNonselectableCapabilityEvenWhenItHasChoices() {
        let value = ChatConfigurationValueID(rawValue: "external")
        let capability = ThinkingCapabilityCatalog(
            choices: [ThinkingOptionCatalogChoice(id: value, label: "External")],
            defaultValueID: value,
            mechanism: .sessionConfig(
                optionID: ChatConfigurationOptionID(rawValue: "external")),
            source: .localOverride(
                overrideID: ThinkingCapabilityOverrideID(rawValue: "external")),
            isSelectable: false)
        let state = ThinkingEffortPresentation.from(ThinkingSelectionResolution(
            capability: capability,
            configuredValueID: value,
            effectiveValueID: value))

        #expect(!state.shouldRender)
    }

    @Test func hidesWhenCatalogAndLiveChoicesAreEmpty() {
        let plain = CachedModelInfo(
            modelId: ModelID(rawValue: "plain"), name: "Plain", isDefault: true)
        let state = ThinkingEffortPresentation.resolve(
            config: config(model: plain),
            providerID: provider.id,
            modelID: plain.modelId,
            configuredID: nil,
            liveOption: nil)
        #expect(!state.shouldRender)
    }

    @Test func codexModelVariantsShowSeparateThinkingSelectorWithoutConfigOption() {
        let variants = [
            CachedModelInfo(
                modelId: ModelID(rawValue: "gpt-5.6-sol[low]"),
                name: "GPT-5.6-Sol (low)",
                isDefault: true),
            CachedModelInfo(
                modelId: ModelID(rawValue: "gpt-5.6-sol[high]"),
                name: "GPT-5.6-Sol (high)"),
        ]
        let fingerprint = ACPAgentFingerprint(
            identity: CodexThinkingCapabilityAdapter.identity,
            version: ACPAgentVersion(rawValue: "1.2.3"))
        let observation = ACPProviderCatalogObservation(
            providerID: provider.id,
            fingerprint: fingerprint,
            models: variants,
            currentModelID: variants[1].modelId,
            thinkingCapability: nil)
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: [provider.id.rawValue: variants],
            selectedModelIds: [provider.id.rawValue: variants[1].modelId],
            catalogObservations: [provider.id.rawValue: observation])
        let state = ThinkingEffortPresentation.resolve(
            config: config,
            providerID: provider.id,
            modelID: variants[1].modelId,
            configuredID: nil,
            liveOption: nil)

        #expect(state.shouldRender)
        #expect(state.effectiveLabel == "High")
        #expect(state.modelIDByValueID[ChatConfigurationValueID(rawValue: "low")]
            == variants[0].modelId)
        #expect(state.configOptionID == nil)
    }

    @Test func unrelatedBracketedProviderDoesNotGainThinkingCapability() {
        let variants = [
            CachedModelInfo(
                modelId: ModelID(rawValue: "model[low]"), name: "Model (low)", isDefault: true),
            CachedModelInfo(
                modelId: ModelID(rawValue: "model[high]"), name: "Model (high)"),
        ]
        let observation = ACPProviderCatalogObservation(
            providerID: provider.id,
            fingerprint: ACPAgentFingerprint(
                identity: ACPAgentIdentity(rawValue: "unrelated-agent"),
                version: ACPAgentVersion(rawValue: "1.2.3")),
            models: variants,
            currentModelID: variants[0].modelId,
            thinkingCapability: nil)
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: [provider.id.rawValue: variants],
            selectedModelIds: [provider.id.rawValue: variants[0].modelId],
            catalogObservations: [provider.id.rawValue: observation])
        let state = ThinkingEffortPresentation.resolve(
            config: config,
            providerID: provider.id,
            modelID: variants[0].modelId,
            configuredID: nil,
            liveOption: nil)
        #expect(!state.shouldRender)
    }

    @Test func providerRefreshRecomputesChoicesDefaultAndLabel() {
        let old = ThinkingEffortPresentation.resolve(
            config: config(model: model()),
            providerID: provider.id,
            modelID: ModelID(rawValue: "model"),
            configuredID: nil,
            liveOption: nil)
        let refreshed = ThinkingEffortPresentation.resolve(
            config: config(model: model(
                choices: [("medium", "Balanced"), ("maximum", "Maximum")],
                defaultID: "maximum")),
            providerID: provider.id,
            modelID: ModelID(rawValue: "model"),
            configuredID: nil,
            liveOption: nil)

        #expect(old.effectiveLabel == "Low")
        #expect(refreshed.effectiveLabel == "Maximum")
        #expect(refreshed.choices.map(\.label) == ["Balanced", "Maximum"])
    }
}
#endif
