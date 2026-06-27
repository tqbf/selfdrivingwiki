import Testing
@testable import WikiFSCore

struct WikiLinkFixerTests {

    // MARK: - Single link (fix)

    @Test func testNormalLink() {
        let result = WikiLinkFixer.fix(target: "Page Name", alias: "alias")
        #expect(result.target == "Page Name")
        #expect(result.alias == "alias")
        #expect(result.wasModified == false)
    }

    @Test func testEscapedBracketInTarget() {
        // LLM writes: [[source:Doc\]]
        let result = WikiLinkFixer.fix(target: "source:Doc\\", alias: nil)
        #expect(result.target == "source:Doc")
        #expect(result.alias == nil)
        #expect(result.wasModified == true)
    }

    @Test func testEscapedBracketInAlias() {
        // LLM writes: [[Page|My alias\]]
        let result = WikiLinkFixer.fix(target: "Page", alias: "My alias\\")
        #expect(result.target == "Page")
        #expect(result.alias == "My alias")
        #expect(result.wasModified == true)
    }

    // MARK: - Batch (applyFixes) — patterns from production pages

    @Test func testApplyFixesProductionPatterns() {
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

    @Test func testApplyFixesUnchangedWhenClean() {
        let markdown = "See [[Page Name]] and [[source:Doc#\"quote\"]] here."
        #expect(WikiLinkFixer.applyFixes(to: markdown) == markdown)
    }
}
