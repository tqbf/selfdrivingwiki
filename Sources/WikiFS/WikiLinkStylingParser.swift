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
@MainActor
struct WikiLinkStylingParser: MarkupParser {
    private let base: AttributedStringMarkdownParser = .init(baseURL: nil)

    func attributedString(for input: String) throws -> AttributedString {
        var result = try base.attributedString(for: input)
        recolorLinks(in: &result)
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
}
