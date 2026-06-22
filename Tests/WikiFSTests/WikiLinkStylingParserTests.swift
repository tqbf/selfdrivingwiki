import AppKit
import SwiftUI
import Testing
import Textual
@testable import WikiFS
@testable import WikiFSCore

/// Unit tests for `WikiLinkStylingParser` — the `MarkupParser` that recolors an
/// UNRESOLVED `wiki://missing…` link red while every other link keeps the
/// standard link color. These cover AC.1/AC.3/AC.4 at the parser seam (the only
/// place link color is decided, since `MarkdownPreview` neutralizes the
/// style-level link color).
@MainActor
struct WikiLinkStylingParserTests {

    private let parser = WikiLinkStylingParser()

    /// The system link color the parser applies to non-missing links.
    private var linkColor: Color { Color(NSColor.linkColor) }

    /// The first run carrying a `.link`, if any.
    private func firstLinkRun(in attributed: AttributedString) -> AttributedString.Runs.Run? {
        attributed.runs.first { $0.link != nil }
    }

    // MARK: - Per-link-kind coloring

    @Test func missingLinkRunIsRed() throws {
        let attributed = try parser.attributedString(for: "[Ghost](wiki://missing?title=Ghost)")
        let run = try #require(firstLinkRun(in: attributed))
        #expect(run.link?.host == "missing")
        #expect(run.foregroundColor == Color.red)
    }

    @Test func resolvedPageLinkUsesLinkColor() throws {
        let attributed = try parser.attributedString(for: "[Home](wiki://page?title=Home)")
        let run = try #require(firstLinkRun(in: attributed))
        #expect(run.link?.host == "page")
        #expect(run.foregroundColor == linkColor)
    }

    @Test func resolvedSourceLinkUsesLinkColor() throws {
        let attributed = try parser.attributedString(for: "[Paper](wiki://source?title=Paper)")
        let run = try #require(firstLinkRun(in: attributed))
        #expect(run.link?.host == "source")
        #expect(run.foregroundColor == linkColor)
    }

    @Test func samePageAnchorUsesLinkColor() throws {
        let attributed = try parser.attributedString(for: "[Section](wiki://anchor#Section)")
        let run = try #require(firstLinkRun(in: attributed))
        #expect(run.link?.host == "anchor")
        #expect(run.foregroundColor == linkColor)
    }

    @Test func externalLinkUsesLinkColor() throws {
        // External links must still be colored by the parser — `MarkdownPreview`
        // neutralizes the style-level link color, so an uncolored link would
        // render with the default text color instead of blue.
        let attributed = try parser.attributedString(for: "[x](https://example.com)")
        let run = try #require(firstLinkRun(in: attributed))
        #expect(run.link?.scheme == "https")
        #expect(run.foregroundColor == linkColor)
    }

    // MARK: - Non-link runs untouched

    @Test func nonLinkRunIsNotRecolored() throws {
        let attributed = try parser.attributedString(for: "Plain paragraph text.")
        // The parser only colors link runs; a plain run keeps its (nil) color.
        let run = try #require(attributed.runs.first)
        #expect(run.link == nil)
        #expect(run.foregroundColor == nil)
    }

    @Test func codeSpanIsNotALink() throws {
        // Code spans are not linkified; there is no `.link` run to recolor.
        let attributed = try parser.attributedString(for: "`[Home]` is literal.")
        #expect(firstLinkRun(in: attributed) == nil)
    }

    // MARK: - End-to-end via the linkifier

    @Test func linkifiedMissingLinkEndsUpRed() throws {
        // Ties WikiLinkMarkdown's `missing` host to the recolor: the linkifier
        // emits wiki://missing for an unresolved target, and the parser recolors
        // it red. Mirrors what MarkdownPreview actually feeds the parser.
        let markdown = WikiLinkMarkdown.linkified("See [[Ghost Page]] now.") { _, _ in false }
        let attributed = try parser.attributedString(for: markdown)
        let run = try #require(firstLinkRun(in: attributed))
        #expect(run.link?.host == "missing")
        #expect(run.foregroundColor == Color.red)
    }

    @Test func linkifiedResolvedLinkUsesLinkColor() throws {
        let markdown = WikiLinkMarkdown.linkified("See [[Home]] now.") { _, _ in true }
        let attributed = try parser.attributedString(for: markdown)
        let run = try #require(firstLinkRun(in: attributed))
        #expect(run.link?.host == "page")
        #expect(run.foregroundColor == linkColor)
    }

    @Test func linkifiedMissingAndResolvedDifferInColor() throws {
        // Both a resolved and an unresolved wiki link in one document.
        let markdown = WikiLinkMarkdown.linkified("[[Real]] vs [[Ghost]]") { name, _ in name == "Real" }
        let attributed = try parser.attributedString(for: markdown)
        let linkRuns = attributed.runs.filter { $0.link != nil }
        #expect(linkRuns.count == 2)
        let colors = linkRuns.map(\.foregroundColor)
        #expect(colors.contains(Color.red))
        #expect(colors.contains(linkColor))
    }
}
