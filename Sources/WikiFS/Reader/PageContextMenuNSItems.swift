import AppKit
import WikiFSCore

/// The page-level actions a right-click on the rendered document offers when the
/// cursor is **not** over a link — Safari's Back / Forward / Print Page… group
/// (issue #933).
///
/// Modelled as a closed set rather than three loose title strings so the label,
/// the SF Symbol, and the menu order all live in one place and a new action is a
/// compile-time exhaustive change.
enum PageContextMenuAction: CaseIterable {
    /// Move one step back through the wiki's navigation history.
    case back
    /// Move one step forward through the wiki's navigation history.
    case forward
    /// Print the rendered document.
    case printPage

    /// The user-visible label. Matches Safari's page context menu verbatim —
    /// "Print Page…" carries the ellipsis because it opens the print panel.
    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .printPage: "Print Page…"
        }
    }

    /// The leading SF Symbol. The chevrons are the same glyphs the toolbar's
    /// Back / Forward buttons use (`OmniboxNavButtons`), so the two surfaces for
    /// the same command read identically.
    var symbolName: String {
        switch self {
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .printPage: "printer"
        }
    }
}

/// Builds the concrete `NSMenuItem`s for the page-level context-menu group and
/// splices them into WebKit's menu.
///
/// This is the page counterpart to ``WikiLinkMenuNSItems`` (which handles the
/// right-clicked *link*). Both run on the main actor because AppKit builds a
/// context menu synchronously in `NSView.willOpenMenu(_:with:)`; nothing here
/// awaits, searches, or touches SQLite, so the menu opens in the same turn.
///
/// **Navigation state is not duplicated.** Back / Forward read
/// ``WikiStoreModel/canNavigateBack`` / ``WikiStoreModel/canNavigateForward``
/// and call ``WikiStoreModel/navigateBack()`` / ``WikiStoreModel/navigateForward()``
/// — the same history stacks the toolbar chevrons (⌘[ / ⌘]) and the two-finger
/// swipe monitor drive. The reader loads its HTML with `loadHTMLString`, so
/// `WKWebView`'s own back-forward list is always empty and is *not* the source of
/// truth for "can this page go back?".
///
/// **Printing is injected.** The print action arrives as a ``PrintAction`` closure
/// so the menu has no opinion about *how* the document prints, and tests can
/// assert the item is wired without presenting a real print panel.
@MainActor
enum PageContextMenuNSItems {

    /// Runs the print operation for the document currently rendered in the
    /// reader. Production passes `WikiReaderWebView`'s printer seam; tests pass a
    /// probe.
    typealias PrintAction = @MainActor () -> Void

    /// The three page items, in menu order: Back, Forward, Print Page….
    ///
    /// Back / Forward are enabled from the store's history at build time *and*
    /// re-validated at display time (see ``NSMenuItem/wikiItem(_:isEnabled:action:)``),
    /// because `NSMenu.autoenablesItems` — which WebKit leaves on — recomputes
    /// enablement just before the menu is shown.
    static func items(store: WikiStoreModel, printPage: @escaping PrintAction) -> [NSMenuItem] {
        [
            item(.back, isEnabled: { store.canNavigateBack }) { store.navigateBack() },
            item(.forward, isEnabled: { store.canNavigateForward }) { store.navigateForward() },
            item(.printPage, isEnabled: { true }, action: printPage),
        ]
    }

    /// Splice the page group into WebKit's context menu and return the inserted
    /// items in menu order.
    ///
    /// Placement mirrors Safari:
    /// - Back / Forward go at the very top, so they sit directly above WebKit's
    ///   own "Reload" and the three read as one navigation group.
    /// - "Print Page…" opens the next group down, separated from navigation —
    ///   it acts on the document rather than moving between documents.
    ///
    /// The caller inserts anything else belonging to the document group (the
    /// reader's "Share…") after the returned Print item, so the group order is
    /// decided here rather than by three independent index computations.
    @discardableResult
    static func insert(
        into menu: NSMenu,
        store: WikiStoreModel,
        printPage: @escaping PrintAction
    ) -> [NSMenuItem] {
        let items = items(store: store, printPage: printPage)
        guard let printItem = items.last else { return [] }
        let navItems = items.dropLast()
        for (offset, item) in navItems.enumerated() {
            menu.insertItem(item, at: offset)
        }
        // Print opens the group below navigation: after WebKit's Reload when it
        // ships one (Back / Forward / Reload stay together), otherwise directly
        // after Forward.
        let reloadIdx = menu.items.firstIndex { $0.identifier?.rawValue == reloadIdentifier }
        let anchor = reloadIdx.map { $0 + 1 } ?? navItems.count
        menu.insertItem(.separator(), at: anchor)
        menu.insertItem(printItem, at: anchor + 1)
        return items
    }

    /// WebKit's identifier for the "Reload" item it puts at the top of a
    /// non-link page menu. Not in any public header — matched by identifier
    /// rather than title so it survives localization.
    static let reloadIdentifier = "WKMenuItemIdentifierReload"

    private static func item(
        _ action: PageContextMenuAction,
        isEnabled: @escaping @MainActor () -> Bool,
        action perform: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem.wikiItem(action.title, isEnabled: isEnabled, action: perform)
        // The accessibility description is what VoiceOver reads for the glyph;
        // the title already carries the command, so it repeats the label rather
        // than inventing a second phrasing.
        item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
        return item
    }
}
