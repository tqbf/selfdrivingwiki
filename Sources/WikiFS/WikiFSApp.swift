import SwiftUI
import WikiFSCore

/// Entry point for the WikiFS macOS app (Phase 1 — Local wiki).
///
/// Owns the `WikiStoreModel` at App level so a single instance survives the
/// window lifecycle, and flushes any pending autosave when the app stops being
/// active (§3.5 immediate-on-background — don't lose buffered edits on quit).
@main
struct WikiFSApp: App {
    @State private var store: WikiStoreModel
    @State private var fileProvider = FileProviderSpike()
    @State private var agentLauncher = AgentLauncher()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Phase 2: the DB lives in the App Group container so the sandboxed File
        // Provider extension reads the same file. Migrate the Phase 1
        // Application Support DB across once (best-effort), then open read-write.
        // Fall back to an in-memory DB only if the container is somehow
        // unavailable, so the app still launches rather than crashing.
        let store: WikiStoreModel
        do {
            DatabaseLocation.migrateFromApplicationSupportIfNeeded()
            let url = try DatabaseLocation.appGroupContainerURL()
            let sqlite = try SQLiteWikiStore(databaseURL: url)
            store = WikiStoreModel(store: sqlite)
            // The projection is empty without at least one page; ensure a Home
            // exists (covers the fresh-container / failed-migration path).
            if store.summaries.isEmpty { store.newPage(title: "Home") }
        } catch {
            print("WikiFS: falling back to in-memory store: \(error)")
            // swiftlint:disable:next force_try
            let memory = try! SQLiteWikiStore(databaseURL: URL(fileURLWithPath: ":memory:"))
            store = WikiStoreModel(store: memory)
        }
        _store = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, fileProvider: fileProvider, agentLauncher: agentLauncher)
                .task {
                    // Wire change signaling: every persisted edit asks the File
                    // Provider daemon to re-enumerate so Terminal reads see the
                    // update without relaunch (INITIAL §6/§10). Set before the
                    // first edit can fire; registration resolves the path.
                    store.onPageDidChange = { [fileProvider] in
                        Task { await fileProvider.signalChange() }
                    }
                    await fileProvider.registerIfNeeded()
                }
        }
        .windowToolbarStyle(.unified)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.flushPendingSave() }
        }
    }
}
