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
    /// The per-active-wiki session (store + launchers + gate). Nil before any
    /// wiki exists / after the last one is deleted — the empty state shows a
    /// "create a wiki" affordance.
    var session: WikiSession?
    /// App-scoped registry: wiki list + active id + create/select/delete.
    @Bindable var registry: WikiRegistryClient
    let fileProvider: FileProviderSpike

    var body: some View {
        Group {
            if let session {
                ContentView(
                    store: session.store,
                    session: session,
                    registry: registry,
                    fileProvider: fileProvider,
                    agentLauncher: session.agentLauncher,
                    chatLauncher: session.chatLauncher,
                    extractionCoordinator: session.extractionCoordinator
                )
                .id(session.wikiID)
            } else {
                ContentUnavailableView {
                    Label("No Wikis", systemImage: "books.vertical")
                } description: {
                    Text("Create a wiki to get started.")
                } actions: {
                    Button("New Wiki", systemImage: "plus") {
                        Task { await registry.createWiki(displayName: "My Wiki") }
                    }
                }
            }
        }
    }
}
