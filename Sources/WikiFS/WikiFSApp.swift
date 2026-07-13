import SwiftUI
import ServiceManagement
import WikiFSEngine
import WikiFSCore
import WikiFSMLX

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
    /// Both launchers share one `GenerationGate` so ingest and chat-turn
    /// generations serialize globally — only one active generation at a time.
    @State private var agentLauncher: AgentLauncher
    @State private var chatLauncher: AgentLauncher
    /// App-wide extraction backend resolver (local pdf2md / Claude / Docling
    /// Serve). Threaded like `agentLauncher` — one instance, owned by the app.
    @State private var extractionCoordinator: ExtractionCoordinator
    @State private var showingLaunchLocationWarning: Bool
    @State private var fileProviderSetupWarning: FileProviderSetupWarning?
    @State private var showingFileProviderSetupWarning = false
    /// Built lazily after `bootstrap` (it needs the registered wikis) — see the
    /// `.task` below. The change bridge observes `wikictl`'s Darwin notifications.
    @State private var changeBridge: WikiChangeBridge?
    /// Tracks whether the main window scene is active, so wiki switches (which
    /// fire `onActiveStoreDidChange`) only kick off the Metal embedding backfill
    /// once the window is up. The launch-time store activation happens during
    /// the first-render `.task`, before the scene is active; backfill for that
    /// case is driven by the `scenePhase == .active` transition instead.
    @State private var isSceneActive = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Migrate the renamed chat-zoom @AppStorage key before any ChatView reads
        // it. Idempotent: copies `conversation.zoom` → `chat.zoom` only when the
        // new key is unset and the old key is set; no-op for fresh installs.
        AppStorageMigration.migrateZoomKey(in: .standard)
        // Install the app-only PDFKit title extractor into Core's injectable
        // seam. Core must not import PDFKit (it pulls AppKit into the File
        // Provider extension on macOS 26), so the real implementation lives in
        // this app target and is injected here. Non-app contexts (the
        // extension, wikictl, tests) keep the nil-returning default.
        DisplayNameResolver.installPDFTitleExtractor()
        // Install the app-only MiniLM (MLX/Metal) embedder into Core's seam.
        // Core must not link MLX (it would pull Metal into the File Provider
        // extension on macOS 26); the real MiniLM implementation lives in the
        // WikiFSMLX target and is injected here. This also starts the AppKit
        // foreground observer that gates the off-main backfill.
        EmbedderBootstrap.install()
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
        // Populate wikis BEFORE handing the manager to @State so SwiftUI's
        // first render sees a non-empty list.  activateNow: false means
        // activeWikiID stays nil for that render — NSTableView's initial
        // reloadData runs with data but no selection, which is safe.
        // activateMostRecent() in .task sets the selection AFTER the first
        // render; that update is selectRow-only (no concurrent reloadData),
        // avoiding an NSTableView reentrant-delegate warning on macOS 26.
        let m = WikiManager(containerDirectory: directory)
        m.bootstrap(activateNow: false)
        _manager = State(initialValue: m)
        let coordinator = ExtractionCoordinator(
            containerDirectory: directory,
            localExtractorFactory: { LocalPdf2MarkdownExtractor() })
        _extractionCoordinator = State(initialValue: coordinator)
        // Both launchers share one GenerationGate so ingest and chat-turn
        // generations coordinate. Phase 2 splits the gate into per-lane queues:
        // ingest-class runs (ingest, lint, lintPage) serialize on the
        // `.ingest` lane (limit 1 — one ingest at a time), while interactive
        // turns (query/chat) run on the `.interactive` lane (limit 3 — chat
        // stays responsive during an ingest). With CAS + workspaces (W0–W4),
        // concurrent writes are safe across lanes.
        let generationGate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])
        _agentLauncher = State(initialValue: {
            let l = AgentLauncher(generationGate: generationGate, extractionCoordinator: coordinator)
            l.pdf2mdScriptPathResolver = { PdfExtractionService.resolveScript()?.path }
            return l
        }())
        _chatLauncher   = State(initialValue: {
            let l = AgentLauncher(generationGate: generationGate, extractionCoordinator: coordinator)
            l.pdf2mdScriptPathResolver = { PdfExtractionService.resolveScript()?.path }
            return l
        }())

        // Assert bun is bundled — ACP providers (claude-acp via bunx) are broken
        // without it. If this fires, run `./build.sh` (which now hard-fails when
        // bun is absent) and reinstall to /Applications.
        if AgentLauncher.bundledHelperPath("bun") == nil {
            DebugLog.agent("⚠️ LAUNCH CHECK: bun NOT found in Contents/Helpers — ACP ingestion will fail. Run ./build.sh and reinstall.")
        }

        // Register the wikid daemon via SMAppService (macOS 13+). The daemon's
        // plist is at Contents/Library/LaunchAgents/com.selfdrivingwiki.wikid.plist
        // and its binary is at Contents/Helpers/wikid. SMAppService registers
        // it as a launchd-managed LaunchAgent that inherits the app's bundle
        // identity + TCC trust — no kTCCServiceSystemPolicyAppData prompts.
        // See plans/multi-wiki-daemon.md §4.3.
        // Best-effort: if registration fails (e.g. not in an app bundle during
        // `swift run`), the daemon simply won't be available — wikictl falls
        // back to direct file access.
        do {
            let daemonService = SMAppService.agent(plistName: "com.selfdrivingwiki.wikid.plist")
            try daemonService.register()
            DebugLog.store("wikid: SMAppService registered, status=\(daemonService.status.rawValue)")
        } catch {
            DebugLog.store("wikid: SMAppService registration failed (expected in dev mode): \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(manager: manager, fileProvider: fileProvider, agentLauncher: agentLauncher, chatLauncher: chatLauncher, extractionCoordinator: extractionCoordinator)
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
                .alert(
                    "Vacuum Orphaned Storage",
                    isPresented: Binding(
                        get: { manager.pendingVacuumAll != nil },
                        set: { if !$0 { manager.pendingVacuumAll = nil } }
                    ),
                    presenting: manager.pendingVacuumAll
                ) { report in
                    if report.isEmpty {
                        Button("OK", role: .cancel) {}
                    } else {
                        Button("Cancel", role: .cancel) {}
                        Button("Vacuum", role: .destructive) { manager.applyVacuumAll() }
                    }
                } message: { report in
                    Text(report.alertMessage)
                }
                .task {
                    fileProvider.wire(into: manager)
                    // Phase 7: reap stale open workspaces older than 24h on launch.
                    // Cleans up crashed/abandoned ingest runs that never merged.
                    if let model = manager.activeStore {
                        _ = try? model.reapStaleWorkspaces(ttl: 86_400)
                    }
                    // First render already loaded the wiki list (reloadData, no
                    // selection).  Now set the active store: only triggers selectRow
                    // (not reloadData), so no NSTableView reentrancy on macOS 26.
                    manager.activateMostRecent()
                    if let warning = await FileProviderSetupVerifier.verifyAndRepairInstalledProvider() {
                        fileProviderSetupWarning = warning
                        showingFileProviderSetupWarning = true
                    }
                    await fileProvider.migrateDomainsIfNeeded(
                        wikiIDs: manager.wikis.map(\.id))
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
            VacuumCommands(manager: manager)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { manager.activeStore?.flushPendingSaves() }
            isSceneActive = (phase == .active)
            if phase == .active { Task { await manager.upgradeActiveStoreSearchIndex() } }
        }
        // Keep the bridge's Darwin observations in lockstep with the wiki set:
        // a freshly-created wiki's CLI writes must be heard; a deleted wiki's
        // notification name released.
        .onChange(of: manager.wikis) { _, _ in
            changeBridge?.refreshObservations()
        }
        // Backfill embeddings for a freshly-selected store, but only once the
        // window is up. The launch-time activation (in the root `.task`) sets
        // `activeWikiID` before the scene becomes active, so this is skipped at
        // launch — the `scenePhase == .active` transition covers that case.
        .onChange(of: manager.activeWikiID) { _, _ in
            if isSceneActive { Task { await manager.upgradeActiveStoreSearchIndex() } }
        }

        // Track C extraction compare: a real, resizable, non-modal window (one
        // per source, opened via `openWindow(value:)` from SourceDetailView).
        // Shares the main window's `manager` so Set Active propagates live.
        WindowGroup("Compare Extractions", for: ExtractionCompareContext.self) { $context in
            ExtractionCompareWindow(manager: manager, context: context)
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)

        Settings {
            TabView {
                AboutView()
                    .tabItem { Label("About", systemImage: "info.circle") }
                ZoteroSettingsView(containerDirectory: containerDirectory)
                    .tabItem { Label("Zotero", systemImage: "books.vertical") }
                ExtractionSettingsView(containerDirectory: containerDirectory, launcher: agentLauncher)
                    .tabItem { Label("Extraction", systemImage: "doc.viewfinder") }
                AgentsSettingsView(containerDirectory: containerDirectory)
                    .tabItem { Label("Agents", systemImage: "cpu") }
            }
            .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
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
    /// keep the active store's resource-change bus wired to a debounced
    /// `signalChange()` after every store swap (select / create / delete).
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
            // Subscribe the FP signaler to the freshly-swapped store's bus (all
            // kinds/origins, debounced via ChangeCoalescer) so local app writes
            // refresh the mount — replacing the old `onPageDidChange` hand-fire.
            self.subscribeActiveStoreBus(manager.activeStore?.eventBus, wikiID: manager.activeWikiID)
            if let active = manager.activeWikiID,
               let descriptor = manager.wikis.first(where: { $0.id == active }) {
                Task { await self.activate(id: descriptor.id, displayName: descriptor.displayName) }
            }
        }
    }
}
