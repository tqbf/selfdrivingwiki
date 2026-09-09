import Foundation
import WikiFSCore
import WikiFSLinks

/// Routes a known queue-target click into that target's wiki window — the
/// closed-wiki click-through seam.
///
/// A target whose name the effective index resolves (live session, payload
/// recorded name, or read-only fallback) gets its action link even when the
/// target's wiki window is closed. Both paths reuse the app's existing
/// navigation seams; nothing new is invented here:
///
/// - **Live session** — navigate the shared `WikiStoreModel` directly
///   (`openTab` for pages, `requestSidebarReveal` for sources), then focus
///   the window. The pre-existing #583 / #598 path, unchanged.
/// - **Closed wiki** — stash a `wiki://page|source?title=…&id=…` deep link
///   on the session manager (the #635 cross-window transcript stash) and
///   open the window. `RootScene.resolveSession` transfers the stash onto
///   the new session and `RootView` delivers it to the store through the
///   same `WikiReaderView.onWikiLinkHandler` the in-wiki transcript uses —
///   so the navigation lands once the session exists.
///
/// Value type with injected effect closures: tests drive both paths with
/// spies and assert the effect order (navigate/stash before focus).
@MainActor
struct QueueTargetRouter {
    /// The wiki's live store, or `nil` when that wiki's window is closed.
    var liveStore: (WikiID) -> WikiStoreModel?
    /// The open-session navigation: page → `openTab`, source → sidebar
    /// reveal. Called before the window focus, matching the historical
    /// order (the navigation must be on the shared model before the window
    /// it drives comes forward).
    var navigateInSession: (WikiStoreModel, QueueWorkspaceTargetIdentity) -> Void
    /// The closed-wiki stash: record the deep link the wiki window will
    /// consume when its session resolves.
    var stashDeepLink: (WikiID, URL) -> Void
    /// Open (or focus — the bridge dedupes) the wiki's window.
    var openWiki: (WikiID) -> Void

    /// Route a click on a KNOWN target (the effective name index resolved
    /// it) into `wikiID`'s window. Exactly one navigation effect runs
    /// (navigate-in-session XOR stash), and it always lands before the
    /// window focus.
    func route(
        _ target: QueueWorkspaceTargetIdentity,
        title: String?,
        in wikiID: WikiID
    ) {
        if let store = liveStore(wikiID) {
            navigateInSession(store, target)
        } else {
            stashDeepLink(wikiID, Self.deepLinkURL(for: target, title: title))
        }
        openWiki(wikiID)
    }

    /// The `wiki://` deep link for a target — parsed back by
    /// `WikiReaderView.linkRoute`, which prefers the canonical `id` query
    /// item and falls back to `title` (the transition fallback for
    /// `title=`-only URLs, so an empty/missing recorded title degrades to
    /// the raw ID rather than an inert link).
    nonisolated static func deepLinkURL(
        for target: QueueWorkspaceTargetIdentity,
        title: String?
    ) -> URL {
        let (host, id): (String, String)
        switch target {
        case .page(let pageID):
            host = WikiLinkMarkdown.resolvedHost
            id = pageID.rawValue
        case .source(let sourceID):
            host = WikiLinkMarkdown.sourceHost
            id = sourceID.rawValue
        }
        var components = URLComponents()
        components.scheme = WikiLinkMarkdown.scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "title", value: title?.isEmpty == false ? title : id),
            URLQueryItem(name: "id", value: id),
        ]
        // scheme + host are constants and query items percent-encode
        // themselves, so the URL cannot be malformed here.
        guard let url = components.url else {
            preconditionFailure("Failed to construct a wiki deep-link URL for host \(host)")
        }
        return url
    }
}
