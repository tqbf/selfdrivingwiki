import Foundation

// MARK: - Overview
//
// Right-click link context menu — the pure, view- and storage-free half.
//
// `WikiLinkMenuBuilder` decides which actions apply to a link URL (and rebuilds
// the canonical `[[…]]` text for "Copy as Wiki Link"). It is pure so it is
// trivially unit-testable and free of the Textual/AppKit dependency. The view
// layer (`WikiLinkMenuNSItems` in `WikiFS`) maps these actions to menu items with
// real closures (navigation, semantic search, pasteboard, the File Provider
// mount), where state is needed.
//
// URL kinds (mirroring `WikiLinkMarkdown`):
//   wiki://page?title=…      — resolved page link
//   wiki://source?title=…    — resolved source link
//   wiki://missing?title=…   — unresolved wiki link (page or source)
//   wiki://anchor#…          — same-page scroll (not a navigation)
//   https/mailto/…           — external link

/// The actions offered in a right-click link context menu.
///
/// Produced (in menu order) by ``WikiLinkMenuBuilder/actions(for:)`` for a link
/// URL; the view layer turns each into a concrete menu item.
public enum WikiLinkAction: Sendable, Equatable {
    /// Missing wiki link — show the closest existing pages/sources (semantic
    /// search) so the user can find what they likely meant.
    case suggest
    /// Any resolved wiki link — explore pages similar to the linked target.
    case findSimilar
    /// Copy the canonical `[[target]]` / `[[source:name]]` (alias and `#fragment`
    /// preserved). See ``WikiLinkMenuBuilder/wikiLinkString(for:)``.
    case copyWikiLink
    /// Copy the File Provider mount path of the linked page/source file.
    case copyFilePath
    /// External http(s) link — fetch + ingest it into this wiki as a source,
    /// the same path the "Add from URL…" toolbar button uses (it opens the sheet
    /// pre-filled with the URL). Offered only for http/https links; other
    /// external schemes (mailto:, etc.) can't be ingested and are skipped.
    case addAsSource
    /// External link — open in the system browser.
    case openInBrowser
    /// External link — copy the raw URL string.
    case copyLink
}

public enum WikiLinkMenuBuilder {

    /// The menu actions that apply to `url`, in display order.
    ///
    /// Pure: decides *what* applies based only on the URL kind. The view layer
    /// supplies the data and closures when building the actual menu.
    public static func actions(for url: URL) -> [WikiLinkAction] {
        // Same-page anchor: it scrolls within the preview, not a navigation —
        // no link-specific menu.
        if WikiLinkMarkdown.isSamePageAnchor(url) {
            return []
        }

        // External link (not our wiki scheme): browser + copy. For http(s) links
        // we also lead with "Add as Source" (fetch + ingest, like the toolbar
        // button); other schemes (mailto:, etc.) can't be fetched/ingested, so
        // they get only browser + copy.
        if url.scheme != WikiLinkMarkdown.scheme {
            let base: [WikiLinkAction] = [.openInBrowser, .copyLink]
            let scheme = url.scheme?.lowercased()
            return (scheme == "http" || scheme == "https") ? [.addAsSource] + base : base
        }

        // Wiki link: resolved page/source vs unresolved (missing).
        switch WikiLinkMarkdown.resolvedKind(from: url) {
        case .page?, .source?:
            return [.findSimilar, .copyWikiLink, .copyFilePath]
        case nil:
            // `wiki://missing` — unresolved. Suggest closest matches; the link
            // text can still be copied. (Find Similar for resolved links is the
            // non-redundant way to "explore pages like this one".)
            return [.suggest, .copyWikiLink]
        }
    }

    /// The canonical `[[…]]` wiki-link string for `url`, or `nil` if `url` is
    /// not a wiki link we can reconstruct (external links, same-page anchors).
    ///
    /// - A resolved page link  → `[[Target]]`
    /// - A source link         → `[[source:Name]]`
    /// - A missing link        → `[[Target]]` (we can't recover an intended
    ///   `source:` prefix from the unresolved URL, so it copies as a page link)
    /// - Fragments are preserved: `[[Target#Section]]`, `[[source:Name#"quote"]]`
    public static func wikiLinkString(for url: URL) -> String? {
        guard let target = WikiLinkMarkdown.target(from: url) else { return nil }
        let fragment = WikiLinkMarkdown.fragment(from: url)

        let base: String
        switch WikiLinkMarkdown.resolvedKind(from: url) {
        case .source?: base = "source:\(target)"
        case .page?, nil: base = target
        }

        if let fragment, !fragment.isEmpty {
            return "[[\(base)#\(fragment)]]"
        }
        return "[[\(base)]]"
    }
}
