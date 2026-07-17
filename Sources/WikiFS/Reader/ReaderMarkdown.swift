import Foundation
import WikiFSCore

/// The footnote-expand + wiki-link-linkify pre-pass shared by both readers
/// (the `WikiReaderView` (WKWebView)), so wiki links and
/// footnotes behave identically regardless of which reader renders them.
///
/// `isResolved` drives resolved-vs-ghost link styling. The native reader passes
/// the store's page/source existence; the web reader currently passes a constant
/// `true` (it can't call the `@MainActor` store from its off-main convert task),
/// so missing links aren't dimmed there yet — ghost coloring for the web reader
/// is a follow-up.
enum ReaderMarkdown {
    static func prepared(
        _ raw: String,
        isResolved: (String, ParsedLink.LinkType) -> Bool,
        embedInfo: ((String) -> WikiLinkMarkdown.SourceEmbedInfo?)? = nil,
        displayName: (PageID, ParsedLink.LinkType) -> String? = { _, _ in nil },
        pinnedExtractionID: ((PageID, Int) -> PageID?)? = nil
    ) -> String {
        let renderedFootnotes = WikiFootnoteMarkdown.rendered(raw)
        let body = WikiLinkMarkdown.linkified(renderedFootnotes.bodyMarkdown,
                                              isResolved: isResolved,
                                              embedInfo: embedInfo,
                                              displayName: displayName,
                                              pinnedExtractionID: pinnedExtractionID)
        guard !renderedFootnotes.footnotes.isEmpty else { return body }
        // Each definition gets a raw-HTML anchor (`wiki-fn-<id>`) so a clicked
        // reference (`wiki-footnote://note?id=…`) can scroll to it. The anchor is
        // inline HTML at the start of the (tight) list item; swift-markdown emits
        // it verbatim, giving the reader a stable `getElementById` target.
        let footnotes = renderedFootnotes.footnotes
            .map { footnote in
                let anchor = "<a id=\"\(WikiFootnoteMarkdown.footnoteAnchorID(for: footnote.id))\"></a>"
                let def = WikiLinkMarkdown.linkified(footnote.markdown, isResolved: isResolved,
                                                     displayName: displayName)
                return "\(footnote.number). \(anchor)\(def)"
            }
            .joined(separator: "\n")
        return "\(body)\n\n---\n\n\(footnotes)"
    }
}
