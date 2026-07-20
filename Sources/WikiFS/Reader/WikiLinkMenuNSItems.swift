import AppKit
import SwiftUI
import WikiFSCore

/// Builds the concrete `NSMenuItem`s for a right-clicked link by wiring the
/// pure ``WikiLinkMenuBuilder`` actions to real closures (navigation, semantic
/// search, pasteboard, the system browser, the File Provider mount).
///
/// This is the WKWebView (AppKit) counterpart to the retired
/// `WikiLinkContextMenu` (which returned Textual `LinkMenuItem`s). It is
/// Textual-free and runs on the main actor (AppKit's context-menu path). The
/// menu items' closures capture `store` / `fileProvider`; because both are
/// `@MainActor`-isolated and the actions fire on the main thread, no isolation
/// boundary is crossed.
@MainActor
enum WikiLinkMenuNSItems {

    static func items(
        for url: URL,
        actions: [WikiLinkAction]? = nil,
        store: WikiStoreModel,
        fileProvider: FileProviderFacade?,
        addURL: (@MainActor @Sendable (String) -> Void)? = nil,
        addBookmark: (@MainActor @Sendable (BookmarkTargetPickerContext) -> Void)? = nil
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for action in actions ?? WikiLinkMenuBuilder.actions(for: url) {
            switch action {
            case .addAsSource:
                // Opens the "Add from URL" sheet pre-filled with the URL, the same
                // path the toolbar button takes. Omitted when no handler is wired
                // (e.g. SwiftUI previews), mirroring how `.copyFilePath` omits
                // itself without a File Provider spike.
                guard let addURL else { continue }
                items.append(.wikiItem("Add as Source") { addURL(url.absoluteString) })
            case .addBookmark:
                // Resolved internal wiki link — file the target page/source into a
                // bookmark folder. The target already exists, so we resolve its id
                // (same lookup as `.openInBackgroundTab`) and hand a
                // `BookmarkTargetPickerContext` to the handler, which presents the
                // folder picker. Omitted when no handler is wired or the link no
                // longer resolves (e.g. the page was just deleted). Issue #188.
                guard let addBookmark else { continue }
                let kind = WikiLinkMarkdown.resolvedKind(from: url)
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                let ctx: BookmarkTargetPickerContext?
                switch kind {
                case .page:
                    guard let id = store.pageID(forTitle: target) else { continue }
                    ctx = BookmarkTargetPickerContext(kind: .pages, ids: [id])
                case .source:
                    guard let id = store.sourceID(forDisplayName: target) else { continue }
                    ctx = BookmarkTargetPickerContext(kind: .sources, ids: [id])
                case .chat:
                    guard let id = store.chatID(forTitle: target) else { continue }
                    ctx = BookmarkTargetPickerContext(kind: .chats, ids: [id])
                case nil:
                    continue
                }
                guard let ctx else { continue }
                items.append(.wikiItem("Add Bookmark…") { addBookmark(ctx) })
            case .suggest:
                items.append(
                    similarPagesItem(
                        title: "Suggest…",
                        query: WikiLinkMarkdown.target(from: url) ?? "",
                        store: store))
            case .findSimilar:
                items.append(
                    similarPagesItem(
                        title: "Find Similar…",
                        query: WikiLinkMarkdown.target(from: url) ?? "",
                        store: store))
            case .openInBackgroundTab:
                let kind = WikiLinkMarkdown.resolvedKind(from: url)
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                items.append(.wikiItem("Open in Background") {
                    switch kind {
                    case .page:
                        if let id = store.pageID(forTitle: target) { store.openTabInBackground(.page(id)) }
                    case .source:
                        if let id = store.sourceID(forDisplayName: target) { store.openTabInBackground(.source(id)) }
                    case .chat:
                        if let id = store.chatID(forTitle: target) { store.openTabInBackground(.chat(id)) }
                    case nil: break
                    }
                })
            }
            }
        return items
    }

