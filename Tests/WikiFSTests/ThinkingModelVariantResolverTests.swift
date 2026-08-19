import Testing
@testable import WikiFSCore

@Suite struct CodexThinkingModelVariantParserTests {
    private let models = [
        CachedModelInfo(modelId: ModelID(rawValue: "gpt-5.6-sol[low]"), name: "GPT-5.6-Sol (low)"),
        CachedModelInfo(modelId: ModelID(rawValue: "gpt-5.6-sol[medium]"), name: "GPT-5.6-Sol (medium)"),
        CachedModelInfo(modelId: ModelID(rawValue: "gpt-5.6-sol[high]"), name: "GPT-5.6-Sol (high)"),
        CachedModelInfo(modelId: ModelID(rawValue: "gpt-5.6-sol[xhigh]"), name: "GPT-5.6-Sol (xhigh)"),
    ]

    @Test func derivesChoicesFromStructuredAdvertisedModelIDs() throws {
        let family = try #require(CodexThinkingModelVariantParser.family(
            containing: ModelID(rawValue: "gpt-5.6-sol[high]"),
            models: models))
        #expect(family.baseModelID == "gpt-5.6-sol")
        #expect(family.choices.map(\.id.rawValue) == ["low", "medium", "high", "xhigh"])
        #expect(family.choices.map(\.label) == ["Low", "Medium", "High", "Extra High"])
        #expect(family.modelID(for: ChatConfigurationValueID(rawValue: "medium"))
            == ModelID(rawValue: "gpt-5.6-sol[medium]"))
    }

    @Test func singleBracketedModelDoesNotInventCapability() {
        let single = [CachedModelInfo(
            modelId: ModelID(rawValue: "model[preview]"), name: "Model [preview]")]
        #expect(CodexThinkingModelVariantParser.family(
            containing: single[0].modelId, models: single) == nil)
    }
}
