import SwiftUI
import WikiFSCore

/// Entry point for the WikiFS macOS app.
///
/// Phase 0 (many wikis): a `WikiManager` owns the registry of wikis, the active
/// store, and the create/select/delete operations. One File Provider domain is
/// registered per wiki on launch. The legacy single-wiki `WikiFS.sqlite` is
/// migrated into the registry as wiki #1 by `WikiManager.bootstrap()`.
///
/// Flushes pending autosave when the app stops being active (§3.5
/// immediate-on-background — don't lose buffered edits on quit).
@main
struct WikiFSApp: App {
    @State private var manager: WikiManager
    @State private var fileProvider = FileProviderSpike()
    @State private var agentLauncher = AgentLauncher()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The single legacy v0 DB still lives at the literal App Group path; the
        // one-time Application-Support → container migration must still run before
        // the registry adopts it. Then the WikiManager migrates that legacy file
        // into the registry as wiki #1 and opens the most-recently-used wiki.
        DatabaseLocation.migrateFromApplicationSupportIfNeeded()
        let directory = (try? DatabaseLocation.appGroupContainerDirectory())
            ?? FileManager.default.temporaryDirectory
        _manager = State(initialValue: WikiManager(containerDirectory: directory))
    }

    var body: some Scene {
        WindowGroup {
            RootView(manager: manager, fileProvider: fileProvider, agentLauncher: agentLauncher)
                .task {
                    // Wire the File Provider side effects into the manager: it
                    // imports no FileProvider symbols (testable core), so the app
                    // injects domain registration/removal + per-store signaling.
                    fileProvider.wire(into: manager)
                    manager.bootstrap()
                    await manager.registerAllDomains()
                    if let active = manager.activeWikiID,
                       let descriptor = manager.wikis.first(where: { $0.id == active }) {
                        await fileProvider.activate(id: descriptor.id, displayName: descriptor.displayName)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { manager.activeStore?.flushPendingSaves() }
        }
    }
}

extension FileProviderSpike {
    /// Inject this provider's per-wiki domain side effects into the manager, and
    /// keep the active store's `onPageDidChange` wired to `signalChange()` after
    /// every store swap (select / create / delete).
    @MainActor
    func wire(into manager: WikiManager) {
        manager.registerDomain = { [weak self] id, name in
            await self?.registerDomain(id: id, displayName: name)
        }
        manager.removeDomain = { [weak self] id in
            await self?.removeDomain(id: id)
        }
        manager.onActiveStoreDidChange = { [weak self, weak manager] in
            guard let self, let manager else { return }
            // Re-point the freshly-swapped store's change hook at the active
            // domain's signaling, and resolve the new mount path.
            manager.activeStore?.onPageDidChange = { [weak self] in
                Task { await self?.signalChange() }
            }
            if let active = manager.activeWikiID,
               let descriptor = manager.wikis.first(where: { $0.id == active }) {
                Task { await self.activate(id: descriptor.id, displayName: descriptor.displayName) }
            }
        }
    }
}
