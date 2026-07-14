import SwiftUI
import ServiceManagement
import WikiFSEngine
import WikiFSCore
import WikiFSMLX

/// Entry point for the WikiFS macOS app.
///
/// Phase 0 (many wikis) + Phase 2b (multi-window): a `WikiRegistryClient` owns
/// the registry of wikis + the active wiki id (MRU launch only — it no longer
/// drives session creation). A `SessionManager` owns the `[wikiID: WikiSession]`
/// cache — each window's `RootScene` resolves its own session via
/// `sessionManager.session(for:descriptor:)`. Two windows over the same wiki
/// share one session (one store, one bus, one gate); two windows over different
/// wikis get independent sessions with independent gates. The change bridge's
/// `sessionLookup` closure routes `wikictl`-write flushes to all matching
/// sessions. One File Provider domain is registered per wiki on launch; each
/// active session's bus gets its own FP subscription.
@main
struct WikiFSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let launchLocationWarning: LaunchLocationWarning?
    private let containerDirectory: URL
    @State private var registry: WikiRegistryClient
    /// Multi-window: owns the `[wikiID: WikiSession]` cache. Each window's
    /// `RootScene` calls `sessionManager.session(for:descriptor:)` to resolve
    /// its session. Replaces the former `@State session` + `SessionRef`.
    @State private var sessionManager: SessionManager
    @State private var fileProvider = FileProviderSpike()
    /// One app-scoped launcher for Settings-only use ("Test Connection" + backend
    /// config). Has its own `GenerationGate`, independent of any session's gate
    /// — a Settings connection test doesn't block an active wiki's ingest.
    @State private var settingsLauncher: AgentLauncher
    /// App-wide extraction backend resolver (local pdf2md / Claude / Docling
    /// Serve). Threaded like `settingsLauncher` — one instance, owned by the app,
    /// shared as a ref into each `WikiSession` (it carries no per-wiki state).
    @State private var extractionCoordinator: ExtractionCoordinator
    /// App-wide queue engine. Owns the persistent `queue.sqlite` store; drives
    /// extraction/ingestion workers off-main. One instance, shared across
    /// sessions via `WikiSession`.
    @State private var queueEngine: QueueEngine
    /// App-wide extraction provider. Bridges the headless queue engine to the
    /// `@MainActor` `ExtractionCoordinator` + `WikiStoreModel`.
    @State private var extractionProvider: any QueueExtractionProvider
    /// App-wide ingestion provider. Bridges the headless queue engine to the
    /// `@MainActor` `AgentLauncher` + `WikiStoreModel` for ingestion.
    @State private var ingestionProvider: any QueueIngestionProvider
    /// Mutable box for the file provider reference — the ingestion provider
    /// uses it to access the `FileProviderSpike` which is only available
    /// after the `@State` property is initialized by SwiftUI.
    @State private var fileProviderBox: FileProviderBox
    /// App-wide queue-activity tracker. Observes `QueueEngine.events` and
    /// exposes `@Observable` extraction state (extractingSourceIDs, progress
    /// log, etc.) that replaces the launcher's slot machinery.
    @State private var activityTracker: QueueActivityTracker
    @State private var showingLaunchLocationWarning: Bool
    @State private var fileProviderSetupWarning: FileProviderSetupWarning?
    @State private var showingFileProviderSetupWarning = false
    /// Built lazily after `bootstrap` (it needs the registered wikis) — see the
    /// `.task` below. The change bridge observes `wikictl`'s Darwin notifications.
    @State private var changeBridge: WikiChangeBridge?

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

        // Queue engine construction. Order matters (factory needs provider;
        // provider needs a session-lookup box; session manager needs engine +
        // provider). The box starts returning nil (no sessions yet) and is
        // wired to the real session manager after construction.
        let queueDBURL = (try? DatabaseLocation.queueDatabaseURL())
            ?? directory.appendingPathComponent("queue.sqlite", isDirectory: false)
        let queueStore: QueueStore
        do {
            queueStore = try QueueStore(databaseURL: queueDBURL)
        } catch {
            DebugLog.store("QueueEngine: failed to open queue.sqlite — using in-memory: \(error)")
            // swiftlint:disable:next force_try
            queueStore = try! QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        }
        let sessionBox = SessionLookupBox()
        let extractionProvider = AppQueueExtractionProvider(
            extractionCoordinator: coordinator,
            sessionBox: sessionBox)
        let fileProviderBox = FileProviderBox()
        let ingestionProvider = AppQueueIngestionProvider(
            sessionBox: sessionBox,
            fileProviderBox: fileProviderBox,
            wikictlDirectory: HelpersLocation.wikictlDirectory)
        // Create a progress-emit box — the closure starts as a no-op and is
        // replaced with the engine's continuation after the engine is
        // constructed (breaking the circular dependency: factory needs the
        // closure, engine needs the factory).
        let progressBox = ProgressEmitBox()
        let transcriptBox = TranscriptEmitBox()
        let extractionFactory = QueueExtractionWorkerFactory(
            provider: extractionProvider,
            emitProgress: { id, line in progressBox.emit?(id, line) })
        let ingestionFactory = QueueIngestionWorkerFactory(
            provider: ingestionProvider,
            emitProgress: { id, line in progressBox.emit?(id, line) },
            emitTranscript: { id, event in transcriptBox.emit?(id, event) })
        let workerFactory = CompositeWorkerFactory(factories: [
            .extraction: extractionFactory,
            .ingestion: ingestionFactory
        ])
        let queueEngine = QueueEngine(store: queueStore, workerFactory: workerFactory)
        // Wire the progress emit box to the engine's event continuation.
        // This is an actor-isolated call — use `await` to hop to the actor.
        // The box starts with a nil emit (no-op), so workers spawned before
        // this resolves simply drop progress lines (rare — the engine hasn't
        // dispatched yet at this point in init).
        Task { progressBox.emit = await queueEngine.makeEmitProgress() }
        Task { transcriptBox.emit = await queueEngine.makeEmitTranscript() }
        // Start the engine (rehydrate + crash recovery + initial dispatch).
        // Detached so the app's init isn't blocked; the engine is an actor so
        // `start()` is safe to call concurrently.
        Task { await queueEngine.start() }
        // Create the activity tracker and attach it to the engine's event
        // stream. The tracker is @Observable @MainActor so views can read
        // extraction state directly via @Environment.
        let activityTracker = QueueActivityTracker()
        activityTracker.attach(engine: queueEngine)
        _queueEngine = State(initialValue: queueEngine)
        _extractionProvider = State(initialValue: extractionProvider)
        _ingestionProvider = State(initialValue: ingestionProvider)
        _fileProviderBox = State(initialValue: fileProviderBox)
        _activityTracker = State(initialValue: activityTracker)

        let sm = SessionManager(
            containerDirectory: directory,
            extractionCoordinator: coordinator,
            queueEngine: queueEngine,
            extractionProvider: extractionProvider,
            pdf2mdScriptPathResolver: { PdfExtractionService.resolveScript()?.path }
        )
        _sessionManager = State(initialValue: sm)
        // Wire the session-lookup box to the real session manager now that
        // it's constructed. The provider (already captured by the factory)
        // sees live sessions through the box.
        sessionBox.setLookup { [weak sm] wikiID in
            sm?.sessions[wikiID]?.store
        }
        sessionBox.setSessionLookup { [weak sm] wikiID in
            sm?.sessions[wikiID]
        }
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
        // Main window: single-identity, opens on launch. Resolves the MRU
        // wiki via the `registry.activeWikiID` → `wikiID` adoption flow in
        // `RootScene`. This avoids the "empty window flash" that
        // `WindowGroup(for:)` would show before `.task` runs.
        WindowGroup {
            RootScene(
                wikiID: nil,
                registry: registry,
                sessionManager: sessionManager,
                fileProvider: fileProvider
            )
            .appEnvironment(tracker: activityTracker)
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
            // Keep the bridge's Darwin observations in lockstep with the wiki
            // set: a freshly-created wiki's CLI writes must be heard; a
            // deleted wiki's notification name released.
            .onChange(of: registry.wikis) { _, _ in
                changeBridge?.refreshObservations()
            }
            .task {
                fileProviderBox.provider = fileProvider
                fileProvider.wire(into: registry)
                // Flush a specific wiki's store before export/delete. The
                // closure receives the wiki ID so the registry can target the
                // right session.
                registry.flushActiveStore = { [sessionManager] wikiID in
                    sessionManager.flushSession(for: wikiID)
                }
                // First render already loaded the wiki list (reloadData, no
                // selection). Now set the active wiki id: only triggers
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
                // Route flushes to all matching sessions — a wikictl write to
                // wiki A must update every window showing wiki A.
                bridge.sessionLookup = { [sessionManager] wikiID in
                    sessionManager.allSessions.filter { $0.wikiID == wikiID }
                }
                bridge.refreshObservations()
                changeBridge = bridge
                // Give the AppDelegate a reference to the session manager so
                // it can flush ALL sessions on app background (R3 safety net —
                // unreleased sessions from closed-but-not-onDisappear'd
                // windows are drained here, since per-window scenePhase only
                // flushes active-window sessions).
                appDelegate.sessionManager = sessionManager

                // Create and start the queue status item (menu-bar presence).
                let statusController = QueueStatusItemController(
                    queueEngine: queueEngine,
                    activityTracker: activityTracker,
                    sessionManager: sessionManager)
                statusController.start()
                appDelegate.statusItemController = statusController
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Suppress the auto-generated File ▸ New Window command (Cmd-N).
            // This app is single-window per wiki; Cmd-N would open a broken
            // "No Wikis" empty-state window (issue #396).
            CommandGroup(replacing: .newItem) { }
            VacuumCommands(sessionManager: sessionManager)
        }
        // Additional wiki windows: value-driven by wiki ID. Opened from the
        // switcher via `openWindow(value: wiki.id)`. `WindowGroup(for:)`
        // deduplicates by `==`, so opening a wiki that already has a window
        // focuses it instead of spawning a duplicate.
        WindowGroup(for: String.self) { $wikiID in
            RootScene(
                wikiID: wikiID,
                registry: registry,
                sessionManager: sessionManager,
                fileProvider: fileProvider
            )
            .appEnvironment(tracker: activityTracker)
        }

        // Extraction compare: a real, resizable, non-modal window (one per
        // source + wiki, opened via `openWindow(value:)` from
        // SourceDetailView). Resolves the correct wiki's session via the
        // shared `SessionManager`.
        WindowGroup("Compare Extractions", for: ExtractionCompareContext.self) { $context in
            ExtractionCompareWindow(sessionManager: sessionManager, context: context)
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
            .appEnvironment(tracker: activityTracker)
            .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Minimal app delegate: drains ALL sessions' pending saves on app background
/// (the R3 safety net from `plans/multi-window-ui.md`). Per-window `scenePhase`
/// in `RootScene` only flushes the active window's session; this catches the
/// case where `onDisappear` didn't fire on window close and a session is
/// lingering in the `SessionManager` cache with unflushed editor drafts.
/// `applicationWillResignActive` fires when the app loses keyboard focus / is
/// backgrounded — the closest macOS equivalent to "all windows inactive."
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var sessionManager: SessionManager?
    @MainActor weak var statusItemController: QueueStatusItemController?

    func applicationWillResignActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            sessionManager?.flushAllSessions()
        }
    }

    /// Keep the app alive after the last window closes — it drops to
    /// menu-bar-only (accessory) mode so the queue engine keeps running.
    /// Always return false: the status item provides the quit path, and
    /// the queue is durable so work resumes on next launch.
    /// (Phase 6: activation policy switching — AC1.1, AC1.2)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    /// When the user reopens the app (Dock click, status item), restore
    /// normal dock presence (AC1.3).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
        }
        return true
    }

    /// Confirm quit if there's active queue work (AC1.4). For now, allow
    /// termination since the queue is durable (items persist to SQLite and
    /// resume on relaunch). A full quit-confirmation dialog is a future
    /// refinement.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
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
    /// Inject this provider's per-wiki domain side effects into the registry, so
    /// `createWiki` / `deleteWiki` / `renameWiki` can register/remove/rename FP
    /// domains. The FP bus subscription to each active session's store is wired
    /// separately in `RootScene.resolveSession(for:)` (per-window, via the
    /// `SessionManager`).
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

// MARK: - App environment injection

/// Centralizes all required `@Environment` injections for app scenes. Every
/// `WindowGroup` and `Settings` scene MUST use this modifier — if a new
/// `@Environment`-dependent type is added, add it here so no scene can forget.
///
/// The assert catches missing injections at debug-build runtime (fitness for
/// `@Environment`-dependent views like `WikiDetailView` and
/// `ExtractionSettingsView`).
extension View {
    @MainActor
    func appEnvironment(tracker: QueueActivityTracker) -> some View {
        assert(tracker.isAttachedToEngine, "QueueActivityTracker must be attached to a QueueEngine before injecting into a scene")
        return self
            .environment(tracker)
    }
}
