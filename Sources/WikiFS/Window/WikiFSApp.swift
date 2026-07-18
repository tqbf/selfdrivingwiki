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
    @State private var queueEngine: QueueEngine
    /// App-wide extraction provider. Bridges the headless queue engine to the
    /// `@MainActor` `ExtractionCoordinator` + `WikiStoreModel`.
    @State private var extractionProvider: any QueueExtractionProvider
    /// App-wide ingestion provider. Bridges the headless queue engine to the
    /// `@MainActor` `AgentLauncher` + `WikiStoreModel` for ingestion.
    @State private var ingestionProvider: any QueueIngestionProvider
    /// Mutable box for the file provider reference — the ingestion provider
    /// uses it to access the `FileProviderFacade` which is only available
    /// after the `@State` property is initialized by SwiftUI.
    @State private var fileProviderBox: FileProviderBox
    /// App-wide queue-activity tracker. Observes `QueueEngine.events` and
    /// exposes `@Observable` extraction state (extractingSourceIDs, progress
    /// log, etc.) that replaces the launcher's slot machinery.
    @State private var activityTracker: QueueActivityTracker
    @State private var showingLaunchLocationWarning: Bool
    @State private var fileProviderSetupWarning: FileProviderSetupWarning?
    @State private var showingFileProviderSetupWarning = false
    /// Drives the Settings TabView selection so the activity windows can open
    /// Settings on the relevant tab (gear button → extraction/agents config).
    @AppStorage("settings.selectedTab") private var settingsSelectedTabRaw = SettingsTab.about.rawValue
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

    // NOTE: There must be exactly ONE @NSApplicationDelegateAdaptor. Registering
    // two adaptors with different types (e.g. a separate QuitConfirmationDelegate)
    // causes only one to win the NSApplication.shared.delegate slot; accessing the
    // other triggers an unconditional `as!` cast that aborts at launch (#378).
    // The quit-confirmation logic lives on AppDelegate itself.

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
        let usageBox = UsageEmitBox()
        let liveUsageBox = LiveUsageEmitBox()
        let extractionFactory = QueueExtractionWorkerFactory(
            provider: extractionProvider,
            emitProgress: { id, line in progressBox.emit?(id, line) })
        let ingestionFactory = QueueIngestionWorkerFactory(
            provider: ingestionProvider,
            emitProgress: { id, line in progressBox.emit?(id, line) },
            emitTranscript: { id, event in transcriptBox.emit?(id, event) },
            emitUsage: { id, usage in usageBox.emit?(id, usage) },
            emitLiveUsage: { id, usage in liveUsageBox.emit?(id, usage) })
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
        Task { usageBox.emit = await queueEngine.makeEmitUsage() }
        Task { liveUsageBox.emit = await queueEngine.makeEmitLiveUsage() }
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
        _windowTracker = State(initialValue: WindowListTracker())
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
            openWindowBridge: openWindowBridge)
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
                    if session.chatLauncher.isRunning {
                        return "A chat session"
                    }
                }
            }
            return nil
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
                bootstrapApp()
                startStatusItem()
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
            .appEnvironment(tracker: activityTracker)
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
        }
        .defaultSize(width: 1080, height: 740)
        .windowResizability(.contentMinSize)

        Settings {
            TabView(selection: settingsSelectedTab) {
                AboutView()
                    .tag(SettingsTab.about)
                    .tabItem { Label("About", systemImage: "info.circle") }
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ZoteroSettingsView(containerDirectory: containerDirectory)
                    .tag(SettingsTab.zotero)
                    .tabItem { Label("Zotero", systemImage: "books.vertical") }
                ExtractionSettingsView(containerDirectory: containerDirectory, launcher: settingsLauncher)
                    .tag(SettingsTab.extraction)
                    .tabItem { Label("Extraction", systemImage: "doc.viewfinder") }
                AgentsSettingsView(containerDirectory: containerDirectory)
                    .tag(SettingsTab.agents)
                    .tabItem { Label("Agents", systemImage: "cpu") }
            }
            .appEnvironment(tracker: activityTracker)
            .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }

    /// Settings tab tags used by the TabView selection and `@AppStorage`.
    enum SettingsTab: String {
        case about
        case zotero
        case extraction
        case agents
    }

    /// Binding that bridges `@AppStorage(String)` → `SettingsTab` for the
    /// Settings `TabView(selection:)`.
    private var settingsSelectedTab: Binding<SettingsTab> {
        Binding(
            get: { SettingsTab(rawValue: settingsSelectedTabRaw) ?? .about },
            set: { settingsSelectedTabRaw = $0.rawValue }
        )
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

    /// Called from `applicationShouldHandleReopen` (Dock click) to restore a
    /// wiki window when the user reopens the app with no visible windows.
    /// Opens the MRU wiki's window, or the main window (empty-state) if no
    /// wikis exist. Wired in `startStatusItem()` where both `registry` and
    /// `openWindowBridge` are in scope.
    var reopenMostRecentWiki: (() -> Void)?

    /// `@AppStorage` key for the "ask before quitting" toggle (Settings →
    /// General). Default is "ask" (true) when unset — matching the feature's
    /// purpose. Referenced by `GeneralSettingsView`.
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
        // quit now without a dialog.
        guard activeOp != nil || Self.confirmBeforeQuitting else {
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

        // Present as a sheet on the current key window when possible; fall back
        // to a modal dialog when no window is available (e.g. all windows
        // closed but app still active in accessory mode).
        if let window = sender.windows.first(
            where: { $0.isVisible && $0.canBecomeKey }
        ) {
            alert.beginSheetModal(for: window) { response in
                NSApp.reply(
                    toApplicationShouldTerminate:
                        response == .alertFirstButtonReturn
                )
            }
        } else {
            let response = alert.runModal()
            NSApp.reply(
                toApplicationShouldTerminate:
                    response == .alertFirstButtonReturn
            )
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
    func appEnvironment(tracker: QueueActivityTracker) -> some View {
        assert(tracker.isAttachedToEngine, "QueueActivityTracker must be attached to a QueueEngine before injecting into a scene")
        return self
            .environment(tracker)
    }
}
