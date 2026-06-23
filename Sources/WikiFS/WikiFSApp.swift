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
    private let launchLocationWarning: LaunchLocationWarning?
    private let containerDirectory: URL
    @State private var manager: WikiManager
    @State private var fileProvider = FileProviderSpike()
    @State private var agentLauncher = AgentLauncher()
    /// App-wide extraction backend resolver (local pdf2md / Claude / Docling
    /// Serve). Threaded like `agentLauncher` — one instance, owned by the app.
    @State private var extractionCoordinator: ExtractionCoordinator
    @State private var showingLaunchLocationWarning: Bool
    @State private var fileProviderSetupWarning: FileProviderSetupWarning?
    @State private var showingFileProviderSetupWarning = false
    /// Built lazily after `bootstrap` (it needs the registered wikis) — see the
    /// `.task` below. The change bridge observes `wikictl`'s Darwin notifications.
    @State private var changeBridge: WikiChangeBridge?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let warning = LaunchLocationWarning.current()
        launchLocationWarning = warning
        _showingLaunchLocationWarning = State(initialValue: warning != nil)

        let directory = (try? DatabaseLocation.appGroupContainerDirectory())
            ?? FileManager.default.temporaryDirectory
        // The v0 legacy import is strictly FIRST-RUN-ONLY. We gate the whole chain
        // on an empty registry: only a genuine first run (no wikis yet) may pull
        // the Phase-1 Application-Support `WikiFS.sqlite` into the container for
        // `WikiManager.bootstrap()` to adopt as wiki #1. Once ANY wiki exists,
        // this is skipped — otherwise the WikiManager renames the container file
        // away on each launch, this layer re-copies it from Application Support,
        // and the two form an infinite duplication loop.
        if WikiRegistry.load(from: directory).isEmpty {
            DatabaseLocation.migrateFromApplicationSupportIfNeeded()
        }
        containerDirectory = directory
        _manager = State(initialValue: WikiManager(containerDirectory: directory))
        _extractionCoordinator = State(
            initialValue: ExtractionCoordinator(containerDirectory: directory))
    }

    var body: some Scene {
        WindowGroup {
            RootView(manager: manager, fileProvider: fileProvider, agentLauncher: agentLauncher, extractionCoordinator: extractionCoordinator)
                .alert(
                    "Install Self Driving Wiki in Applications",
                    isPresented: $showingLaunchLocationWarning,
                    presenting: launchLocationWarning
                ) { warning in
                    Button("Open Installed Copy") {
                        NSWorkspace.shared.open(warning.expectedURL)
                    }
                    Button("Reveal This Copy") {
                        NSWorkspace.shared.activateFileViewerSelecting([warning.actualURL])
                    }
                    Button("OK", role: .cancel) {}
                } message: { warning in
                    Text(warning.message)
                }
                .alert(
                    "File Provider Setup Needs Attention",
                    isPresented: $showingFileProviderSetupWarning,
                    presenting: fileProviderSetupWarning
                ) { warning in
                    Button("Open Installed Copy") {
                        NSWorkspace.shared.open(warning.expectedAppURL)
                    }
                    Button("Reveal Installed App") {
                        NSWorkspace.shared.activateFileViewerSelecting([warning.expectedAppURL])
                    }
                    Button("OK", role: .cancel) {}
                } message: { warning in
                    Text(warning.message)
                }
                .task {
                    if let warning = await FileProviderSetupVerifier.verifyAndRepairInstalledProvider() {
                        fileProviderSetupWarning = warning
                        showingFileProviderSetupWarning = true
                    }
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
                    // Stand up the change bridge now that the registry is loaded,
                    // then observe every wiki's `wikictl` Darwin notification.
                    let bridge = WikiChangeBridge(manager: manager, fileProvider: fileProvider)
                    bridge.refreshObservations()
                    changeBridge = bridge
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            ClaudePromptHelpCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { manager.activeStore?.flushPendingSaves() }
        }
        // Keep the bridge's Darwin observations in lockstep with the wiki set:
        // a freshly-created wiki's CLI writes must be heard; a deleted wiki's
        // notification name released.
        .onChange(of: manager.wikis) { _, _ in
            changeBridge?.refreshObservations()
        }

        Window("Claude Prompt Templates", id: "claudePromptHelp") {
            ClaudePromptHelpView()
        }
        .defaultSize(width: 880, height: 680)

        Settings {
            TabView {
                ZoteroSettingsView(containerDirectory: containerDirectory)
                    .tabItem { Label("Zotero", systemImage: "books.vertical") }
                ExtractionSettingsView(containerDirectory: containerDirectory, launcher: agentLauncher)
                    .tabItem { Label("Extraction", systemImage: "doc.viewfinder") }
            }
        }
    }
}

private struct LaunchLocationWarning {
    let actualURL: URL
    let expectedURL: URL

    var message: String {
        """
        File Provider mounts are only reliable from the installed app at \(expectedURL.path). \
        This copy is running from \(actualURL.path), so wiki mounts may be unavailable. \
        Run `make install`, then open the installed app.
        """
    }

    static func current() -> LaunchLocationWarning? {
        let actualURL = Bundle.main.bundleURL.standardizedFileURL
        let expectedURL = URL(fileURLWithPath: AppInstallationPolicy.expectedAppPath)
            .standardizedFileURL
        guard !AppInstallationPolicy.isExpectedInstallLocation(bundlePath: actualURL.path) else {
            return nil
        }
        return LaunchLocationWarning(actualURL: actualURL, expectedURL: expectedURL)
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
        manager.renameDomain = { [weak self] id, name in
            await self?.renameDomain(id: id, displayName: name)
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
