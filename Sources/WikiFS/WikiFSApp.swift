import SwiftUI
import ServiceManagement
import WikiFSEngine
import WikiFSCore
import WikiFSMLX

/// Entry point for the WikiFS macOS app.
///
/// Phase 0 (many wikis): a `WikiRegistryClient` owns the registry of wikis +
/// the active wiki id, and a `WikiSession` (one per active wiki) owns the store
/// + launchers + gate. The registry never opens a store; the session is
/// created/destroyed in the `.onChange(of: registry.activeWikiID)` handler.
/// One File Provider domain is registered per wiki on launch. The legacy
/// single-wiki `WikiFS.sqlite` is migrated into the registry as wiki #1 by
/// `WikiRegistryClient.bootstrap()`.
///
/// Flushes pending autosave when the app stops being active (§3.5
/// immediate-on-background — don't lose buffered edits on quit).
@main
struct WikiFSApp: App {
    private let launchLocationWarning: LaunchLocationWarning?
    private let containerDirectory: URL
    @State private var registry: WikiRegistryClient
    @State private var session: WikiSession?
    @State private var fileProvider = FileProviderSpike()
    /// One app-scoped launcher for Settings-only use ("Test Connection" + backend
    /// config). Has its own `GenerationGate`, independent of any session's gate
    /// — a Settings connection test doesn't block an active wiki's ingest.
    @State private var settingsLauncher: AgentLauncher
    /// App-wide extraction backend resolver (local pdf2md / Claude / Docling
    /// Serve). Threaded like `settingsLauncher` — one instance, owned by the app,
    /// shared as a ref into each `WikiSession` (it carries no per-wiki state).
    @State private var extractionCoordinator: ExtractionCoordinator
    @State private var showingLaunchLocationWarning: Bool
    @State private var fileProviderSetupWarning: FileProviderSetupWarning?
    @State private var showingFileProviderSetupWarning = false
    /// Built lazily after `bootstrap` (it needs the registered wikis) — see the
    /// `.task` below. The change bridge observes `wikictl`'s Darwin notifications.
    @State private var changeBridge: WikiChangeBridge?
    /// A class-based holder for the active session so the registry's
    /// `flushActiveStore` closure (set in `.task`) can always reach the
    /// *current* session at invocation time. `WikiFSApp` is a struct, so a
    /// closure can't capture `self` by reference — this holder is the bridge.
    @State private var sessionRef = SessionRef()
    /// Tracks whether the main window scene is active, so wiki switches (which
    /// fire `activeWikiID` onChange) only kick off the Metal embedding backfill
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
        // `WikiRegistryClient.bootstrap()` to adopt as wiki #1. Once ANY wiki
        // exists, this is skipped — otherwise the registry renames the container
        // file away on each launch, this layer re-copies it from Application
        // Support, and the two form an infinite duplication loop.
        if WikiRegistry.load(from: directory).isEmpty {
            DatabaseLocation.migrateFromApplicationSupportIfNeeded()
        }
        containerDirectory = directory
        // Populate wikis BEFORE handing the registry to @State so SwiftUI's
        // first render sees a non-empty list.  activateNow: false means
        // activeWikiID stays nil for that render — NSTableView's initial
        // reloadData runs with data but no selection, which is safe.
        // activateMostRecent() in .task sets the selection AFTER the first
        // render; that update is selectRow-only (no concurrent reloadData),
        // avoiding an NSTableView reentrant-delegate warning on macOS 26.
        let r = WikiRegistryClient(containerDirectory: directory)
        r.bootstrap(activateNow: false)
        _registry = State(initialValue: r)
        let coordinator = ExtractionCoordinator(
            containerDirectory: directory,
            localExtractorFactory: { LocalPdf2MarkdownExtractor() })
        _extractionCoordinator = State(initialValue: coordinator)
        // Settings-only launcher (D5): its own gate, independent of any
        // session's gate. Used for "Test Connection" + backend config only.
        let settingsGate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])
        _settingsLauncher = State(initialValue: {
            let l = AgentLauncher(generationGate: settingsGate, extractionCoordinator: coordinator)
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
            RootView(session: session, registry: registry, fileProvider: fileProvider)
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
                        get: { session?.pendingVacuumAll != nil },
                        set: { if !$0 { session?.pendingVacuumAll = nil } }
                    ),
                    presenting: session?.pendingVacuumAll
                ) { report in
                    if report.isEmpty {
                        Button("OK", role: .cancel) {}
                    } else {
                        Button("Cancel", role: .cancel) {}
                        Button("Vacuum", role: .destructive) { session?.applyVacuumAll() }
                    }
                } message: { report in
                    Text(report.alertMessage)
                }
                .task {
                    fileProvider.wire(into: registry)
                    registry.flushActiveStore = { [sessionRef] in
                        sessionRef.session?.store.flushPendingSaves()
                    }
                    // First render already loaded the wiki list (reloadData, no
                    // selection).  Now set the active wiki id: only triggers
                    // selectRow (not reloadData), so no NSTableView reentrancy.
                    registry.activateMostRecent()
                    if let warning = await FileProviderSetupVerifier.verifyAndRepairInstalledProvider() {
                        fileProviderSetupWarning = warning
                        showingFileProviderSetupWarning = true
                    }
                    await fileProvider.migrateDomainsIfNeeded(
                        wikiIDs: registry.wikis.map(\.id))
                    await registry.registerAllDomains()
                    // Stand up the change bridge now that the registry is loaded,
                    // then observe every wiki's `wikictl` Darwin notification.
                    let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
                    bridge.refreshObservations()
                    changeBridge = bridge
                    // The onChange handler (below) fires asynchronously from
                    // `registry.activateMostRecent()` above — it may have already
                    // created a session before the bridge existed. Wire it now.
                    // If it hasn't fired yet (session is nil), the next onChange
                    // will set the bridge's session itself.
                    if let session {
                        bridge.session = session
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            VacuumCommands(session: session)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session?.store.flushPendingSaves() }
            isSceneActive = (phase == .active)
            if phase == .active { Task { await session?.upgradeSearchIndex() } }
        }
        // Keep the bridge's Darwin observations in lockstep with the wiki set:
        // a freshly-created wiki's CLI writes must be heard; a deleted wiki's
        // notification name released.
        .onChange(of: registry.wikis) { _, _ in
            changeBridge?.refreshObservations()
        }
        // Create / destroy a WikiSession whenever the active wiki id changes.
        // This is the core of the dissolution: the registry owns the id, this
        // handler owns the session + the FP bus wiring + the FP domain
        // activation + the stale-workspace reaping + the search-index
        // backfill.
        .onChange(of: registry.activeWikiID) { _, newID in
            guard let newID,
                  let descriptor = registry.wikis.first(where: { $0.id == newID }) else {
                session?.store.flushPendingSaves()
                session = nil
                sessionRef.session = nil
                changeBridge?.session = nil
                return
            }
            // Tear down old session (flushes pending saves).
            session?.store.flushPendingSaves()
            // Create new session.
            let newSession = WikiSession(
                wikiID: newID,
                descriptor: descriptor,
                containerDirectory: containerDirectory,
                extractionCoordinator: extractionCoordinator,
                pdf2mdScriptPathResolver: { PdfExtractionService.resolveScript()?.path }
            )
            session = newSession
            sessionRef.session = newSession
            // Wire the bridge.
            changeBridge?.session = newSession
            // Wire the File Provider bus subscription + activate domain.
            fileProvider.subscribeActiveStoreBus(newSession.store.eventBus, wikiID: newID)
            Task { await fileProvider.activate(id: descriptor.id, displayName: descriptor.displayName) }
            // Reap stale workspaces (was in .task on launch — now per-session).
            _ = try? newSession.store.reapStaleWorkspaces(ttl: 86_400)
            // Backfill embeddings for the freshly-selected wiki. Only when the
            // scene is already active — the launch-time activation is covered by
            // the scenePhase == .active transition.
            if isSceneActive { Task { await newSession.upgradeSearchIndex() } }
        }

        // Track C extraction compare: a real, resizable, non-modal window (one
        // per source, opened via `openWindow(value:)` from SourceDetailView).
        // Shares the main window's session so Set Active propagates live.
        WindowGroup("Compare Extractions", for: ExtractionCompareContext.self) { $context in
            ExtractionCompareWindow(session: session, context: context)
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)

        Settings {
            TabView {
                AboutView()
                    .tabItem { Label("About", systemImage: "info.circle") }
                ZoteroSettingsView(containerDirectory: containerDirectory)
                    .tabItem { Label("Zotero", systemImage: "books.vertical") }
                ExtractionSettingsView(containerDirectory: containerDirectory, launcher: settingsLauncher)
                    .tabItem { Label("Extraction", systemImage: "doc.viewfinder") }
                AgentsSettingsView(containerDirectory: containerDirectory)
                    .tabItem { Label("Agents", systemImage: "cpu") }
            }
            .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// A class-based holder for the active `WikiSession` so the registry's
/// `flushActiveStore` closure (set in `.task`) can always reach the current
/// session at invocation time. `WikiFSApp` is a struct — closures can't capture
/// it by reference. This holder is the bridge: the app updates `session` on
/// every wiki switch, and the closure captures the holder, not the app.
@MainActor
private final class SessionRef {
    weak var session: WikiSession?
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
    /// Inject this provider's per-wiki domain side effects into the registry, so
    /// `createWiki` / `deleteWiki` / `renameWiki` can register/remove/rename FP
    /// domains. The FP bus subscription to the active store is wired separately
    /// in the `.onChange(of: registry.activeWikiID)` handler (the session is
    /// created there).
    @MainActor
    func wire(into registry: WikiRegistryClient) {
        registry.registerDomain = { [weak self] id, name in
            await self?.registerDomain(id: id, displayName: name)
        }
        registry.removeDomain = { [weak self] id in
            await self?.removeDomain(id: id)
        }
        registry.renameDomain = { [weak self] id, name in
            await self?.renameDomain(id: id, displayName: name)
        }
    }
}
