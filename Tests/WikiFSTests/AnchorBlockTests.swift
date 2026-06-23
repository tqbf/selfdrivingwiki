import Testing
@testable import WikiFSCore

/// Unit tests for `AnchorBlock.parse()` and `resolveAnchor()`.
struct AnchorBlockTests {

    // MARK: - parse basic

    @Test func parsesHeadingsAndParagraphs() {
        let md = """
        # Heading One

        First paragraph text.

        ## Heading Two

        Second paragraph here.
        """
        let blocks = AnchorBlock.parse(md)
        #expect(blocks.count == 4)
        #expect(blocks[0].kind == .heading)
        #expect(blocks[0].id == "heading-one")
        #expect(blocks[1].kind == .paragraph)
        #expect(blocks[1].id == "p1")
        #expect(blocks[2].kind == .heading)
        #expect(blocks[2].id == "heading-two")
        #expect(blocks[3].kind == .paragraph)
        #expect(blocks[3].id == "p2")
    }

    @Test func deduplicatesHeadingSlugs() {
        let md = """
        # Overview

        ## Overview

        ### Overview
        """
        let blocks = AnchorBlock.parse(md)
        #expect(blocks[0].id == "overview")
        #expect(blocks[1].id == "overview-1")
        #expect(blocks[2].id == "overview-2")
    }

    @Test func skipsNonParagraphBlocks() {
        let md = """
        # Heading

        A paragraph.

        - list item
        - another item

        > blockquote

        ```
        code block
        ```

        Another paragraph.

        | col1 | col2 |
        |------|------|
        | a    | b    |
        """
        let blocks = AnchorBlock.parse(md)
        // Only heading + 2 paragraphs; lists, blockquotes, code, tables skipped.
        #expect(blocks.count == 3)
        #expect(blocks[0].kind == .heading)
        #expect(blocks[1].kind == .paragraph)
        #expect(blocks[1].id == "p1")
        #expect(blocks[2].kind == .paragraph)
        #expect(blocks[2].id == "p2")
    }

    @Test func emptyMarkdownReturnsEmpty() {
        #expect(AnchorBlock.parse("").isEmpty)
        #expect(AnchorBlock.parse("\n\n\n").isEmpty)
    }

    @Test func onlyHeadingsReturnsOnlyHeadings() {
        let md = """
        # Alpha

        ## Beta

        ### Gamma
        """
        let blocks = AnchorBlock.parse(md)
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.kind == .heading })
    }

    // MARK: - resolveAnchor

    @Test func resolvesHeadingBySlug() {
        let blocks = AnchorBlock.parse("# Methodology\n\nContent here.")
        let id = resolveAnchor("Methodology", in: blocks)
        #expect(id == "methodology")
    }

    @Test func resolvesHeadingBySlugWithSpaces() {
        let blocks = AnchorBlock.parse("# My Research Notes\n\nText.")
        let id = resolveAnchor("My Research Notes", in: blocks)
        #expect(id == "my-research-notes")
    }

    @Test func slugMatchBeatsQuoteMatch() {
        let blocks = AnchorBlock.parse("# Methodology\n\nThe methodology section describes...")
        // "methodology" matches both the heading slug AND the paragraph text.
        // Slug should win.
        let id = resolveAnchor("Methodology", in: blocks)
        #expect(id == "methodology")
    }

    @Test func resolvesQuoteBySubstring() {
        let blocks = AnchorBlock.parse("# Intro\n\nThe results show a 30% improvement in throughput.")
        let id = resolveAnchor("30% improvement", in: blocks)
        #expect(id == "p1")
    }

    @Test func stripsSurroundingQuotesFromFragment() {
        let blocks = AnchorBlock.parse("# Intro\n\nExact match text here.")
        let id = resolveAnchor("\"Exact match text here\"", in: blocks)
        #expect(id == "p1")
    }

    @Test func notFoundReturnsNil() {
        let blocks = AnchorBlock.parse("# Intro\n\nSome text.")
        #expect(resolveAnchor("nonexistent", in: blocks) == nil)
    }

    @Test func resolvesAgainstEmptyBlocksReturnsNil() {
        #expect(resolveAnchor("anything", in: []) == nil)
    }

    // MARK: - slug generation

    @Test func slugLowercasesAndReplacesSpaces() {
        var counts: [String: Int] = [:]
        #expect(AnchorBlock.makeSlug("My Research Notes", counts: &counts) == "my-research-notes")
    }

    @Test func slugDropsPunctuation() {
        var counts: [String: Int] = [:]
        #expect(AnchorBlock.makeSlug("What's New? (2024)", counts: &counts) == "whats-new-2024")
    }

    @Test func slugDedupWithSuffix() {
        var counts: [String: Int] = [:]
        #expect(AnchorBlock.makeSlug("Overview", counts: &counts) == "overview")
        #expect(AnchorBlock.makeSlug("Overview", counts: &counts) == "overview-1")
        #expect(AnchorBlock.makeSlug("Overview", counts: &counts) == "overview-2")
    }

    @Test func emptySlugReturnsHeading() {
        var counts: [String: Int] = [:]
        // All punctuation → empty string after filtering.
        #expect(AnchorBlock.makeSlug("?!", counts: &counts) == "heading")
    }

    // MARK: - Regression: resolveAnchor with quote fragments (Quote Highlight)

    @Test func resolveAnchorQuoteFragmentStripsQuotesAndNormalizes() {
        // Simulates the fragment from `[[source:Paper#"30%  improvement"]]`
        // (extra spaces inside the quote, surrounded by double-quotes).
        let blocks = AnchorBlock.parse("# Intro\n\nThe results show a 30% improvement in throughput.")
        let id = resolveAnchor("\"30%  improvement\"", in: blocks)
        #expect(id == "p1")
    }

    @Test func resolveAnchorBareQuoteFragment() {
        // Fragment without surrounding quotes (heading slug or bare quote).
        let blocks = AnchorBlock.parse("# Intro\n\nThe results show a 30% improvement.")
        let id = resolveAnchor("30% improvement", in: blocks)
        #expect(id == "p1")
    }
}
