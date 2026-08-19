import Foundation
import Testing
@testable import WikiFSCore

@Suite struct CachedModelInfoCompatibilityTests {
    private let low = ChatConfigurationValueID(rawValue: "low")
    private let high = ChatConfigurationValueID(rawValue: "high")

    private func model(defaultValueID: ChatConfigurationValueID? = nil) -> CachedModelInfo {
        CachedModelInfo(
            modelId: ModelID(rawValue: "model"),
            name: "Model",
            thinkingOptionCatalog: ThinkingOptionCatalog(
                configOptionID: ChatConfigurationOptionID(rawValue: "reasoning_mode"),
                choices: [
                    ThinkingOptionCatalogChoice(id: low, label: "Low"),
                    ThinkingOptionCatalogChoice(id: high, label: "High"),
                ],
                defaultValueID: defaultValueID))
    }

    @Test func legacyCachedModelJSONDecodesWithoutThinkingMetadata() throws {
        let data = Data(#"{"modelId":"legacy","name":"Legacy","description":null}"#.utf8)
        let model = try JSONDecoder().decode(CachedModelInfo.self, from: data)

        #expect(model.modelId == ModelID(rawValue: "legacy"))
        #expect(model.thinkingOptionCatalog == nil)
        #expect(!model.isDefault)
    }

    @Test func catalogRoundTripsTypedIDsAndChoiceOrder() throws {
        let original = model(defaultValueID: high)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedModelInfo.self, from: data)

        #expect(decoded == original)
        #expect(decoded.thinkingOptionCatalog?.choices.map(\.id) == [low, high])
    }
}
