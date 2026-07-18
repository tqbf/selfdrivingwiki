import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Hosts the active wiki's editor, swapping wholesale when the user switches
/// wikis. The session (one per active wiki) carries the store + launchers;
/// the registry carries the wiki list + active id. Observing both here (not
/// inside `ContentView`) keeps the heavy editor view from re-initializing on
/// unrelated registry changes — it re-creates only when the session's wiki
/// changes.
///
/// `.id(session.wikiID)` forces a clean `ContentView` rebuild on a wiki switch
/// so no editor draft or selection leaks across wikis (§3.1 — state tied to the
/// wrong source is the classic frozen-snapshot bug). Without `.id()`, SwiftUI
/// keys `@State` by structural identity, not by the `@Observable` object's
/// identity — a session swap (non-nil→non-nil) would NOT reset child `@State`
/// (editor drafts, selection), reintroducing the frozen-snapshot bug.
struct RootView: View {
    /// The per-active-wiki session (store + launchers + gate). Non-optional —
    /// `RootScene` guarantees the session is resolved before instantiating
    /// `RootView`. The empty/loading state is handled by `RootScene`.
    var session: WikiSession
    /// App-scoped registry: wiki list + active id + create/select/delete.
    @Bindable var registry: WikiRegistryClient
    let fileProvider: FileProviderFacade

    var body: some View {
        ContentView(
            store: session.store,
            session: session,
            registry: registry,
            fileProvider: fileProvider,
            agentLauncher: session.agentLauncher,
            chatLauncher: session.chatLauncher,
            extractionCoordinator: session.extractionCoordinator,
            queueEngine: session.queueEngine,
            extractionProvider: session.extractionProvider
        )
        .id(session.wikiID)
        // Consume a deferred cross-window `wiki://` navigation (set on the
        // session by `SessionManager.applyOrStashWikiLink` when a link was
        // clicked in the Activity window while THIS wiki's window was closed).
        // Runs once on appear — after `RootScene.resolveSession` has created
        // the session, so `store` is ready (`WikiStoreModel.init` loads
        // `summaries` synchronously and `selectPage` loads drafts inline).
        // Deferred by one runloop tick so `ContentView` has mounted and the
        // tab/selection change diff is observed by the sidebar + detail.
        .onAppear { consumePendingWikiLink() }
    }

    /// Deliver the stashed `wiki://` link (if any) to the app-layer router
    /// (`WikiReaderView.onWikiLinkHandler`) — same handler the in-wiki chat
    // transcript uses. Clears the stash so a re-appear (e.g. window re-focus)
    // never re-navigates. The explicit nil-out also keeps the session lean.
    private func consumePendingWikiLink() {
        guard let pending = session.pendingWikiLink else { return }
        session.pendingWikiLink = nil
        // `WikiReaderView.onWikiLinkHandler(for:)` is app-layer; importing it
        // here would create a layering cycle (`WikiFS` viewing `WikiReaderView`
        // is fine — we already do in `ChatView`). Defer via `Task @MainActor`
        // so `ContentView`'s first layout has committed before the selection
        // mutation travels through `store` → `.onChange` → sidebar/detail.
        let handler = WikiReaderView.onWikiLinkHandler(for: session.store)
        Task { @MainActor in
            await Task.yield()
            handler(pending.url, pending.openInNewTab)
        }
    }
}
