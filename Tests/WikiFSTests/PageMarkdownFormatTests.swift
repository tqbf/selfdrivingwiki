import Foundation
import Testing
import WikiFSCore

struct PageMarkdownFormatTests {

    // MARK: - stripped: H1 present

    @Test func stripsMatchingH1() {
        let body = "# My Page\n\nSome content here."
        let result = PageMarkdownFormat.stripped(body: body, title: "My Page")
        #expect(result == "Some content here.")
    }

    @Test func stripsMatchingH1WithMultipleBlankLines() {
        let body = "# My Page\n\n\n\nSome content here."
        let result = PageMarkdownFormat.stripped(body: body, title: "My Page")
        #expect(result == "Some content here.")
    }

    @Test func doesNotStripH1WhenTitleMismatches() {
        let body = "# Other Title\n\nSome content here."
        let result = PageMarkdownFormat.stripped(body: body, title: "My Page")
        #expect(result == body)
    }

    // MARK: - stripped: frontmatter present

    @Test func stripsFrontmatterAndH1() {
        let body = "---\ntitle: \"My Page\"\ndate: 2026-06-28\n---\n\n# My Page\n\nSome content here."
        let result = PageMarkdownFormat.stripped(body: body, title: "My Page")
        #expect(result == "Some content here.")
    }

    @Test func stripsFrontmatterWithoutH1() {
        let body = "---\ntitle: \"My Page\"\n---\n\nSome content here."
        let result = PageMarkdownFormat.stripped(body: body, title: "My Page")
        #expect(result == "Some content here.")
    }

    @Test func stripsFrontmatterWhenH1Mismatches() {
        let body = "---\ntitle: \"Old Title\"\n---\n\n# Old Title\n\nSome content here."
        let result = PageMarkdownFormat.stripped(body: body, title: "My Page")
        // frontmatter is stripped; H1 doesn't match so it stays
        #expect(result == "# Old Title\n\nSome content here.")
    }

    // MARK: - stripped: no decoration

    @Test func returnsBodyUnchangedWhenNothingToStrip() {
        let body = "Some content here.\n\n## A section"
        let result = PageMarkdownFormat.stripped(body: body, title: "My Page")
        #expect(result == body)
    }

    @Test func returnsEmptyStringUnchanged() {
        let result = PageMarkdownFormat.stripped(body: "", title: "My Page")
        #expect(result == "")
    }

    // MARK: - fileContent

    @Test func fileContentContainsFrontmatterAndH1() {
        let page = WikiPage(
            id: PageID(rawValue: "01KW6BDW000000000000000000"),
            title: "My Page",
            slug: "my-page",
            bodyMarkdown: "Some content here.",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1
        )
        let content = PageMarkdownFormat.fileContent(for: page)
        #expect(content.hasPrefix("---\n"))
        #expect(content.contains("title: \"My Page\""))
        #expect(content.contains("# My Page"))
        #expect(content.contains("Some content here."))
    }

    @Test func fileContentStripsExistingH1BeforeGenerating() {
        let page = WikiPage(
            id: PageID(rawValue: "01KW6BDW000000000000000000"),
            title: "My Page",
            slug: "my-page",
            bodyMarkdown: "# My Page\n\nSome content here.",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1
        )
        let content = PageMarkdownFormat.fileContent(for: page)
        // H1 appears exactly once (the generated one)
        let h1Count = content.components(separatedBy: "# My Page").count - 1
        #expect(h1Count == 1)
        #expect(content.contains("Some content here."))
    }

    @Test func fileContentEscapesDoubleQuoteInTitle() {
        let page = WikiPage(
            id: PageID(rawValue: "01KW6BDW000000000000000000"),
            title: "It's a \"Test\"",
            slug: "its-a-test",
            bodyMarkdown: "Body.",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1
        )
        let content = PageMarkdownFormat.fileContent(for: page)
        #expect(content.contains("\\\"Test\\\""))
    }

    @Test func fileContentHandlesEmptyBody() {
        let page = WikiPage(
            id: PageID(rawValue: "01KW6BDW000000000000000000"),
            title: "Empty Page",
            slug: "empty-page",
            bodyMarkdown: "",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            version: 1
        )
        let content = PageMarkdownFormat.fileContent(for: page)
        #expect(content.hasSuffix("# Empty Page"))
    }
}
