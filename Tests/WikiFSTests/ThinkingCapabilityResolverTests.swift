import Testing
@testable import WikiFSCore

@Suite struct ThinkingCapabilityResolverTests {
    private let providerID = ProviderID(rawValue: "provider")
    private let modelID = ModelID(rawValue: "model")
    private let fingerprint = ACPAgentFingerprint(
        identity: CodexThinkingCapabilityAdapter.identity,
        version: ACPAgentVersion(rawValue: "1.2.3"))
    private let low = ChatConfigurationValueID(rawValue: "low")
    private let high = ChatConfigurationValueID(rawValue: "high")

    private func capability(
        source: ThinkingCapabilitySource,
        mechanism: ThinkingCapabilityMechanism? = nil,
        choices: [ChatConfigurationValueID]? = nil
    ) -> ThinkingCapabilityCatalog {
        let values = choices ?? [low, high]
        return ThinkingCapabilityCatalog(
            choices: values.map { ThinkingOptionCatalogChoice(id: $0, label: $0.rawValue.capitalized) },
            defaultValueID: values.first,
            mechanism: mechanism ?? .sessionConfig(
                optionID: ChatConfigurationOptionID(rawValue: "thought-level-option")),
            source: source,
            fingerprint: source == .observedACP ? nil : fingerprint,
            modelID: source == .observedACP ? nil : modelID)
    }

    private func observation(
        thinking: ThinkingCapabilityCatalog? = nil
    ) -> ACPProviderCatalogObservation {
        ACPProviderCatalogObservation(
            providerID: providerID,
            fingerprint: fingerprint,
            models: [CachedModelInfo(modelId: modelID, name: "Model")],
            currentModelID: modelID,
            thinkingCapability: thinking)
    }

    @Test func liveACPOutranksAllFallbackSources() throws {
        let liveOnly = ChatConfigurationValueID(rawValue: "live-only")
        let live = capability(source: .observedACP, choices: [liveOnly])
        let cached = capability(source: .observedACP)
        let adapter = capability(source: .agentAdapter(
            adapterID: ThinkingCapabilityAdapterID(rawValue: "codex")))
        let override = capability(source: .localOverride(
            overrideID: ThinkingCapabilityOverrideID(rawValue: "override")))

        let result = ThinkingCapabilityResolver.resolve(.init(
            selectedProviderID: providerID,
            selectedModelID: modelID,
            liveACP: live,
            liveCurrentValueID: liveOnly,
            cachedObservation: observation(thinking: cached),
            adapter: adapter,
            localOverride: override,
            configuredValueID: high))

        #expect(result.source == .observedACP)
        #expect(result.choices.map(\.id) == [liveOnly])
        #expect(result.effectiveValueID == liveOnly)
    }

    @Test(arguments: [
        (true, true, true, ThinkingCapabilitySource.observedACP),
        (false, true, true, ThinkingCapabilitySource.agentAdapter(
            adapterID: ThinkingCapabilityAdapterID(rawValue: "codex"))),
        (false, false, true, ThinkingCapabilitySource.localOverride(
            overrideID: ThinkingCapabilityOverrideID(rawValue: "override"))),
    ])
    func enforcesDiscoveryPriority(
        includeCached: Bool,
        includeAdapter: Bool,
        includeOverride: Bool,
        expected: ThinkingCapabilitySource
    ) {
        let cached = capability(source: .observedACP)
        let adapter = capability(source: .agentAdapter(
            adapterID: ThinkingCapabilityAdapterID(rawValue: "codex")))
        let override = capability(source: .localOverride(
            overrideID: ThinkingCapabilityOverrideID(rawValue: "override")))
        let result = ThinkingCapabilityResolver.resolve(.init(
            selectedProviderID: providerID,
            selectedModelID: modelID,
            cachedObservation: observation(thinking: includeCached ? cached : nil),
            adapter: includeAdapter ? adapter : nil,
            localOverride: includeOverride ? override : nil))
        #expect(result.source == expected)
    }

    @Test func mismatchedFingerprintAndModelFallThroughToNone() {
        let adapter = ThinkingCapabilityCatalog(
            choices: [ThinkingOptionCatalogChoice(id: low, label: "Low")],
            mechanism: .modelVariants(valueToModelID: [low: modelID]),
            source: .agentAdapter(adapterID: ThinkingCapabilityAdapterID(rawValue: "codex")),
            fingerprint: ACPAgentFingerprint(
                identity: ACPAgentIdentity(rawValue: "other"), version: nil),
            modelID: modelID)
        let result = ThinkingCapabilityResolver.resolve(.init(
            selectedProviderID: providerID,
            selectedModelID: modelID,
            cachedObservation: observation(),
            adapter: adapter))
        #expect(result.capability == nil)
        #expect(!result.shouldRenderSelector)
    }

