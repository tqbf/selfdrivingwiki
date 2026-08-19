import Testing
@testable import WikiFSCore

@Suite struct ThinkingEffortModelLabelTests {
    @Test(
        "Removes recognized effort suffix without live metadata",
        arguments: [
            ("GPT-5.6-Luna (Low)", "GPT-5.6-Luna"),
            ("GPT-5.6-Luna [High]", "GPT-5.6-Luna"),
            ("GPT-5.6-Luna (Extra High)", "GPT-5.6-Luna"),
            ("GPT-5.6-Luna (xhigh)", "GPT-5.6-Luna"),
        ]
    )
    func removesRecognizedSuffixWithoutLiveMetadata(modelName: String, expected: String) {
        #expect(ThinkingEffortModelLabel.displayName(for: modelName) == expected)
    }

    @Test(
        "Preserves unrelated trailing qualifiers",
        arguments: [
            "GPT-5.6-Luna (beta)",
            "GPT-5.6-Luna [preview]",
            "GPT-5.6-Luna (2026-08-17)",
            "GPT-5.6-Luna",
        ]
    )
    func preservesUnrelatedTrailingQualifier(modelName: String) {
        #expect(ThinkingEffortModelLabel.displayName(for: modelName) == modelName)
    }

    @Test func removesProviderAdvertisedAlias() {
        #expect(
            ThinkingEffortModelLabel.displayName(
                for: "GPT-5.6-Luna (Maximum)",
                advertisedEfforts: ["Maximum"]
            ) == "GPT-5.6-Luna"
        )
    }

    @Test func returnsNormalizedVariantEffort() throws {
        let variant = try #require(
            ThinkingEffortModelLabel.variant(
                in: "GPT-5.6-Luna [ High ]"
            )
        )

        #expect(variant.baseName == "GPT-5.6-Luna")
        #expect(variant.effort == "high")
    }
}
