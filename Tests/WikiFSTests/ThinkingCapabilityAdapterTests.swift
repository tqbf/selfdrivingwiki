import Foundation
import Testing
@testable import WikiFSCore

@Suite struct ThinkingCapabilityAdapterTests {
    private let models = [
        CachedModelInfo(modelId: ModelID(rawValue: "gpt[low]"), name: "GPT (Low)"),
        CachedModelInfo(modelId: ModelID(rawValue: "gpt[high]"), name: "GPT (High)"),
    ]

    @Test func recognizesSupportedCodexVariantFamilies() throws {
        let fingerprint = ACPAgentFingerprint(
            identity: ACPAgentIdentity(rawValue: "codex-acp"),
            version: ACPAgentVersion(rawValue: "1.4.0"))
        let result = try #require(CodexThinkingCapabilityAdapter.resolve(
            fingerprint: fingerprint,
            selectedModelID: models[1].modelId,
            models: models))
        #expect(result.source == .agentAdapter(adapterID: CodexThinkingCapabilityAdapter.adapterID))
        #expect(result.defaultValueID == ChatConfigurationValueID(rawValue: "high"))
        #expect(result.mechanism.modelID(for: ChatConfigurationValueID(rawValue: "low")) == models[0].modelId)
    }

    @Test(arguments: [
        ACPAgentFingerprint(identity: ACPAgentIdentity(rawValue: "other"), version: ACPAgentVersion(rawValue: "1.4.0")),
        ACPAgentFingerprint(identity: ACPAgentIdentity(rawValue: "codex-acp"), version: nil),
        ACPAgentFingerprint(identity: ACPAgentIdentity(rawValue: "codex-acp"), version: ACPAgentVersion(rawValue: "2.0.0")),
        ACPAgentFingerprint(identity: ACPAgentIdentity(rawValue: "codex-acp"), version: ACPAgentVersion(rawValue: "opaque")),
    ])
    func rejectsIdentityAndVersionMismatches(_ fingerprint: ACPAgentFingerprint) {
        #expect(CodexThinkingCapabilityAdapter.resolve(
            fingerprint: fingerprint,
            selectedModelID: models[0].modelId,
            models: models) == nil)
    }

    @Test func exactOpaqueVersionMatchesOnlyExactly() {
        let predicate = ACPAgentVersionPredicate.exact(ACPAgentVersion(rawValue: "release-7"))
        #expect(predicate.contains(ACPAgentVersion(rawValue: "release-7")))
        #expect(!predicate.contains(ACPAgentVersion(rawValue: "release-8")))
        #expect(!predicate.contains(nil))
    }

    @Test func registryRejectsMismatchOverlapAndMalformedEntries() throws {
        let identity = ACPAgentIdentity(rawValue: "agent")
        let modelID = ModelID(rawValue: "model")
        let firstID = ThinkingCapabilityOverrideID(rawValue: "first")
        let secondID = ThinkingCapabilityOverrideID(rawValue: "second")
        func entry(_ id: ThinkingCapabilityOverrideID) -> LocalThinkingCapabilityOverride {
            LocalThinkingCapabilityOverride(
                id: id,
                identity: identity,
                version: .exact(ACPAgentVersion(rawValue: "release-7")),
                modelIDs: [modelID],
                capability: ThinkingCapabilityCatalog(
                    choices: [ThinkingOptionCatalogChoice(
                        id: ChatConfigurationValueID(rawValue: "high"), label: "High")],
                    mechanism: .sessionConfig(
                        optionID: ChatConfigurationOptionID(rawValue: "thought_level")),
                    source: .localOverride(overrideID: id)))
        }
        #expect(throws: LocalThinkingCapabilityRegistryError.self) {
            try LocalThinkingCapabilityRegistry(entries: [entry(firstID), entry(secondID)])
        }
        let registry = try LocalThinkingCapabilityRegistry(entries: [entry(firstID)])
        #expect(registry.resolve(
            fingerprint: ACPAgentFingerprint(identity: identity, version: ACPAgentVersion(rawValue: "release-7")),
            modelID: modelID) != nil)
        #expect(registry.resolve(
            fingerprint: ACPAgentFingerprint(identity: identity, version: ACPAgentVersion(rawValue: "release-8")),
            modelID: modelID) == nil)
        #expect(throws: LocalThinkingCapabilityRegistryError.self) {
            try LocalThinkingCapabilityRegistry(schemaVersion: 2, entries: [])
        }
    }
}
