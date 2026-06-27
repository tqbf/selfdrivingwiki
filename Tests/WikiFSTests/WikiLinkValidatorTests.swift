import Testing
@testable import WikiFSCore

struct WikiLinkFixerTests {

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
}
