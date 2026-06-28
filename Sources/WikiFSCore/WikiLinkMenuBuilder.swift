import Foundation

// MARK: - Overview
//
// Right-click link context menu — the pure, view- and storage-free half.
//
// `WikiLinkMenuBuilder` decides which actions apply to a link URL. It is pure
// so it is trivially unit-testable and free of the Textual/AppKit dependency.
// The view layer (`WikiLinkMenuNSItems` in `WikiFS`) maps these actions to menu
// items with real closures (navigation, semantic search, pasteboard, the File
// Provider mount), where state is needed.
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
    /// Resolved wiki link — open the target page/source in a background tab
    /// without switching focus away from the current page.
    case openInBackgroundTab
    /// Copy the File Provider mount path of the linked page/source file.
    case copyFilePath
    /// External http(s) link — fetch + ingest it into this wiki as a source,
    /// the same path the "Add from URL…" toolbar button uses (it opens the sheet
    /// pre-filled with the URL). Offered only for http/https links; other
    /// external schemes (mailto:, etc.) can't be ingested and are skipped.
    case addAsSource
    /// External link — open in the system browser.
    case openInBrowser
    /// Download the linked file to the Downloads folder. For wiki page/source
    /// links this copies the file from the File Provider mount (file://); for
    /// external http(s) links it fetches via URLSession.
    case downloadLink
    /// External link — copy the raw URL string.
    case copyLink
}

public enum WikiLinkMenuBuilder {

    /// Actions for the top section (prepended above WebKit's native items).
    /// Pure — see ``actions(for:)``.
    public static func actions(for url: URL) -> [WikiLinkAction] {
        // Same-page anchor: it scrolls within the preview, not a navigation —
        // no link-specific menu.
        if WikiLinkMarkdown.isSamePageAnchor(url) {
            return []
        }

        // External link (not our wiki scheme): browser + copy. For http(s) links
        // we also lead with "Add as Source" (fetch + ingest, like the toolbar
        // button) and offer "Download"; other schemes (mailto:, etc.) can't be
        // fetched/ingested, so they get only browser + copy.
        if url.scheme != WikiLinkMarkdown.scheme {
            let base: [WikiLinkAction] = [.openInBrowser, .copyLink]
            let scheme = url.scheme?.lowercased()
            return (scheme == "http" || scheme == "https") ? [.addAsSource, .openInBrowser, .downloadLink, .copyLink] : base
        }

        // Wiki link: resolved page/source vs unresolved (missing).
        switch WikiLinkMarkdown.resolvedKind(from: url) {
        case .page?, .source?:
            return [.openInBackgroundTab, .copyFilePath, .downloadLink]
        case nil:
            // `wiki://missing` — unresolved. Suggest closest matches.
            return [.suggest]
        }
    }

    /// Actions for the bottom section (inserted before the Share item, below
    /// WebKit's Open/Copy Link items). Currently only resolved wiki links get
    /// "Find Similar…" here.
    public static func bottomActions(for url: URL) -> [WikiLinkAction] {
        guard url.scheme == WikiLinkMarkdown.scheme,
              WikiLinkMarkdown.resolvedKind(from: url) != nil else { return [] }
        return [.findSimilar]
    }

}