    /// A submenu listing the closest pages to `query`; choosing one navigates to
    /// it. Shows a disabled "No similar pages" item when the search is empty so
    /// the submenu is never mysteriously blank.
    ///
    /// #637: builds with `store.searchSimilarResolvingTantivy(query:limit:)`
    /// (rather than the FTS5-fallback `searchSimilar(query:limit:)`) so the menu
    /// surfaces Tantivy-BM25-fused results — gaining the indexer's `fuzzyFields`
    /// edit-distance-1 matches (already configured at
    /// `TantivyIndexer.swift:108-111`) for free, and surviving #634's FTS5 drop
    /// without regression.
    private static func similarPagesItem(
        title: String, query: String, store: WikiStoreModel
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let matches = query.isEmpty ? [] : store.searchSimilarResolvingTantivy(query: query, limit: 8)
        let menu = NSMenu()
        if matches.isEmpty {
            let none = NSMenuItem(title: "No similar pages", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for page in matches {
                menu.addItem(.wikiItem(page.title) { store.selectPage(byTitle: page.title) })
            }
        }
        parent.submenu = menu
        return parent
    }
}

// MARK: - NSMenuItem + closure bridge

extension NSMenuItem {
    /// Build an enabled menu item whose action invokes `action` when selected.
    ///
    /// `NSMenuItem.action` is a selector, so the closure is wrapped in an
    /// Objective-C target object. The item's `representedObject` retains the
    /// target for the lifetime of the menu (the menu owns its items), and the
    /// target is released when the menu is torn down — so no manual cleanup is
    /// needed and there's no lingering reference.
    @MainActor
    static func wikiItem(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureMenuItemTarget(action)
        let item = NSMenuItem(title: title, action: #selector(ClosureMenuItemTarget.invoke), keyEquivalent: "")
        item.target = target
        item.isEnabled = isEnabled
        item.representedObject = target
        return item
    }
}

/// A retainable target that bridges a Swift closure to `NSMenuItem`'s
/// selector-based action. Retained via the menu item's `representedObject`.
@MainActor
private final class ClosureMenuItemTarget: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}

private struct AddURLHandlerKey: EnvironmentKey {
    // Main-actor-isolated: the handler touches UI/store state (presents the
    // "Add from URL" sheet via a @State property on the main-actor ContentView).
    // @Sendable so the closure can be stored in EnvironmentValues and read deep
    // in the reader tree without losing isolation.
    static let defaultValue: (@MainActor @Sendable (String) -> Void)? = nil
}

private struct AddBookmarkHandlerKey: EnvironmentKey {
    // Main-actor-isolated: the handler touches UI state (presents the bookmark
    // picker sheet via a @State property on the main-actor ContentView).
    // @Sendable so the closure can be stored in EnvironmentValues and read deep
    // in the reader tree without losing isolation.
    static let defaultValue: (@MainActor @Sendable (BookmarkTargetPickerContext) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens the "Add from URL" sheet, pre-filling the field with the given URL
    /// string (empty for the toolbar / empty-state buttons; the absolute URL for
    /// the right-click "Add as Source" item).
    ///
    /// Set once by `ContentView` and read deep in the tree (the reader views'
    /// link context menu, via `WikiLinkMenuNSItems`, plus the empty-state
    /// buttons) so external links can be ingested from any reader without
    /// threading a closure through every detail view. Mirrors how the reader
    /// already injects behavior via `\.openURL`.
    var addURLHandler: (@MainActor @Sendable (String) -> Void)? {
        get { self[AddURLHandlerKey.self] }
        set { self[AddURLHandlerKey.self] = newValue }
    }

    /// Presents `BookmarkTargetPickerSheet` for the given context — set once by
    /// `ContentView` and read deep in the reader tree via `WikiLinkMenuNSItems`,
    /// so a right-clicked internal wiki link can be filed into a bookmark folder
    /// without threading a closure through every detail view. Issue #188.
    var addBookmarkHandler: (@MainActor @Sendable (BookmarkTargetPickerContext) -> Void)? {
        get { self[AddBookmarkHandlerKey.self] }
        set { self[AddBookmarkHandlerKey.self] = newValue }
    }
}
