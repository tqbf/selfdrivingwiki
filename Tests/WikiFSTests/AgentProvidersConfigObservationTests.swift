import Foundation
import Testing
@testable import WikiFSCore

@Suite struct AgentProvidersConfigObservationTests {
    @Test func catalogObservationRoundTripsAcrossReload() throws {
        let providerID = ProviderID(rawValue: "provider")
        let model = CachedModelInfo(modelId: ModelID(rawValue: "model"), name: "Model")
        let fingerprint = ACPAgentFingerprint(
            identity: ACPAgentIdentity(rawValue: "agent"),
            version: ACPAgentVersion(rawValue: "1.2.3"),
            title: "Agent Title")
        let observation = ACPProviderCatalogObservation(
            providerID: providerID,
            fingerprint: fingerprint,
            models: [model],
            currentModelID: model.modelId,
            thinkingCapability: ThinkingCapabilityCatalog(
                choices: [ThinkingOptionCatalogChoice(
                    id: ChatConfigurationValueID(rawValue: "high"), label: "High")],
                defaultValueID: ChatConfigurationValueID(rawValue: "high"),
                mechanism: .sessionConfig(
                    optionID: ChatConfigurationOptionID(rawValue: "reasoning_mode")),
                source: .observedACP))
        let original = AgentProvidersConfig(
            providers: [AgentProvider(id: providerID, label: "Provider")],
            catalogObservations: [providerID.rawValue: observation],
            generation: 7)
        let decoded = try JSONDecoder().decode(
            AgentProvidersConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded.catalogObservation(forProvider: providerID) == observation)
        #expect(decoded.generation == 7)
    }

    @Test func decodesLegacyCatalogWithoutFingerprintOrNormalizedCapability() throws {
        let json = #"""
        {
          "providers":[{"id":"provider","label":"Provider","env":{},"enabled":true,"isDefault":true}],
          "providerModels":{"provider":[{
            "modelId":"model","name":"Model","isDefault":true,
            "thinkingOptionCatalog":{
              "configOptionID":"thought_level",
              "choices":[{"id":"high","label":"High"}],
              "defaultValueID":"high"
            }
          },{
            "modelId":"plain","name":"Plain","isDefault":false
          }]}
        }
        """#
        let decoded = try JSONDecoder().decode(
            AgentProvidersConfig.self, from: Data(json.utf8))
        #expect(decoded.catalogObservations.isEmpty)
        #expect(decoded.generation == 0)
        let resolution = decoded.resolveThinkingCapability(
            providerID: ProviderID(rawValue: "provider"),
            modelID: ModelID(rawValue: "model"))
        #expect(resolution.source == ThinkingCapabilitySource.observedACP)
        #expect(resolution.effectiveValueID == ChatConfigurationValueID(rawValue: "high"))
        #expect(decoded.resolveThinkingCapability(
            providerID: ProviderID(rawValue: "provider"),
            modelID: ModelID(rawValue: "plain")).capability == nil)
    }

    @Test func observedCapabilityAppliesOnlyToObservedCurrentModel() {
        let providerID = ProviderID(rawValue: "provider")
        let first = CachedModelInfo(modelId: ModelID(rawValue: "first"), name: "First")
        let second = CachedModelInfo(modelId: ModelID(rawValue: "second"), name: "Second")
        let capability = ThinkingCapabilityCatalog(
            choices: [ThinkingOptionCatalogChoice(
                id: ChatConfigurationValueID(rawValue: "high"), label: "High")],
            mechanism: .sessionConfig(
                optionID: ChatConfigurationOptionID(rawValue: "thought_level")),
            source: .observedACP)
        let observation = ACPProviderCatalogObservation(
            providerID: providerID,
            fingerprint: nil,
            models: [first, second],
            currentModelID: first.modelId,
            thinkingCapability: capability)
        let config = AgentProvidersConfig(
            providers: [AgentProvider(id: providerID, label: "Provider")],
            providerModels: [providerID.rawValue: [first, second]],
            catalogObservations: [providerID.rawValue: observation])

        #expect(config.resolveThinkingCapability(
            providerID: providerID, modelID: first.modelId).capability != nil)
        #expect(config.resolveThinkingCapability(
            providerID: providerID, modelID: second.modelId).capability == nil)
    }

    @Test func explicitUnknownModelDoesNotUseAnotherModelsCapability() {
        let providerID = ProviderID(rawValue: "provider")
        let knownModel = ModelID(rawValue: "known")
        let config = AgentProvidersConfig(
            providers: [AgentProvider(id: providerID, label: "Provider")],
            providerModels: [providerID.rawValue: [CachedModelInfo(
                modelId: knownModel,
                name: "Known",
                thinkingOptionCatalog: ThinkingOptionCatalog(
                    configOptionID: ChatConfigurationOptionID(rawValue: "thought_level"),
                    choices: [ThinkingOptionCatalogChoice(
                        id: ChatConfigurationValueID(rawValue: "high"), label: "High")],
                    defaultValueID: ChatConfigurationValueID(rawValue: "high")),
                isDefault: true)]])

        let resolution = config.resolveThinkingCapability(
            providerID: providerID,
            modelID: ModelID(rawValue: "removed"))

        #expect(resolution.capability == nil)
        #expect(!resolution.shouldRenderSelector)
    }

    @Test func unrelatedMutationCarriesObservationAndGeneration() {
        let providerID = ProviderID(rawValue: "provider")
        let observation = ACPProviderCatalogObservation(
            providerID: providerID,
            fingerprint: nil,
            models: [CachedModelInfo(modelId: ModelID(rawValue: "model"), name: "Model")],
            currentModelID: ModelID(rawValue: "model"),
            thinkingCapability: nil)
        let config = AgentProvidersConfig(
            providers: [AgentProvider(id: providerID, label: "Provider")],
            catalogObservations: [providerID.rawValue: observation],
            generation: 11)
        let updated = config.togglingFavoriteModel(
            ModelID(rawValue: "model"), forProvider: providerID)
        #expect(updated.catalogObservation(forProvider: providerID) == observation)
        #expect(updated.generation == 11)
    }
}
