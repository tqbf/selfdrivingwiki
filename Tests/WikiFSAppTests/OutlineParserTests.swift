import Testing
import Foundation
@testable import WikiFS
import WikiFSCore

/// Unit tests for the pure outline parser shared by the page and source
/// producers. These port the parse semantics the former
/// `PageOutlineView.parseHeadings` established (fence tracking, ATX level
/// validation, whitespace-after-`#`, empty-text guards, inline markup
/// stripping, GFM slug dedup) plus the `activeHeadingID` caret mapping in the
/// editors' UTF-16 coordinate space.
struct OutlineParserTests {
    // MARK: - ATX levels

    @Test func parsesAtxLevelsOneThroughSix() {
        let markdown = """
        # One
        ## Two
        ### Three
        #### Four
        ##### Five
        ###### Six
        """
        let headings = OutlineParser.headings(in: markdown)
        #expect(headings.map(\.level) == [1, 2, 3, 4, 5, 6])
        #expect(headings.map(\.text) == ["One", "Two", "Three", "Four", "Five", "Six"])
    }

    @Test func rejectsSevenOrMorePounds() {
        let headings = OutlineParser.headings(in: "####### Not a heading")
        #expect(headings.isEmpty)
    }

    @Test func rejectsPoundWithoutWhitespace() {
        let headings = OutlineParser.headings(in: "#NoSpace")
        #expect(headings.isEmpty)
    }

    @Test func rejectsEmptyText() {
        let markdown = """
        #
        # 
        ##   
        """
        #expect(OutlineParser.headings(in: markdown).isEmpty)
    }

    @Test func rejectsEmptyTextAfterInlineMarkupStripping() {
        // A heading whose text is only link markup strips down to nothing and
        // must not produce a row (the renderer's anchor for it would be empty).
        #expect(OutlineParser.headings(in: "# [](https://example.com)").isEmpty)
    }

    @Test func allowsLeadingWhitespaceBeforeAtx() {
        let headings = OutlineParser.headings(in: "   ## Indented")
        #expect(headings.count == 1)
        #expect(headings[0].level == 2)
        #expect(headings[0].text == "Indented")
    }

    // MARK: - Fenced code blocks

    @Test func skipsHashLinesInsideFences() {
        let markdown = """
        # Real
        ```
        # Fake
        ## Also Fake
        ```
        # Also Real
        """
        let headings = OutlineParser.headings(in: markdown)
        #expect(headings.map(\.text) == ["Real", "Also Real"])
    }

    @Test func resumesParsingAfterFenceCloses() {
        let markdown = """
        ```text
        # Inside
        ```
        # Outside
        """
        let headings = OutlineParser.headings(in: markdown)
        #expect(headings.map(\.text) == ["Outside"])
    }

    // MARK: - Inline markup

    @Test func stripsLinksAndCodeSpans() {
        let headings = OutlineParser.headings(in: "# [Docs](https://example.com) with `code` span")
        #expect(headings.count == 1)
        #expect(headings[0].text == "Docs with code span")
    }

    @Test func stripsDoubleAsteriskAndDoubleUnderscoreEmphasis() {
        let headings = OutlineParser.headings(in: "## **Bold** and __Underline__")
        #expect(headings.count == 1)
        #expect(headings[0].text == "Bold and Underline")
    }

    // MARK: - Slugs

    @Test func slugsAreGFMStyleAndDeduped() {
        let markdown = """
        # Setup
        ## Setup
        # Setup
        """
        let headings = OutlineParser.headings(in: markdown)
        #expect(headings.map(\.id) == ["setup", "setup-1", "setup-2"])
    }

    // MARK: - charOffset (UTF-16 line-start coordinate space)

    @Test func charOffsetsAreLineStartUTF16Offsets() {
        let markdown = """
        # First
        body line
        ## Second
        """
        let headings = OutlineParser.headings(in: markdown)
        // "# First\n" = 8, "body line\n" = 10.
        #expect(headings[0].charOffset == 0)
        #expect(headings[1].charOffset == 18)
    }

    @Test func nonAsciiContentPreservesUTF16OffsetArithmetic() {
        let filler = "Café ☕️ note — émoji 🎉 line"
        let markdown = "# First\n\(filler)\n# Second\n"
        let headings = OutlineParser.headings(in: markdown)
        let secondOffset = ("# First" as NSString).length + 1
            + (filler as NSString).length + 1
        #expect(headings[1].charOffset == secondOffset)
        // The fixture must actually exercise UTF-16 arithmetic: multi-byte
        // scalars make Swift's Character count differ from NSString length.
        #expect(filler.count != (filler as NSString).length)
        #expect(OutlineParser.activeHeadingID(
            caretUTF16Offset: secondOffset, headings: headings) == "second")
    }

    // MARK: - activeHeadingID

    private var sample: [OutlineHeading] {
        OutlineParser.headings(in: """
        # Alpha
        alpha body
        ## Beta
        beta body
        ### Gamma
        """)
    }

    @Test func caretBeforeFirstHeadingYieldsNil() {
        // Headings start at offsets 0, 19, 37 — caret -1 (no caret) precedes all.
        let headings = sample
        #expect(headings.map(\.charOffset) == [0, 19, 37])
        #expect(OutlineParser.activeHeadingID(caretUTF16Offset: -1, headings: headings) == nil)
    }

    @Test func caretBetweenHeadingsSelectsTheEarlierOne() {
        let headings = sample
        // Between Beta (19) and Gamma (37): Beta is the enclosing heading.
        #expect(OutlineParser.activeHeadingID(caretUTF16Offset: 19, headings: headings) == "beta")
        #expect(OutlineParser.activeHeadingID(caretUTF16Offset: 36, headings: headings) == "beta")
    }

    @Test func caretAtExactHeadingOffsetSelectsIt() {
        let headings = sample
        #expect(OutlineParser.activeHeadingID(caretUTF16Offset: 0, headings: headings) == "alpha")
        #expect(OutlineParser.activeHeadingID(caretUTF16Offset: 37, headings: headings) == "gamma")
    }

    @Test func caretAfterLastHeadingSelectsLast() {
        let headings = sample
        #expect(OutlineParser.activeHeadingID(caretUTF16Offset: 10_000, headings: headings) == "gamma")
    }

    @Test func activeHeadingIDWithNoHeadingsYieldsNil() {
        #expect(OutlineParser.activeHeadingID(caretUTF16Offset: 5, headings: []) == nil)
    }

    // MARK: - Performance (the live shape)

    /// The operator's failing surface was a ~32K-char transcript; the live
    /// shape seen in session logs is a ~95K-character document whose outline
    /// has a single heading. Parsing is O(lines), so it must stay far under
    /// interactive latency.
    @Test func parses95KSingleHeadingTranscriptUnder50ms() {
        let bodySentence = "This transcript paragraph deliberately contains no ATX headings, fences, or markup that the outline parser would treat as structure. "
        var markdown = "# Transcript\n"
        while markdown.utf16.count < 95_000 {
            markdown += bodySentence
        }
        #expect(markdown.utf16.count >= 95_000)

        let clock = ContinuousClock()
        let start = clock.now
        let headings = OutlineParser.headings(in: markdown)
        let elapsed = clock.now - start

        #expect(headings.count == 1)
        #expect(elapsed < .milliseconds(50), "parsing 95K chars took \(elapsed)")
    }
}