    @Test func nonstandardCapabilityRequiresKnownMatchingFingerprints() {
        let override = ThinkingCapabilityCatalog(
            choices: [ThinkingOptionCatalogChoice(id: low, label: "Low")],
            mechanism: .sessionConfig(
                optionID: ChatConfigurationOptionID(rawValue: "override")),
            source: .localOverride(
                overrideID: ThinkingCapabilityOverrideID(rawValue: "override")),
            fingerprint: nil,
            modelID: modelID)
        let unknownObservation = ACPProviderCatalogObservation(
            providerID: providerID,
            fingerprint: nil,
            models: [CachedModelInfo(modelId: modelID, name: "Model")],
            currentModelID: modelID,
            thinkingCapability: nil)

        let result = ThinkingCapabilityResolver.resolve(.init(
            selectedProviderID: providerID,
            selectedModelID: modelID,
            cachedObservation: unknownObservation,
            localOverride: override))

        #expect(result.capability == nil)
    }

    @Test func legacyCodexSidecarUsesExactTrustedCommand() throws {
        let codexProviderID = ProviderID(rawValue: "codex-acp")
        let variants = [
            CachedModelInfo(
                modelId: ModelID(rawValue: "gpt-5.6-sol[low]"),
                name: "GPT-5.6-Sol (low)",
                isDefault: true),
            CachedModelInfo(
                modelId: ModelID(rawValue: "gpt-5.6-sol[high]"),
                name: "GPT-5.6-Sol (high)"),
        ]
        let provider = AgentProvider(
            id: codexProviderID,
            label: "Codex",
            command: ["npx", "@agentclientprotocol/codex-acp@1.1.7"],
            enabled: true,
            isDefault: true)
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: [codexProviderID.rawValue: variants])

        let result = config.resolveThinkingCapability(
            providerID: codexProviderID,
            modelID: nil)

        #expect(result.shouldRenderSelector)
        #expect(result.source == .agentAdapter(
            adapterID: CodexThinkingCapabilityAdapter.adapterID))
        #expect(result.effectiveValueID == ChatConfigurationValueID(rawValue: "low"))
        #expect(result.modelIDByValueID[ChatConfigurationValueID(rawValue: "high")]
            == variants[1].modelId)
    }

    @Test func observedFingerprintSuppressesLegacyCommandFallback() {
        let codexProviderID = ProviderID(rawValue: "codex-acp")
        let variants = [
            CachedModelInfo(
                modelId: ModelID(rawValue: "gpt[low]"),
                name: "GPT (low)",
                isDefault: true),
            CachedModelInfo(modelId: ModelID(rawValue: "gpt[high]"), name: "GPT (high)"),
        ]
        let provider = AgentProvider(
            id: codexProviderID,
            label: "Codex",
            command: ["npx", "@agentclientprotocol/codex-acp@1.1.7"],
            enabled: true,
            isDefault: true)
        let observedFingerprint = ACPAgentFingerprint(
            identity: CodexThinkingCapabilityAdapter.identity,
            version: ACPAgentVersion(rawValue: "2.0.0"))
        let observation = ACPProviderCatalogObservation(
            providerID: codexProviderID,
            fingerprint: observedFingerprint,
            models: variants,
            currentModelID: variants[0].modelId,
            thinkingCapability: nil)
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: [codexProviderID.rawValue: variants],
            catalogObservations: [codexProviderID.rawValue: observation])

        let result = config.resolveThinkingCapability(
            providerID: codexProviderID,
            modelID: variants[0].modelId)

        #expect(result.capability == nil)
        #expect(!result.shouldRenderSelector)
    }

    @Test func legacyCodexSidecarRejectsUntrustedCommand() {
        let codexProviderID = ProviderID(rawValue: "codex-acp")
        let variants = [
            CachedModelInfo(modelId: ModelID(rawValue: "gpt[low]"), name: "GPT (low)"),
            CachedModelInfo(modelId: ModelID(rawValue: "gpt[high]"), name: "GPT (high)"),
        ]
        let provider = AgentProvider(
            id: codexProviderID,
            label: "Codex",
            command: ["npx", "@agentclientprotocol/codex-acp@latest"],
            enabled: true,
            isDefault: true)
        let config = AgentProvidersConfig(
            providers: [provider],
            providerModels: [codexProviderID.rawValue: variants])

        let result = config.resolveThinkingCapability(
            providerID: codexProviderID,
            modelID: variants[0].modelId)

        #expect(result.capability == nil)
        #expect(!result.shouldRenderSelector)
    }

    @Test func hidesUnknownAndExternallyConfiguredCapability() {
        let diagnostic = ThinkingCapabilityCatalog(
            choices: [ThinkingOptionCatalogChoice(id: low, label: "Low")],
            mechanism: .sessionConfig(optionID: ChatConfigurationOptionID(rawValue: "external")),
            source: .localOverride(overrideID: ThinkingCapabilityOverrideID(rawValue: "external")),
            fingerprint: fingerprint,
            modelID: modelID,
            isSelectable: false)
        let result = ThinkingCapabilityResolver.resolve(.init(
            selectedProviderID: providerID,
            selectedModelID: modelID,
            cachedObservation: observation(),
            localOverride: diagnostic))
        #expect(result.capability == nil)
        #expect(!result.shouldRenderSelector)
    }
}
