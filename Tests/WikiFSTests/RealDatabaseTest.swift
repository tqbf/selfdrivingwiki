import Testing
@testable import WikiFSCore

/// Regression test for the LLM-hallucinated escaped-bracket pattern seen in production.
/// Uses inline markdown that reproduces the real failures found across 7 live pages.
struct RealDatabaseTest {
    @Test func testRealHallucinations() {
        let markdown = """
            See [[source:The Value of Beliefs#"quote"\\]] for details.
            Also [[Information Seeking (neuroscience)\\]] and [[Page|alias\\]].
            This [[normal link]] should be untouched.
            And [[source:Doc#"passage"\\]] is another common pattern.
            """

        let fixed = WikiLinkFixer.applyFixes(to: markdown)

        #expect(fixed.contains("[[source:The Value of Beliefs#\"quote\"]]"))
        #expect(fixed.contains("[[Information Seeking (neuroscience)]]"))
        #expect(fixed.contains("[[Page|alias]]"))
        #expect(fixed.contains("[[normal link]]"))
        #expect(fixed.contains("[[source:Doc#\"passage\"]]"))
        #expect(!fixed.contains("\\]]"))
    }
}
