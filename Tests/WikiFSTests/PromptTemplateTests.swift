import Testing
@testable import WikiFSCore

/// `PromptTemplate.fill` unit tests — the helper the templated prompt builders
/// rely on. Covers the contract: known tokens substitute, unknown tokens stay
/// intact (no silent drop), inserted values are not re-scanned (no recursive
/// expansion), and adjacent/multi-token templates work.
struct PromptTemplateTests {

    @Test func substitutesKnownTokens() {
        #expect(PromptTemplate.fill("{{a}}/{{b}}", ["a": "1", "b": "2"]) == "1/2")
    }

    @Test func leavesUnknownTokensIntact() {
        #expect(PromptTemplate.fill("{{a}}/{{missing}}", ["a": "1"]) == "1/{{missing}}")
    }

    @Test func doesNotRescanInsertedValues() {
        // A value containing "{{a}}" must not be re-expanded into itself.
        #expect(PromptTemplate.fill("{{x}}", ["x": "{{x}}"]) == "{{x}}")
        #expect(PromptTemplate.fill("{{a}}", ["a": "[[{{b}}]]"]) == "[[{{b}}]]")
    }

    @Test func handlesAdjacentTokens() {
        #expect(PromptTemplate.fill("{{a}}{{b}}", ["a": "1", "b": "2"]) == "12")
    }

    @Test func passesThroughTemplateWithNoTokens() {
        #expect(PromptTemplate.fill("no tokens here", [:]) == "no tokens here")
    }

    @Test func allowsUnderscoresAndDigitsInNames() {
        #expect(PromptTemplate.fill("{{page_count_2}}", ["page_count_2": "7"]) == "7")
    }

    @Test func preservesSurroundingText() {
        #expect(
            PromptTemplate.fill(
                "Current contents: {{n}} page{{noun}}.",
                ["n": "3", "noun": "s"])
            == "Current contents: 3 pages.")
    }
}
