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
    /// it. Shows a disabled "No similar pages" item when the search finds
    /// nothing so the submenu is never mysteriously blank.
    ///
    /// #637: searches with `store.searchSimilarResolvingTantivy(query:limit:)`
    /// (rather than the FTS5-fallback `searchSimilar(query:limit:)`) so the menu
    /// surfaces Tantivy-BM25-fused results — gaining the indexer's `fuzzyFields`
    /// edit-distance-1 matches (already configured at
    /// `TantivyIndexer.swift:108-111`) for free, and surviving #634's FTS5 drop
    /// without regression.
    ///
    /// #925: that search is now `async`, so this returns immediately with a
    /// disabled "Searching…" row and a ``SimilarPagesMenuLoader`` delegate that
    /// fills the submenu in when the user actually opens it. Nothing runs at
    /// right-click time; nothing blocks the main actor.
    private static func similarPagesItem(
        title: String, query: String, store: WikiStoreModel
    ) -> NSMenuItem {
        similarPagesItem(
            title: title,
            query: query,
            search: { query, limit in await store.searchSimilarResolvingTantivy(query: query, limit: limit) },
            navigate: { page in
                // Prefer the rename-stable id path (#922 strong types); fall back
                // to the title lookup when the summary list hasn't reloaded since
                // the search, which is the only case `selectPage(byID:)` rejects.
                if !store.selectPage(byID: page.id) { store.selectPage(byTitle: page.title) }
            })
    }

    /// Seam-injected form of ``similarPagesItem(title:query:store:)`` — the
    /// production overload wires `store`; tests pass a controlled `search` to
    /// drive the lazy submenu deterministically.
    static func similarPagesItem(
        title: String,
        query: String,
        search: @escaping SimilarPagesMenuLoader.Search,
        navigate: @escaping SimilarPagesMenuLoader.Navigate
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        // An empty query can never match, so skip the loader entirely and show
        // the settled empty state rather than a "Searching…" row that resolves
        // to the same thing.
        guard !query.isEmpty else {
            menu.addItem(SimilarPagesMenuLoader.disabledItem(SimilarPagesMenuLoader.noResultsTitle))
            parent.submenu = menu
            return parent
        }
        menu.addItem(SimilarPagesMenuLoader.disabledItem(SimilarPagesMenuLoader.searchingTitle))
        let loader = SimilarPagesMenuLoader(query: query, search: search, navigate: navigate)
        menu.delegate = loader
        // `NSMenu.delegate` is a weak reference, so the loader needs an owner for
        // the submenu's lifetime. The parent item's `representedObject` is that
        // owner (same trick `wikiItem` uses for its closure target) and is not a
        // cycle: the loader holds neither the item nor the menu strongly.
        parent.representedObject = loader
        parent.submenu = menu
        return parent
    }
}

// MARK: - Lazy "Suggest…" / "Find Similar…" submenu

/// Fills a "Suggest…" / "Find Similar…" submenu when it is about to open,
/// replacing the disabled "Searching…" placeholder with ranked page titles.
///
/// #925: the search this drives (`searchSimilarResolvingTantivy`) is async
/// because resolving the Tantivy BM25 leg hops to the indexer actor. AppKit
/// builds a context menu synchronously, so the work cannot happen during
/// construction — it happens here, on `menuNeedsUpdate(_:)`, which AppKit calls
/// just before the submenu is displayed. A right-click that never opens the
/// submenu therefore performs no search at all.
///
/// Lifecycle:
/// - Retained by the parent `NSMenuItem`'s `representedObject` (`NSMenu.delegate`
///   is weak). The loader captures neither back, so there is no cycle.
/// - `menuNeedsUpdate(_:)` fires every time the submenu is displayed *and* can
///   repeat for a single display pass, so the `State` machine — not a pile of
///   booleans — is what makes "exactly one search per open" true.
/// - `menuDidClose(_:)` cancels an in-flight search and bumps `generation`, so a
///   late completion cannot mutate a submenu the user has already dismissed.
///   Reopening starts a fresh search from the placeholder that is still in place.
@MainActor
final class SimilarPagesMenuLoader: NSObject, NSMenuDelegate {

    /// Runs the page search. `(query, limit) -> ranked pages`.
    typealias Search = @MainActor (String, Int) async -> [WikiPageSummary]
    /// Navigates to a chosen result.
    typealias Navigate = @MainActor (WikiPageSummary) -> Void

    /// #637 parity: the submenu has always shown at most 8 pages.
    static let resultLimit = 8
    /// Transient placeholder shown while the async search runs (#925).
    static let searchingTitle = "Searching…"
    /// Settled empty state — unchanged user-visible label.
    static let noResultsTitle = "No similar pages"

    /// One lifecycle, one stored value: `.idle` may start a search, `.searching`
    /// owns the cancellable task, `.loaded` is terminal for this open. Encoding
    /// this as separate `isSearching` / `hasLoaded` flags would make "searching
    /// *and* loaded" representable and put the duplicate-search guard in two
    /// places.
    private enum State {
        case idle
        case searching(generation: Int, task: Task<Void, Never>)
        case loaded
    }

    private let query: String
    private let search: Search
    private let navigate: Navigate
    private var state: State = .idle
    /// Bumped on every start and every close; a completion whose captured value
    /// no longer matches is stale and must not touch the menu.
    private var generation = 0

    init(query: String, search: @escaping Search, navigate: @escaping Navigate) {
        self.query = query
        self.search = search
        self.navigate = navigate
        super.init()
    }

    /// A disabled, action-less row. `NSMenu.autoenablesItems` would disable a
    /// nil-action item anyway; setting it explicitly keeps the intent readable
    /// and assertable before the menu is ever displayed.
    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Only `.idle` starts work: repeated update callbacks during one display
        // pass, and reopening an already-filled submenu, are both no-ops.
        guard case .idle = state else { return }
        generation += 1
        let started = generation
        let task = Task { [weak self, weak menu] in
            guard let self else { return }
            let matches = await self.search(self.query, Self.resultLimit)
            // Three ways to be stale: the task was cancelled, the menu closed and
            // bumped the generation, or the menu itself was torn down.
            guard !Task.isCancelled, started == self.generation, let menu else { return }
            self.apply(matches, to: menu)
            self.state = .loaded
        }
        // Safe to assign after creating the task: this method is main-actor
        // isolated and has no suspension point, so the task cannot start (and
        // overwrite `state` with `.loaded`) before this line runs.
        state = .searching(generation: started, task: task)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard case .searching(_, let task) = state else { return }
        task.cancel()
        generation += 1
        // Back to `.idle` — the "Searching…" placeholder is still in the menu, so
        // the next open simply retries.
        state = .idle
    }

    // MARK: - Internals

    private func apply(_ matches: [WikiPageSummary], to menu: NSMenu) {
        menu.removeAllItems()
        guard !matches.isEmpty else {
            menu.addItem(Self.disabledItem(Self.noResultsTitle))
            return
        }
        // Rank order is the search's; the menu preserves it verbatim.
        for page in matches {
            menu.addItem(.wikiItem(page.title) { [navigate] in navigate(page) })
        }
    }

    /// Test seam: the in-flight search, so AppKit menu tests can `await` a
    /// settled submenu instead of polling or sleeping. `nil` when idle or
    /// loaded. Reading it before `menuDidClose(_:)` is also how the stale-
    /// completion test keeps a handle on a task the loader has let go of.
    var inFlightSearch: Task<Void, Never>? {
        if case .searching(_, let task) = state { task } else { nil }
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
