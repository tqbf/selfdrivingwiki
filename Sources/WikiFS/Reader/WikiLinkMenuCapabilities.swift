// pattern: Capability Seam

import AppKit
import WikiFSCore

/// What a host can do with a right-clicked wiki link, as opaque closures.
///
/// ``WikiLinkMenuNSItems/items(for:actions:capabilities:)`` builds menu items
/// from this struct alone — it never sees `WikiStoreModel` or
/// `FileProviderFacade`. Each member is optional: `nil` means the host cannot
/// offer that action, and the corresponding item is omitted rather than shown
/// inert (the issue #188 convention).
///
/// Why a parameter and not SwiftUI Environment: the capability is
/// instance-scoped, not scope-scoped. The Activity window is a separate scene
/// that never passes through `ContentView` (where the `addURLHandler` /
/// `addBookmarkHandler` environment values are installed), and its tree hosts
/// transcripts from several wikis in one view subtree, each with its own
/// store. Environment is a per-subtree mechanism and cannot express that.
///
/// The one place `WikiStoreModel` meets menu construction is
/// ``WikiLinkMenuCapabilities/full(store:fileProvider:addURL:addBookmark:)``.
/// Hosts with full authority build the struct there; every downstream consumer
/// — the reader's `willOpenMenu` and the chat transcript's context menu alike
/// — sees closures only.
@MainActor
struct WikiLinkMenuCapabilities {
    /// Resolve a right-clicked `wiki://` URL to its typed navigation target
    /// (canonical `?id=` first, display-name fallback for legacy links).
    /// `nil` here (the member, not the per-URL result) means the host cannot
    /// resolve links at all.
    var selection: ((URL) -> WikiSelection?)?
    /// Open a resolved target in a background tab of the host's window.
    var openInBackground: ((WikiSelection) -> Void)?
    /// Ranked page search behind the "Suggest…" / "Find Similar…" submenus —
    /// the production form of the `SimilarPagesMenuLoader` test seam.
    var similarPages: SimilarPagesMenuLoader.Search?
    /// Navigate a "Suggest…" / "Find Similar…" result to its page.
    var navigateToPage: SimilarPagesMenuLoader.Navigate?
    /// Present the system sharing picker for the link's target. Implementations
    /// resolve any File Provider URL at CLICK time, never at menu-build time —
    /// AppKit assembles context menus synchronously, so build-time work would
    /// run on every right-click whether or not Share is chosen (the defect
    /// #925 fixed for the similar-pages search). The anchor view and rect are
    /// host facts passed to `items(for:)`, forwarded here at click time.
    var sharePresent: (@MainActor (URL, NSView, NSRect) -> Void)?
    /// Open the "Add from URL" sheet pre-filled (the `addURLHandler` value).
    var addURL: (@MainActor @Sendable (String) -> Void)?
    /// Present the bookmark-folder picker for a resolved target (the
    /// `addBookmarkHandler` value).
    var addBookmark: (@MainActor @Sendable (BookmarkTargetPickerContext) -> Void)?

    /// A host with no link-menu authority: every item the builder would add
    /// from capabilities is omitted, and only the URL-only actions remain.
    static let none = WikiLinkMenuCapabilities()

    /// Full authority from a live store and, optionally, the File Provider
    /// facade. The ONLY place menu construction meets `WikiStoreModel`.
    ///
    /// - Parameters:
    ///   - store: the host's wiki model; backs link resolution, background-tab
    ///     opening, and the similar-pages search.
    ///   - fileProvider: when present, Share… resolves mount URLs through it
    ///     at click time. `nil` omits Share… (hosts without a mount).
    ///   - addURL: the host's `addURLHandler`, if it can present the
    ///     "Add from URL" sheet. `nil` omits Add as Source.
    ///   - addBookmark: the host's `addBookmarkHandler`, if it can present the
    ///     bookmark-folder picker. `nil` omits Add Bookmark….
    static func full(
        store: WikiStoreModel,
        fileProvider: FileProviderFacade?,
        addURL: (@MainActor @Sendable (String) -> Void)? = nil,
        addBookmark: (@MainActor @Sendable (BookmarkTargetPickerContext) -> Void)? = nil
    ) -> Self {
        WikiLinkMenuCapabilities(
            selection: { WikiLinkMenuNSItems.selection(for: $0, store: store) },
            openInBackground: { store.openTabInBackground($0) },
            similarPages: { query, limit in
                await store.searchSimilarResolvingTantivy(query: query, limit: limit)
            },
            navigateToPage: { page in
                // Rename-stable first, title fallback — the same discipline
                // the store-backed overload has always used (#922).
                if !store.selectPage(byID: page.id) { store.selectPage(byTitle: page.title) }
            },
            sharePresent: Self.sharePresent(store: store, fileProvider: fileProvider),
            addURL: addURL,
            addBookmark: addBookmark)
    }

    /// Build the click-time Share presenter for `.full`. A chat-kind target
    /// resolves but has no File Provider URL today, so its Share… click is a
    /// deliberate no-op — exactly the reader's pre-existing behavior.
    private static func sharePresent(
        store: WikiStoreModel,
        fileProvider: FileProviderFacade?
    ) -> (@MainActor (URL, NSView, NSRect) -> Void)? {
        guard let fileProvider else { return nil }
        return { url, anchorView, anchorRect in
            let resolveTask: Task<URL?, Never>?
            switch WikiLinkMenuNSItems.selection(for: url, store: store) {
            case .page(let id):
                resolveTask = Task { await fileProvider.resolvePageByTitleURL(id: id) }
            case .source(let id):
                resolveTask = Task { await fileProvider.resolveSourceByNameURL(id: id) }
            case .chat, nil:
                // Chat sharing via File Provider URL is not yet wired; an
                // unresolvable link has nothing to share.
                resolveTask = nil
            default:
                resolveTask = nil
            }
            Task { @MainActor in
                guard let fileURL = await resolveTask?.value as? URL else { return }
                let picker = NSSharingServicePicker(items: [fileURL])
                picker.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
            }
        }
    }
}
