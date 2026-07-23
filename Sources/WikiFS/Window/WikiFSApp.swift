import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiCtlCore
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
    @State private var fileProvider = FileProviderFacade()
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
    @State private var queueEngine: any QueueEngineClient
    /// App-wide extraction provider. Bridges the headless queue engine to the
    /// `@MainActor` `ExtractionCoordinator` + `WikiStoreModel`. Handles both
    /// bytes-based extraction (PDF, HTML) AND transcript fetching (YouTube
    /// captions, podcast feeds) — transcript sources resolve to a
    /// `transcriptFetch` closure in the `ExtractionResolution`.
    @State private var extractionProvider: any QueueExtractionProvider
    /// Mutable box for the file provider reference — the ingestion provider
    /// uses it to access the `FileProviderFacade` which is only available
    /// after the `@State` property is initialized by SwiftUI.
    @State private var fileProviderBox: FileProviderBox
    /// App-wide queue-activity tracker. Observes `QueueEngine.events` and
    /// exposes `@Observable` extraction state (extractingSourceIDs, progress
    /// log, etc.) that replaces the launcher's slot machinery.
    @State private var activityTracker: QueueActivityTracker
    @State private var backgroundIngestCoordinator: BackgroundIngestCoordinator
    @State private var showingLaunchLocationWarning: Bool
    @State private var fileProviderSetupWarning: FileProviderSetupWarning?
    @State private var showingFileProviderSetupWarning = false
    /// Drives the Settings TabView selection so the activity windows can open
    /// Settings on the relevant tab (gear button → extraction/agents config).
    @AppStorage("settings.selectedTab") private var settingsSelectedTabRaw = SettingsTab.zotero.rawValue
    /// Per-app appearance override (Light / Dark / System). Shared key with
    /// `AppearanceSettingsView`. Applied via `.preferredColorScheme` on every
    /// scene + `NSApp.appearance` for AppKit surfaces (NSAlert, menu bar).
    @AppStorage("backgroundIngestEnabled") private var backgroundIngestEnabled = false
    @AppStorage(AppearanceSettingsView.storageKey) private var appearanceModeRaw = AppearanceMode.system.rawValue
    /// Built lazily after `bootstrap` (it needs the registered wikis) — see the
    /// `.task` below. The change bridge observes `wikictl`'s Darwin notifications.
    @State private var changeBridge: WikiChangeBridge?
    /// Bridges SwiftUI's `@Environment(\.openWindow)` to AppKit (menu bar,
    /// app delegate) so wiki windows can be reopened from the status item
    /// when no windows are visible (accessory mode). Wired by
    /// `WindowBridgeProbe`, a hidden view inside the main `WindowGroup`.
    @State private var openWindowBridge = OpenWindowBridge()
    /// Owns the open-windows list for the standard Window menu (issue #567).
    @State private var windowTracker: WindowListTracker

    /// App-wide chat daemon coordinator (Phase C4). Owns the per-chat
    /// `RemoteChatSession` registry + wraps the 6 chat XPC commands. `nil`
    /// when the daemon is unavailable — chat surfaces then render an
    /// unavailable state (no local fallback; the daemon owns chat).
    @State private var chatDaemonCoordinator: ChatDaemonCoordinator?

    /// Manages the wikid LaunchAgent via `launchctl` (replaces SMAppService).
    /// The daemon is an unsandboxed binary — no entitlements, no provisioning
    /// profile. The app generates the LaunchAgent plist at runtime and
    /// bootstraps it via `launchctl bootstrap gui/<uid> <path>`. The daemon
    /// survives app quit (launchd manages it independently).
    private let daemonManager: DaemonLaunchAgentManager?

    // NOTE: There must be exactly ONE @NSApplicationDelegateAdaptor. Registering
    // two adaptors with different types (e.g. a separate QuitConfirmationDelegate)
    // causes only one to win the NSApplication.shared.delegate slot; accessing the
    // other triggers an unconditional `as!` cast that aborts at launch (#378).
    // The quit-confirmation logic lives on AppDelegate itself.

    init() {
        // Migrate the renamed chat-zoom @AppStorage key before any ChatDetailView reads
        // it. Idempotent: copies `conversation.zoom` → `chat.zoom` only when the
        // new key is unset and the old key is set; no-op for fresh installs.
        AppStorageMigration.migrateZoomKey(in: .standard)
        // #607: one-time migration of the pre-split `agentPermissionMode` key
        // into `chatPermissionMode`. Idempotent: only copies when the new chat
        // key has NEVER been written (object == nil check, not string == nil) and
        // the legacy key is set + valid. The legacy key is orphaned (not deleted)
        // — see `PermissionModeMigration` + `plans/acp-permissions.md` §5.3.
        PermissionModeMigration.migrateOnce()
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
        // One-shot: move any legacy file-keychain secrets onto the shared
        // DataProtection keychain (under the keychain-access-groups access group)
        // so the app AND the wikid daemon keep reading them after the
        // keychain-sharing change. No-op when no access group is configured
        // (tests / fresh clones) and idempotent in production. See
        // plans/keychain-sharing.md.
        KeychainSecretStore.migrateLegacyItemsToDataProtection()
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

        // Queue engine: connect to the wikid daemon via XPC (Phase A+B).
        // The daemon owns the ENTIRE queue (extraction + ingestion). The app
        // is a pure XPC client — all 13 QueueEngineClient methods proxy to
        // the daemon. One DB, one engine, one owner.
        //
        // Fallback: if the daemon isn't running (dev mode without
        // `make install-daemon`), construct a local QueueEngine so the app
        // stays functional.
        let sessionBox = SessionLookupBox()
        let extractionProvider = AppQueueExtractionProvider(
            extractionCoordinator: coordinator,
            sessionBox: sessionBox)
        let fileProviderBox = FileProviderBox()

        let queueEngine: any QueueEngineClient
        let activityTracker = QueueActivityTracker()

        if let daemonConnection = try? WikiDaemonConnection.connect() {
            DebugLog.store("WikiFSApp: connected to wikid daemon — using XPC proxy")
            let workloadClient = DaemonWorkloadClient(connection: daemonConnection)
            let eventSink = DaemonQueueEventSink()
            workloadClient.registerEventSink(eventSink)
            queueEngine = XPCQueueEngineProxy(
                workloadClient: workloadClient, eventSink: eventSink)
            activityTracker.attach(engine: queueEngine)
            Task { await activityTracker.rehydrate(from: queueEngine) }
            // #871 self-heal: if the daemon → app event stream breaks (sink
            // invalidated, envelope dropped), poll the snapshot so a finished
            // item still clears the spinner instead of spinning forever.
            activityTracker.startSnapshotWatchdog(engine: queueEngine)
            // Phase C4: the coordinator owns chat sessions over the same
            // connection + event sink (chat envelopes are demuxed alongside
            // queue events). Routes envelopes per chatID + wraps the 6 chat
            // XPC commands.
            chatDaemonCoordinator = ChatDaemonCoordinator(
                client: workloadClient, eventSink: eventSink)
        } else {
            DebugLog.store("wikid: daemon not responding to health check — using local QueueEngine fallback")
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
            let ingestionProvider = AppQueueIngestionProvider(
                sessionBox: sessionBox,
                fileProviderBox: fileProviderBox,
                wikictlDirectory: HelpersLocation.wikictlDirectory,
                queueStore: queueStore)
            let progressBox = ProgressEmitBox()
            let transcriptBox = TranscriptEmitBox()
            let usageBox = UsageEmitBox()
            let liveUsageBox = LiveUsageEmitBox()
            let logPathsBox = LogPathsEmitBox()
            let pendingPermissionBox = PendingPermissionEmitBox()
            let extractionFactory = QueueExtractionWorkerFactory(
                provider: extractionProvider,
                emitProgress: { id, line in progressBox.emit?(id, line) })
            let ingestionFactory = QueueIngestionWorkerFactory(
                provider: ingestionProvider,
                emitProgress: { id, line in progressBox.emit?(id, line) },
                emitTranscript: { id, event in transcriptBox.emit?(id, event) },
                emitUsage: { id, usage in usageBox.emit?(id, usage) },
                emitLiveUsage: { id, usage in liveUsageBox.emit?(id, usage) },
                emitLogPaths: { id, logURL, debugURL in logPathsBox.emit?(id, logURL, debugURL) },
                emitPendingPermission: { id, permission in pendingPermissionBox.emit?(id, permission) })
            let workerFactory = CompositeWorkerFactory(factories: [
                .extraction: extractionFactory,
                .ingestion: ingestionFactory,
            ])
            let localEngine = QueueEngine(store: queueStore, workerFactory: workerFactory)
            Task { progressBox.emit = await localEngine.makeEmitProgress() }
            Task { transcriptBox.emit = await localEngine.makeEmitTranscript() }
            Task { usageBox.emit = await localEngine.makeEmitUsage() }
            Task { liveUsageBox.emit = await localEngine.makeEmitLiveUsage() }
            Task { logPathsBox.emit = await localEngine.makeEmitLogPaths() }
            Task { pendingPermissionBox.emit = await localEngine.makeEmitPendingPermission() }
            Task { await localEngine.start() }
            queueEngine = localEngine
            activityTracker.attach(engine: localEngine)
            Task { await activityTracker.rehydrate(from: localEngine) }
        }

        _queueEngine = State(initialValue: queueEngine)
        _extractionProvider = State(initialValue: extractionProvider)
        _fileProviderBox = State(initialValue: fileProviderBox)
        _activityTracker = State(initialValue: activityTracker)

        let sm = SessionManager(
            containerDirectory: directory,
            extractionCoordinator: coordinator,
            queueEngine: queueEngine,
            extractionProvider: extractionProvider,
            pdf2mdScriptPathResolver: { PdfExtractionService.resolveScript()?.path },
            htmlMarkdownExtractorFactory: { LocalDefuddleExtractor() },
            htmlBackendResolver: { ExtractionConfig.load(from: directory).htmlBackend },
            podcastBackendResolver: { ExtractionConfig.load(from: directory).podcastBackend },
            interactiveUsageRecorder: { [weak activityTracker] usage in
                activityTracker?.recordInteractiveUsage(usage)
            }
        )
        _sessionManager = State(initialValue: sm)
        _windowTracker = State(initialValue: WindowListTracker())
        
        let backgroundIngestCoordinator = BackgroundIngestCoordinator(
            sessionManager: sm,
            queueEngine: queueEngine,
            quotaCoordinator: QuotaFallbackCoordinator()
        )
        _backgroundIngestCoordinator = State(initialValue: backgroundIngestCoordinator)
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

        // Bootstrap the wikid daemon via launchctl. The app generates the
        // LaunchAgent plist at runtime (it knows the container path + the
        // app bundle path), writes it to ~/Library/LaunchAgents/, and runs
        // `launchctl bootstrap`. The daemon is unsandboxed — no entitlements
        // (AMFI killed the old entitled binary because the bare Mach-O had
        // no embedded provisioning profile). It reads the app group container
        // directly via filesystem permissions. The daemon survives app quit.
        // Best-effort: in dev mode (`swift run`) the bootstrap still works
        // (the plist points at the container binary), wikictl falls back to
        // direct file access if the daemon isn't running.
        let manager = DaemonLaunchAgentManager(containerDirectory: directory)
        manager.bootstrap()
        self.daemonManager = manager

        // Call bootstrap directly from init.
        print("SDW: calling bootstrapApp from init")
        bootstrapApp()
    }

    /// App-level bootstrap: status item, file provider, activateMostRecent,
    /// change bridge. Called from BOTH AppDelegate.applicationDidFinishLaunching
    /// (guaranteed) AND the main WindowGroup's .task (fallback). Idempotent —
    /// guarded by a static flag.
    private static var didBootstrap = false
    @MainActor
    private func bootstrapApp() {
        DebugLog.tabs("WikiFSApp: bootstrapApp called, didBootstrap=\(Self.didBootstrap)")
        guard !Self.didBootstrap else { return }
        Self.didBootstrap = true

        // Synchronous part: activate most recent + file provider wiring.
        registry.activateMostRecent()
        fileProviderBox.provider = fileProvider
        fileProvider.wire(into: registry)
        registry.flushActiveStore = { [sessionManager] wikiID in
            sessionManager.flushSession(for: wikiID)
        }

        // Status item + File Provider setup run from .task (on the first
        // WindowGroup that appears) via bootstrapApp's idempotent guard.
        // The async Task parts also run from there.
    }

    /// Create and start the menu-bar status item. Called from .task (runs
    /// when a window appears — guaranteed even with state restoration).
    /// Idempotent — guarded by `didStartStatusItem`.
    @MainActor
    private static var didStartStatusItem = false
    @MainActor
    private func startStatusItem() {
        guard !Self.didStartStatusItem else { return }
        Self.didStartStatusItem = true

        let statusController = MenuBarItemController(
            queueEngine: queueEngine,
            activityTracker: activityTracker,
            sessionManager: sessionManager,
            registry: registry,
            openWindowBridge: openWindowBridge,
            backgroundIngestCoordinator: backgroundIngestCoordinator,
            daemonRestartHandler: { [daemonManager] in
                daemonManager?.restart()
            })
        statusController.start()
        windowTracker.start()
        appDelegate.menuBarItemController = statusController

        // Operation notifier: posts macOS local notifications when extraction,
        // ingestion, or lint reaches a terminal state. Subscribes to the same
        // event stream as the tracker and status item (multicast — free).
        let notifier = OperationNotifier(queueEngine: queueEngine)
        notifier.start()
        appDelegate.operationNotifier = notifier

        // File Provider setup + change bridge (async).
        Task {
            if let warning = await FileProviderSetupVerifier.verifyAndRepairInstalledProvider() {
                fileProviderSetupWarning = warning
                showingFileProviderSetupWarning = true
            }
            await fileProvider.migrateDomainsIfNeeded(
                wikiIDs: registry.wikis.map(\.id))
            await registry.registerAllDomains()

            let bridge = WikiChangeBridge(registry: registry, fileProvider: fileProvider)
            bridge.sessionLookup = { [sessionManager] wikiID in
                sessionManager.allSessions.filter { $0.wikiID == wikiID }
            }
            bridge.refreshObservations()
            changeBridge = bridge
            appDelegate.sessionManager = sessionManager
        }

        // Wire the quit-confirmation closures onto AppDelegate (the single app
        // delegate). Flush pending autosaves (don't lose buffered edits), and
        // report any active operation (extraction, ingestion, agent run) so the
        // quit dialog message is tailored and the app won't silently quit
        // mid-work even with the setting off.
        appDelegate.flushPendingSaves = { [weak sessionManager] in
            sessionManager?.flushAllSessions()
        }
        appDelegate.activeOperationDescription = { [weak activityTracker, weak sessionManager] in
            if activityTracker?.isExtracting == true {
                return "A PDF extraction"
            }
            // A lint runs through the `.ingestion` queue kind with empty
            // `sourceIDs` and a non-nil `lintPageIDs`, so `isIngesting` is
            // true for both ingestion and lint. Distinguish a lint-only run
            // via the tracker's source/lint ID sets so the quit dialog names
            // the operation actually in flight (not always "ingestion").
            if let tracker = activityTracker, tracker.isIngesting {
                if !tracker.lintingItemIDs.isEmpty
                    && tracker.ingestingSourceIDs.isEmpty {
                    return "A lint"
                }
                return "A source ingestion"
            }
            if let sm = sessionManager {
                for session in sm.allSessions {
                    if session.agentLauncher.isRunning {
                        return "An agent operation"
                    }
                }
            }
            // Phase C4: chat runs on the daemon — check the coordinator's
            // aggregate rather than a per-wiki chat launcher.
            if chatDaemonCoordinator?.anyChatRunning == true {
                return "A chat session"
            }
            return nil
        }
        appDelegate.cancelInFlightForQuit = {
            // Phase A+B: the daemon owns the queue. We do NOT cancel daemon
            // items on ⌘Q — extraction/ingestion survives the app quitting,
            // which is the whole point of the daemon architecture. The daemon
            // re-dispatches on its own when the app reconnects.
        }
        appDelegate.unregisterDaemon = { [daemonManager] in
            // The daemon survives app quit — launchd manages it independently
            // (KeepAlive + RunAtLoad). We do NOT bootout on terminate; the
            // daemon keeps running so extraction/ingestion/chat survive the
            // app quitting (the whole point of the daemon architecture). The
            // "Restart Daemon" menu item uses launchctl kickstart when needed.
            _ = daemonManager
        }
        appDelegate.reopenMostRecentWiki = { [registry, openWindowBridge] in
            if let wikiID = registry.activeWikiID ?? registry.wikis.first?.id {
                openWindowBridge.openWiki?(wikiID)
            } else {
                openWindowBridge.openMain?()
            }
        }
    }

    var body: some Scene {
        // Main window: single-identity, opens on launch. Resolves the MRU
        // wiki via the `registry.activeWikiID` → `wikiID` adoption flow in
        // `RootScene`. This avoids the "empty window flash" that
        // `WindowGroup(for:)` would show before `.task` runs.
        //
        // `id: "main"` lets `openWindow(id: "main")` reopen this window from
        // the status bar menu / Dock click when all windows are closed
        // (accessory mode) and there are no wikis to open via `openWindow(value:)`.
        WindowGroup(id: "main") {
            RootScene(
                wikiID: nil,
                registry: registry,
                sessionManager: sessionManager,
                fileProvider: fileProvider
            )
            .background(WindowBridgeProbe(bridge: openWindowBridge))
            .appEnvironment(
                tracker: activityTracker,
                openActivityWindow: { [weak openWindowBridge] queue in openWindowBridge?.openActivityWindow?(queue) },
                chatDaemon: chatDaemonCoordinator)
            .preferredColorScheme(appearanceColorScheme)
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
            .onChange(of: appearanceModeRaw) { _, _ in
                applyAppKitAppearance()
            }
            .task {
                bootstrapApp()
                startStatusItem()
                applyAppKitAppearance()
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // Suppress the auto-generated File ▸ New Window command (Cmd-N).
            // This app is single-window per wiki; Cmd-N would open a broken
            // "No Wikis" empty-state window (issue #396).
            CommandGroup(replacing: .newItem) { }
            VacuumCommands(sessionManager: sessionManager)
            // Window menu: open-windows list + Show Previous/Next Tab (⇧⌘[ / ⇧⌘]).
            WindowMenuCommands(
                sessionManager: sessionManager,
                windowTracker: windowTracker,
                registry: registry)
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
            .background(WindowBridgeProbe(bridge: openWindowBridge))
            .appEnvironment(
                tracker: activityTracker,
                openActivityWindow: { [weak openWindowBridge] queue in openWindowBridge?.openActivityWindow?(queue) },
                chatDaemon: chatDaemonCoordinator)
            .preferredColorScheme(appearanceColorScheme)
            .onAppear {
                DebugLog.tabs("RootScene wiki-window onAppear: wikiID=\(wikiID ?? "nil")")
            }
            .task {
                bootstrapApp()
                startStatusItem()
            }
            // The presented value can arrive AFTER first render (state
            // restoration) or change in place (openWindow(value:) routing to
            // an existing window). RootScene copies the value into @State at
            // creation, so key the whole subtree on it — a changed value must
            // rebuild RootScene, not be silently ignored.
            .id(wikiID)
        }

        // Extraction compare: a real, resizable, non-modal window (one per
        // source + wiki, opened via `openWindow(value:)` from
        // SourceDetailView). Resolves the correct wiki's session via the
        // shared `SessionManager`.
        WindowGroup("Compare Extractions", for: ExtractionCompareContext.self) { $context in
            ExtractionCompareWindow(sessionManager: sessionManager, context: context)
                .preferredColorScheme(appearanceColorScheme)
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)

        // Page versions: a real, resizable, non-modal window (one per page +
        // wiki, opened via `openWindow(value:)` from `PageDetailView`'s
        // inspector). Browse/diff/restore the page's version history (#817).
        // Mirrors the "Compare Extractions" group above.
        WindowGroup("Compare Versions", for: PageVersionCompareContext.self) { $context in
            PageVersionCompareWindow(sessionManager: sessionManager, context: context)
                .preferredColorScheme(appearanceColorScheme)
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)

        // Queue Activity windows: one per `QueueKind` (Ingestion + Extraction),
        // opened via `openWindow(value:)` / `openWindowBridge.openQueueWindow`.
        // `WindowGroup(for:)` deduplicates by `==`, so re-opening a queue's
        // window focuses the existing one (#835). System-managed scene replaces
        // the hand-built `NSWindow` — correct title-bar inset, frame persistence,
        // and state restoration come for free.
        WindowGroup("Agent Queue", for: QueueKind.self) { $queue in
            ActivityWindowView(
                queue: queue ?? .ingestion,
                queueEngine: queueEngine,
                activityTracker: activityTracker,
                sessionManager: sessionManager,
                openWindowBridge: openWindowBridge
            )
            .appEnvironment(
                tracker: activityTracker,
                openActivityWindow: { [weak openWindowBridge] queue in
                    openWindowBridge?.openQueueWindow?(queue)
                })
            .preferredColorScheme(appearanceColorScheme)
        }
        .defaultSize(width: 760, height: 500)
        .windowResizability(.contentMinSize)

        Settings {
            TabView(selection: settingsSelectedTab) {
                ZoteroSettingsView(containerDirectory: containerDirectory)
                    .tag(SettingsTab.zotero)
                    .tabItem { Label("Zotero", systemImage: "books.vertical") }
                ExtractionSettingsView(containerDirectory: containerDirectory, launcher: settingsLauncher)
                    .tag(SettingsTab.extraction)
                    .tabItem { Label("Extraction", systemImage: "doc.viewfinder") }
                AgentsSettingsView(containerDirectory: containerDirectory)
                    .tag(SettingsTab.agents)
                    .tabItem { Label("Providers", systemImage: "cpu") }
                OperationsSettingsView(containerDirectory: containerDirectory)
                    .tag(SettingsTab.operations)
                    .tabItem { Label("Operations", systemImage: "slider.horizontal.3") }
                AppearanceSettingsView()
                    .tag(SettingsTab.appearance)
                    .tabItem { Label("Appearance", systemImage: "paintbrush") }
            }
            .appEnvironment(tracker: activityTracker)
            .preferredColorScheme(appearanceColorScheme)
            .frame(minWidth: 560, minHeight: 520)
            .onChange(of: backgroundIngestEnabled) { _, newValue in
                if newValue {
                    backgroundIngestCoordinator.start()
                } else {
                    backgroundIngestCoordinator.stop()
                }
            }
        }
        .windowResizability(.contentMinSize)
    }

    /// Settings tab tags used by the TabView selection and `@AppStorage`.
    enum SettingsTab: String {
        case zotero
        case extraction
        case agents
        case operations
        case appearance
    }

    /// Binding that bridges `@AppStorage(String)` → `SettingsTab` for the
    /// Settings `TabView(selection:)`. Falls back to `.zotero` (the new
    /// first tab) when the stored raw value is missing or references a
    /// removed tab (e.g. `.about` / `.general` from before the About and
    /// General tabs were removed).
    private var settingsSelectedTab: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: settingsSelectedTabRaw) ?? .zotero },
            set: { settingsSelectedTabRaw = $0.rawValue }
        )
    }

    /// The `ColorScheme?` to apply via `.preferredColorScheme` on every scene.
    /// `nil` (`.system`) means no override — SwiftUI follows the OS.
    private var appearanceColorScheme: ColorScheme? {
        AppearanceMode(rawValue: appearanceModeRaw)?.colorScheme
    }

    /// Sync `NSApp.appearance` so AppKit-level surfaces (NSAlert, menu bar,
    /// status item) also honor the override. Called on launch (`.task`) and
    /// whenever `appearanceModeRaw` changes (`.onChange`). `.system` clears
    /// `NSApp.appearance` (nil → follows OS).
    @MainActor
    private func applyAppKitAppearance() {
        let mode = AppearanceMode(rawValue: appearanceModeRaw) ?? .system
        NSApp.appearance = mode.nsAppearanceName.flatMap { NSAppearance(named: $0) }
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
    /// STRONG on purpose: this is the only long-lived owner of the status-item
    /// controller. A weak reference here deallocates the controller the moment
    /// `startStatusItem()` returns, which removes the NSStatusItem from the
    /// menu bar before it ever draws.
    @MainActor var menuBarItemController: MenuBarItemController?
    /// Strong on purpose — the notifier's `streamTask` captures `self` weakly,
    /// so without a strong owner it deallocates the moment `start()` returns
    /// (same pattern as `menuBarItemController`).
    @MainActor var operationNotifier: OperationNotifier?
    @MainActor var bootstrap: (@MainActor () -> Void)?

    // MARK: - Quit confirmation (folded in from the former QuitConfirmationDelegate;
    // see #378 — there can be only one app delegate)

    /// Called before the app terminates so the model can flush buffered edits.
    /// Wired in `startStatusItem()`.
    var flushPendingSaves: (() -> Void)?

    /// Returns a human-readable description of any operation in flight (PDF
    /// extraction, source ingestion, agent run, or chat), or `nil` when idle.
    /// The quit dialog message is tailored based on what's running.
    var activeOperationDescription: (() -> String?)?

    /// Called when the user confirms quitting while operations are in flight.
    /// Cancels all in-flight queue items so crash recovery on restart skips
    /// them (they're `.cancelled`, not `.running`). Must complete BEFORE
    /// `NSApp.reply(toApplicationShouldTerminate:)` is called.
    var cancelInFlightForQuit: (() async -> Void)?

    /// Called on the terminate path to (optionally) stop the wikid daemon.
    /// The daemon now survives app quit (launchd-managed LaunchAgent), so
    /// this is a no-op — but the hook stays so the terminate flow doesn't
    /// need to know about the daemon's lifecycle model. Wired in
    /// `startStatusItem()`.
    var unregisterDaemon: (() -> Void)?

    /// Called from `applicationShouldHandleReopen` (Dock click) to restore a
    /// wiki window when the user reopens the app with no visible windows.
    /// Opens the MRU wiki's window, or the main window (empty-state) if no
    /// wikis exist. Wired in `startStatusItem()` where both `registry` and
    /// `openWindowBridge` are in scope.
    var reopenMostRecentWiki: (() -> Void)?

    /// `@AppStorage` key for the ask-before-quitting behavior. Default is
    /// `true` (ask) when unset. The Settings toggle was removed with the
    /// Permissions tab (the per-stage model picker now lives inline on the
    /// Agents tab — see
    /// `plans/inline-models-and-remove-permissions-tab-v2.md`); the key
    /// stays because `AppDelegate` reads `confirmBeforeQuitting` for quit
    /// gating.
    static let confirmQuitKey = "confirmBeforeQuitting"

    static var confirmBeforeQuitting: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: confirmQuitKey) != nil else { return true }
        return defaults.bool(forKey: confirmQuitKey)
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.tabs("AppDelegate: applicationDidFinishLaunching")
        MainActor.assumeIsolated {
            bootstrap?()
            removeRedundantAppMenuItems()
        }
    }

    /// Remove the auto-generated "About" and "Settings…" items from the
    /// "Self Driving Wiki" app menu. Both are surfaced under the menu-bar
    /// icon instead (`MenuBarItemController.buildMenu`) — the status item is
    /// reachable even in accessory mode, when the app has no menu bar. The
    /// Settings scene itself is untouched, so `showSettingsWindow:` (gear
    /// buttons, "Open Settings…") and the window keep working; the About
    /// panel opens from the icon via `orderFrontStandardAboutPanel:`.
    @MainActor
    private func removeRedundantAppMenuItems() {
        let settingsAction = Selector(("showSettingsWindow:"))
        let aboutAction = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        guard let mainMenu = NSApp.mainMenu else { return }
        for topLevel in mainMenu.items {
            guard let submenu = topLevel.submenu else { continue }
            // Iterate a snapshot (`submenu.items` is a fresh array), so
            // removing while iterating is safe. `action` is optional, so
            // compare against the selectors directly (optional == non-optional
            // lifts via Equatable) rather than via a Set<Selector>.
            submenu.items
                .filter {
                    $0.action == settingsAction
                        || $0.action == aboutAction
                        || $0.title.hasPrefix("Settings")
                        || $0.title.hasPrefix("About")
                }
                .forEach { submenu.removeItem($0) }
            tidySeparators(in: submenu)
        }
    }

    /// Collapse leading separators and consecutive duplicate separators that
    /// removing items leaves behind — NSMenu doesn't auto-merge them, so an
    /// un-tidied menu could start with a blank divider.
    @MainActor
    private func tidySeparators(in menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }
        var index = 0
        while index < menu.items.count {
            let nextIsSeparator = index + 1 < menu.items.count
                && menu.items[index + 1].isSeparatorItem
            if menu.items[index].isSeparatorItem && nextIsSeparator {
                menu.removeItem(at: index)
            } else {
                index += 1
            }
        }
    }

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
    /// normal dock presence (AC1.3) and open a wiki window if none are
    /// visible — so the user isn't stranded in accessory mode with no way
    /// back to their content.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !flag {
                NSApp.setActivationPolicy(.regular)
                reopenMostRecentWiki?()
            }
        }
        return true
    }

    /// Intercept termination to show a "confirm to quit" dialog (toggleable in
    /// Settings → General). Catches all quit paths: ⌘Q, Apple menu, Dock, and
    /// system shutdown. Returns `.terminateLater` so the system pauses while we
    /// present an `NSAlert`, then we reply with the user's choice.
    ///
    /// Even when `confirmBeforeQuitting` is **off**, the dialog appears if an
    /// extraction, ingestion, agent, or chat operation is in flight — silent
    /// termination during active work could lose data.
    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Flush pending saves regardless — don't lose buffered edits on quit.
        flushPendingSaves?()

        let activeOp = activeOperationDescription?()

        // If nothing is running AND the user has disabled confirm-before-quit,
        // quit now without a dialog. Unregister the daemon first so launchd
        // releases management (#863) — nothing is in flight to cancel.
        guard activeOp != nil || Self.confirmBeforeQuitting else {
            unregisterDaemon?()
            return .terminateNow
        }

        // Either the user wants confirmation, or there's active work we
        // shouldn't interrupt silently — show the dialog in both cases.
        let alert = NSAlert()
        alert.alertStyle = .warning

        if let description = activeOp {
            alert.messageText = "Quit Self Driving Wiki?"
            alert.informativeText =
                "\(description) is still running and will be cancelled. "
                + "Are you sure you want to quit?"
        } else {
            alert.messageText = "Quit Self Driving Wiki?"
            alert.informativeText = "Are you sure you want to quit?"
        }

        let quitButton = alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        quitButton.hasDestructiveAction = true
        quitButton.keyEquivalent = "\r"    // Return → default (Quit)
        // Make Cancel the escape-equivalent so ⎋ dismisses without quitting.
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        // Activate the app so the alert appears frontmost. On macOS 14+, the
        // new activate() API replaces the deprecated activate(ignoringOtherApps:).
        NSApp.activate(ignoringOtherApps: true)

        // Present as a sheet on the current key window when possible; fall back
        // to a modal dialog when no window is available (e.g. all windows
        // closed but app still active in accessory mode).
        if let window = sender.windows.first(
            where: { $0.isVisible && $0.canBecomeKey }
        ) {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn, let cancel = self.cancelInFlightForQuit {
                    // Cancel in-flight items BEFORE replying to terminate so
                    // crash recovery on restart skips them (.cancelled, not
                    // .running). The Task awaits cancellation, then replies
                    // on the main actor. The daemon unregister (#863) runs
                    // AFTER cancellation, while the daemon is still alive to
                    // process it, and BEFORE the terminate reply.
                    Task {
                        await cancel()
                        await MainActor.run {
                            self.unregisterDaemon?()
                            NSApp.reply(toApplicationShouldTerminate: true)
                        }
                    }
                } else {
                    if response == .alertFirstButtonReturn {
                        self.unregisterDaemon?()
                    }
                    NSApp.reply(
                        toApplicationShouldTerminate:
                            response == .alertFirstButtonReturn
                    )
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn, let cancel = self.cancelInFlightForQuit {
                Task {
                    await cancel()
                    await MainActor.run {
                        self.unregisterDaemon?()
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
            } else {
                if response == .alertFirstButtonReturn {
                    self.unregisterDaemon?()
                }
                NSApp.reply(
                    toApplicationShouldTerminate:
                        response == .alertFirstButtonReturn
                )
            }
        }

        // We've deferred the decision to the alert callback.
        return .terminateLater
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

extension FileProviderFacade {
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
    func appEnvironment(
        tracker: QueueActivityTracker,
        openActivityWindow: ((QueueKind) -> Void)? = nil,
        chatDaemon: ChatDaemonCoordinator? = nil
    ) -> some View {
        assert(tracker.isAttachedToEngine, "QueueActivityTracker must be attached to a QueueEngine before injecting into a scene")
        return self
            .environment(tracker)
            .environment(\.openActivityWindow, openActivityWindow)
            .environment(\.chatDaemonCoordinator, chatDaemon)
    }
}
