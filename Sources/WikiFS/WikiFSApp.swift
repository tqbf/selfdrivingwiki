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
        _sessionManager = State(initialValue: SessionManager(
            containerDirectory: directory,
            extractionCoordinator: coordinator,
            pdf2mdScriptPathResolver: { PdfExtractionService.resolveScript()?.path }
        ))
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
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
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
