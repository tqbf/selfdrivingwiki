import SwiftUI
import WikiFSCore

/// Hosts the active wiki's editor, swapping wholesale when the user switches
/// wikis. Observing `manager` here (not inside `ContentView`) keeps the heavy
/// editor view from re-initializing on unrelated manager changes — it re-creates
/// only when `activeStore`'s identity changes.
///
/// `.id(manager.activeWikiID)` forces a clean `ContentView` rebuild on a wiki
/// switch so no editor draft or selection leaks across wikis (§3.1 — state tied
/// to the wrong source is the classic frozen-snapshot bug).
struct RootView: View {
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @Bindable var agentLauncher: AgentLauncher
    let askLauncher: AgentLauncher
    let editLauncher: AgentLauncher
    @Bindable var extractionCoordinator: ExtractionCoordinator

    var body: some View {
        Group {
            if let store = manager.activeStore {
                ContentView(
                    store: store,
                    manager: manager,
                    fileProvider: fileProvider,
                    agentLauncher: agentLauncher,
                    askLauncher: askLauncher,
                    editLauncher: editLauncher,
                    extractionCoordinator: extractionCoordinator
                )
                .id(manager.activeWikiID)
            } else {
                ContentUnavailableView {
                    Label("No Wikis", systemImage: "books.vertical")
                } description: {
                    Text("Create a wiki to get started.")
                } actions: {
                    Button("New Wiki", systemImage: "plus") {
                        Task { await manager.createWiki(displayName: "My Wiki") }
                    }
                }
            }
        }
    }
}
