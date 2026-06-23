import AppKit
import SwiftUI
import Textual
import WikiFSCore

/// A `MarkupParser` that delegates to Textual's Markdown parser, then recolors
/// wiki-link runs so an UNRESOLVED `[[Ghost Page]]` renders **red** while every
/// other link keeps the standard link color.
///
/// `WikiLinkMarkdown.linkified` already encodes resolution into the URL host: an
/// unresolved target renders `wiki://missing?title=…`; a resolved page/source
/// renders `wiki://page?…` / `wiki://source?…`; a same-page anchor renders
/// `wiki://anchor#…`. This parser only needs the host to decide color, so it
/// stays pure (no `WikiStoreModel` access).
///
/// **Why `MarkdownPreview` neutralizes the link style.** Textual's
/// `WithInlineStyle` applies the `InlineStyle.link` foreground color to EVERY
/// `.link` run with a `keepNew` attribute merge, which would override whatever
/// per-run color this parser sets. To let the per-run colors survive,
/// `MarkdownPreview` applies `.textual.inlineStyle(InlineStyle.default.link())`
/// — identical to the default inline style except the link run applies no
/// foreground color (an empty pack is a no-op). The parser is then the single
/// source of truth for link color.
///
/// The system link color (`NSColor.linkColor`, adapted via SwiftUI `Color`) is
/// used for resolved/external links rather than Textual's `DynamicColor.link`,
/// because `DynamicColor` must be resolved against a color environment the
/// parser does not receive. `NSColor.linkColor` is SwiftUI's self-adapting
/// semantic link color and is visually equivalent to Textual's link blue.
///
/// **Quote highlighting.** When `highlightQuote` is non-nil, the parser finds
/// the first whitespace-normalized occurrence of the quote in the rendered
/// markdown and sets its `.backgroundColor` — exactly the same normalization
/// `resolveAnchor` uses (`wikiNormalized`). The highlight color is the semantic
/// Find color (`NSColor.findHighlightColor`), matching native macOS reader
/// behavior.
@MainActor
struct WikiLinkStylingParser: MarkupParser {
    private let base: AttributedStringMarkdownParser = .init(baseURL: nil)

    /// An optional quote to highlight in the rendered output. Whitespace-normalized
    /// before matching (mirrors `wikiNormalized`). `nil` → no highlight.
    private let highlightQuote: String?

    init(highlightQuote: String? = nil) {
        self.highlightQuote = highlightQuote
    }

    func attributedString(for input: String) throws -> AttributedString {
        var result = try base.attributedString(for: input)
        recolorLinks(in: &result)
        if let q = highlightQuote?.wikiNormalized, !q.isEmpty {
            highlightQuote(q, in: &result)
        }
        return result
    }

    /// Set per-link foreground colors: `wiki://missing…` → red, every other link
    /// (resolved page/source, same-page anchor, external `https`, …) → the
    /// system link color. Because `MarkdownPreview` neutralizes the style-level
    /// link color, EVERY link must be colored here or it would render uncolored.
    /// Mutating an `AttributedString` while iterating `.runs` is unsafe, so
    /// changes are collected first and applied after the loop.
    private func recolorLinks(in string: inout AttributedString) {
        var updates: [(range: Range<AttributedString.Index>, color: Color)] = []
        for run in string.runs {
            guard let url = run.link else { continue }
            let isMissing = url.scheme == WikiLinkMarkdown.scheme
                && url.host == WikiLinkMarkdown.unresolvedHost
            updates.append((run.range, isMissing ? Color.red : Color(NSColor.linkColor)))
        }
        for update in updates {
            // `AttributedSubstring` is a mutable view into the storage; setting a
            // single attribute keeps every other attribute on the run intact.
            string[update.range].foregroundColor = update.color
        }
    }

    /// Set `.backgroundColor` on the first whitespace-normalized occurrence of `quote`.
    ///
    /// Uses a dynamic color that adapts to light/dark mode: the system Find color in
    /// light mode, and a lower-opacity warm tint in dark mode so white text stays readable.
    private func highlightQuote(_ quote: String, in string: inout AttributedString) {
        guard let range = Self.quoteRange(quote, in: string) else { return }
        string[range].backgroundColor = Self.highlightColor
    }

    /// A dynamic background color that stays readable against both light and dark text.
    /// In light mode, uses the system Find highlight (bright yellow). In dark mode, uses
    /// a muted gold at reduced opacity so white foreground text doesn't wash out.
    private static let highlightColor: Color = {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                return NSColor(calibratedRed: 0.70, green: 0.55, blue: 0.15, alpha: 0.45)
            } else {
                return NSColor.findHighlightColor
            }
        }
        return Color(nsColor: nsColor)
    }()

    // MARK: - Pure, testable quote range

    /// Find the first whitespace-normalized occurrence of `quote` in `string`,
    /// returning the original `AttributedString` range, or `nil` on no match.
    ///
    /// Whitespace in `string` is collapsed to single spaces (mirrors
    /// `wikiNormalized`), then an index map translates the normalized match
    /// bounds back to the original `AttributedString.Index` positions. The match
    /// is case-sensitive and always picks the first occurrence.
    static func quoteRange(_ quote: String, in string: AttributedString) -> Range<AttributedString.Index>? {
        guard !quote.isEmpty else { return nil }

        let chars = string.characters
        guard !chars.isEmpty else { return nil }

        // Build a whitespace-collapsed view + index map so we can translate
        // normalized positions back to original AttributedString.Index values.
        var normalizedChars: [Character] = []
        var indexMap: [AttributedString.Index] = []

        var idx = chars.startIndex
        while idx < chars.endIndex {
            let ch = chars[idx]
            if ch.isWhitespace || ch.isNewline {
                // Collapse consecutive whitespace runs to a single space.
                if normalizedChars.last != " " {
                    normalizedChars.append(" ")
                    indexMap.append(idx)
                }
                idx = chars.index(after: idx)
            } else {
                normalizedChars.append(ch)
                indexMap.append(idx)
                idx = chars.index(after: idx)
            }
        }

        // Trim leading / trailing space to mirror `wikiNormalized`'s behavior.
        while normalizedChars.first == " " { normalizedChars.removeFirst(); indexMap.removeFirst() }
        while normalizedChars.last == " " { normalizedChars.removeLast(); indexMap.removeLast() }

        let normalizedHaystack = String(normalizedChars)
        guard let matchRange = normalizedHaystack.range(of: quote) else { return nil }

        // Convert String.Index offsets in the normalized haystack to array indices.
        let lo = normalizedHaystack.distance(from: normalizedHaystack.startIndex, to: matchRange.lowerBound)
        let hi = normalizedHaystack.distance(from: normalizedHaystack.startIndex, to: matchRange.upperBound)

        let start = indexMap[lo]
        let end = hi < indexMap.count ? indexMap[hi] : chars.endIndex

        return start..<end
    }
}
