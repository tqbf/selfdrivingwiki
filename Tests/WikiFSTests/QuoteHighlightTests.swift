import AppKit
import SwiftUI
import Testing
import Textual
@testable import WikiFS
@testable import WikiFSCore

/// Unit tests for `WikiLinkStylingParser.quoteRange` (the pure whitespace-tolerant
/// substring matcher) and integration tests for the parser's `highlightQuote`
/// parameter (verifying `.backgroundColor` is applied and link colors are preserved).
@MainActor
struct QuoteHighlightTests {

    // MARK: - quoteRange: exact match

    @Test func exactMatch() throws {
        let input = "The results show a 30% improvement."
        let attributed = try attributedString(input)
        let range = try #require(WikiLinkStylingParser.quoteRange("30% improvement", in: attributed))
        let matched = String(attributed[range].characters)
        #expect(matched == "30% improvement")
    }

    @Test func matchAtStart() throws {
        let attributed = try attributedString("First sentence. Second sentence.")
        let range = try #require(WikiLinkStylingParser.quoteRange("First sentence", in: attributed))
        let matched = String(attributed[range].characters)
        #expect(matched == "First sentence")
    }

    @Test func matchAtEnd() throws {
        let attributed = try attributedString("Start and end.")
        let range = try #require(WikiLinkStylingParser.quoteRange("end", in: attributed))
        let matched = String(attributed[range].characters)
        // "end" appears before the period.
        #expect(matched == "end")
    }

    // MARK: - quoteRange: whitespace tolerance

    @Test func whitespaceTolerantNewlineInHaystack() throws {
        // The haystack wraps across lines, but the quote is a single line.
        let input = "The results show\na 30% improvement in throughput."
        let attributed = try attributedString(input)
        let range = try #require(WikiLinkStylingParser.quoteRange("30% improvement", in: attributed))
        // The matched text in the original string spans the newline.
        let matched = String(attributed[range].characters)
        #expect(matched.contains("30"))
        #expect(matched.contains("improvement"))
    }

    @Test func whitespaceTolerantExtraSpacesInHaystack() throws {
        // Extra spaces between words in the haystack.
        let input = "The   results   show   a   30%   improvement."
        let attributed = try attributedString(input)
        let range = try #require(WikiLinkStylingParser.quoteRange("30% improvement", in: attributed))
        let matched = String(attributed[range].characters)
        #expect(matched.contains("30%"))
    }

    @Test func quoteWithNormalizedWhitespace() throws {
        // Quote has extra spaces; haystack is normalized.
        let input = "The results show a 30% improvement."
        let attributed = try attributedString(input)
        // The quote passed to quoteRange is already wikiNormalized (collapsed spaces).
        let _ = try #require(WikiLinkStylingParser.quoteRange("30% improvement", in: attributed))
    }

    // MARK: - quoteRange: no match

    @Test func noMatchReturnsNil() throws {
        let attributed = try attributedString("Some text here.")
        #expect(WikiLinkStylingParser.quoteRange("nonexistent", in: attributed) == nil)
    }

    @Test func emptyQuoteReturnsNil() throws {
        let attributed = try attributedString("Some text.")
        #expect(WikiLinkStylingParser.quoteRange("", in: attributed) == nil)
    }

    @Test func emptyStringReturnsNil() throws {
        let attributed = AttributedString()
        #expect(WikiLinkStylingParser.quoteRange("anything", in: attributed) == nil)
    }

    // MARK: - quoteRange: first occurrence (case-sensitive)

    @Test func picksFirstOccurrenceCaseSensitive() throws {
        // Case-sensitive search: "the dog" (lowercase) matches the second occurrence.
        let input = "The dog chased the dog."
        let attributed = try attributedString(input)
        let range = try #require(WikiLinkStylingParser.quoteRange("the dog", in: attributed))
        let matched = String(attributed[range].characters)
        #expect(matched == "the dog")
    }

    @Test func picksFirstOccurrenceSameCase() throws {
        // Same-case search picks the first occurrence at the start.
        let input = "The dog chased the dog."
        let attributed = try attributedString(input)
        let range = try #require(WikiLinkStylingParser.quoteRange("The dog", in: attributed))
        let matched = String(attributed[range].characters)
        #expect(matched == "The dog")
        #expect(range.lowerBound == attributed.startIndex)
    }

    // MARK: - Integration: parser applies backgroundColor

    @Test func parserAppliesBackgroundColor() throws {
        let parser = WikiLinkStylingParser(highlightQuote: "hello world")
        let attributed = try parser.attributedString(for: "Say hello world today.")
        // Find the run that carries backgroundColor.
        let highlighted = attributed.runs.first { $0.backgroundColor != nil }
        #expect(highlighted != nil)
    }

    @Test func parserNoHighlightWhenQuoteNil() throws {
        let parser = WikiLinkStylingParser(highlightQuote: nil)
        let attributed = try parser.attributedString(for: "Some text.")
        let highlighted = attributed.runs.first { $0.backgroundColor != nil }
        #expect(highlighted == nil)
    }

    @Test func parserNoHighlightWhenQuoteNotFound() throws {
        let parser = WikiLinkStylingParser(highlightQuote: "not here")
        let attributed = try parser.attributedString(for: "Completely different text.")
        let highlighted = attributed.runs.first { $0.backgroundColor != nil }
        #expect(highlighted == nil)
    }

    // MARK: - Integration: link colors are preserved

    @Test func resolvedLinkKeepsColorWithHighlight() throws {
        // A resolved page link + a quote highlight in the same document.
        let markdown = WikiLinkMarkdown.linkified("[[Real Page]] discussed the results.") { _, _ in true }
        let parser = WikiLinkStylingParser(highlightQuote: "the results")
        let attributed = try parser.attributedString(for: markdown)
        // The link run should still have the link color.
        let linkRun = try #require(attributed.runs.first { $0.link != nil })
        #expect(linkRun.foregroundColor == Color(NSColor.linkColor))
    }

    @Test func missingLinkKeepsRedColorWithHighlight() throws {
        let markdown = WikiLinkMarkdown.linkified("[[Ghost]] was mentioned.") { _, _ in false }
        let parser = WikiLinkStylingParser(highlightQuote: "mentioned")
        let attributed = try parser.attributedString(for: markdown)
        let linkRun = try #require(attributed.runs.first { $0.link != nil })
        #expect(linkRun.foregroundColor == Color.red)
    }

    // MARK: - Integration: multiple runs (link + highlight coexist)

    @Test func linkAndHighlightInSameDocument() throws {
        let markdown = WikiLinkMarkdown.linkified("See [[Home]] for the 30% improvement data.") { _, _ in true }
        let parser = WikiLinkStylingParser(highlightQuote: "30% improvement")
        let attributed = try parser.attributedString(for: markdown)
        // The link run has link color.
        let linkRuns = attributed.runs.filter { $0.link != nil }
        #expect(linkRuns.count == 1)
        #expect(linkRuns[0].foregroundColor == Color(NSColor.linkColor))
        // Some run has backgroundColor.
        let bgRuns = attributed.runs.filter { $0.backgroundColor != nil }
        #expect(!bgRuns.isEmpty)
    }
}

// MARK: - Helpers

/// Build a plain `AttributedString` from markdown via the base parser (no
/// highlight, no recolor), so `quoteRange` tests run against realistic input.
@MainActor
private func attributedString(_ markdown: String) throws -> AttributedString {
    let base = AttributedStringMarkdownParser(baseURL: nil)
    return try base.attributedString(for: markdown)
}
