import Foundation
import Observation
import WikiFSCore

/// One per-active-wiki session: everything the view tree needs to drive ONE
/// wiki's editing, ingest, query, chat, vacuum, and search upgrade.
///
/// Created / destroyed by the app layer (`WikiFSApp`) whenever
/// `WikiRegistryClient.activeWikiID` changes — the registry client only owns
/// the wiki *list* and the active id; this type owns the active wiki's
/// *store* + its agents. That split is what lets ingest in one wiki stop
/// blocking a query in another (every session has its own DB file + its own
/// `WikiEventBus` + its own read pool + its own `GenerationGate`).
///
/// Lives in `WikiFSEngine` (not `WikiFSCore`) because it holds
/// `AgentLauncher`, `GenerationGate`, and `ExtractionCoordinator` — all
/// engine-layer types. `WikiFSCore` cannot depend on `WikiFSEngine` (the
/// engine already depends on core), so the session naturally sits here.
/// Both the app and a future daemon can link it.
///
/// The `extractionCoordinator` is **shared** (created once at app scope and
/// passed into each session) — it carries no per-wiki state, so sharing avoids
/// re-reading the same config file per session. `agentLauncher` /
/// `chatLauncher` / `generationGate` are per-session instances.
///
/// See `plans/dissolve-wikimanager.md` for the full dissolution rationale.
@MainActor
@Observable
public final class WikiSession {
    /// The wiki's stable ULID. Guaranteed non-nil (a session only exists while
    /// a wiki is open). Views read `session.wikiID` instead of the old
    /// `activeWikiID ?? ""`.
    public let wikiID: String

    /// The wiki's registry descriptor (display name, home page, etc). Updated
    /// in place if the app layer mutates the registry (rename / set home page)
    /// by calling `updateDescriptor(_:)`. Views read
    /// `session.descriptor.displayName` / `.homePageID` instead of the old
    /// `manager.wikis.first(where: { $0.id == id })`.
    public private(set) var descriptor: WikiDescriptor

    /// The active wiki's editing model — the sidebar/editor bind to THIS. Built
    /// fresh over the wiki's DB in `init` (matching the old
    /// manager's `openActive` path).
    public let store: WikiStoreModel

    /// Per-session agent launcher for ingest / query / lint runs. Each session
    /// gets its own so a long ingest in one wiki cannot block a query in
    /// another (they're on different `GenerationGate` instances). Wired with
    /// the same `pdf2mdScriptPathResolver` the app layer sets on the
    /// settings-only launcher — the resolver is a pure function, safe to
    /// share across sessions.
    public let agentLauncher: AgentLauncher

    /// Per-session chat launcher. Mirrors `agentLauncher` — paired with it on
    /// one shared per-session gate so chat turns and ingest runs in the SAME
    /// wiki still coordinate, while a different wiki's session runs
    /// independently.
    public let chatLauncher: AgentLauncher

    /// Shared, app-wide extraction backend resolver (local pdf2md / Claude /
    /// Docling Serve). Passed in from the app; carries no per-wiki state, so
    /// one instance serves every session.
    public let extractionCoordinator: ExtractionCoordinator

    /// Shared, app-wide queue engine. One instance serves every session —
    /// the engine routes extraction work off-main via workers, and serializes
    /// via the persistent `queue.sqlite` store. Session views access it to
    /// enqueue extraction + await completion during ingest.
    public let queueEngine: QueueEngine

    /// Shared, app-wide extraction provider. The app-layer bridge from the
    /// headless queue engine to the `@MainActor` `ExtractionCoordinator` +
    /// `WikiStoreModel`. One instance serves every session.
    public let extractionProvider: any QueueExtractionProvider

    /// Per-session generation gate. Each `WikiSession` owns its own so
    /// cross-wiki isolation is structural: a held gate on session A does not
    /// block session B. Lane limits match the app-wide gate the launchers
    /// previously shared (`.ingest: 1`, `.interactive: 3`).
    public let generationGate: GenerationGate

    // MARK: - Vacuum / GC state (moved from the dissolved manager)

    /// Non-nil while the "Vacuum Orphaned Storage…" confirm alert is on screen
    /// (Help menu → `previewBlobVacuum()`). Carries the dry-run report shown
    /// in the alert; cleared on Cancel / Vacuum.
    public var pendingBlobVacuum: BlobVacuumReport?

    /// Non-nil while the "Vacuum All…" confirm alert is on screen (Help menu →
    /// `previewVacuumAll()`). Carries the combined dry-run report for both
    /// blob and activity orphans; cleared on Cancel / Vacuum.
    public var pendingVacuumAll: VacuumReport?

    /// Phase 2 Tantivy search index (plans/tantivy-search-sidecar.md §4.4).
    /// Tantivy is now the PRIMARY BM25 leg of the hybrid search; FTS5 is kept
    /// as fallback. `nil` if construction failed (session never breaks over a
    /// derived index). Retained for the lifetime of the session so the
    /// `TantivyShadowSync` bus subscription stays alive.
    public let tantivyShadowSearch: TantivySearchService?

    /// Cross-window deferred `wiki://` navigation. Set by
    /// ``SessionManager`` when a `wiki://` link is clicked in a window
    /// whose wiki is NOT yet open (e.g. the Activity / queue window
    /// rendering an ingest transcript). `SessionManager` stashes the
    /// request keyed by wiki ID; `RootScene.resolveSession` transfers it
    /// onto the session as soon as the session is created, and `RootView`
    /// consumes it on appear — after the store is ready — by applying
    /// `WikiReaderView.onWikiLinkHandler`. Holds raw `URL` + the
    /// ⌘-click `openInNewTab` flag (Foundation types only, so the Engine
    /// layer never references the app-layer `WikiLinkRoute`). Same
    /// "set once / consume once" discipline as `pendingBlobVacuum`.
    public var pendingWikiLink: (url: URL, openInNewTab: Bool)?
    @ObservationIgnored private var tantivyShadowSync: TantivyShadowSync?

    // MARK: - Init

    /// Open `wikiID`'s DB and stand up the model + launchers for one wiki.
    ///
    /// Mirrors the old manager's `openActive` path: open the store, attach
    /// the per-wiki `WikiEventBus` BEFORE the model is created (so the model's
    /// `.external`→reload subscription sees it), build the model, attach a
    /// `WikiReadPool` for off-main snapshot reads (only for real file-backed
    /// DBs), and create the per-session launchers. If the store has no pages,
    /// seeds a Home page and wires it as the wiki's home page (#315).
    ///
    /// - Parameters:
    ///   - wikiID: The wiki's ULID.
    ///   - descriptor: The registry descriptor (display name / home page).
    ///   - containerDirectory: The App Group container holding the
    ///     `<ulid>.sqlite` file.
    ///   - extractionCoordinator: Shared, app-wide extraction backend resolver.
    ///   - makeStore: Injection seam for tests; defaults to
    ///     `SQLiteWikiStore(databaseURL:)`.
    ///   - pdf2mdScriptPathResolver: Resolves the bundled `pdf2md` script path
    ///     for the agent seatbelt. The app passes a closure delegating to
    ///     `PdfExtractionService.resolveScript()`; tests / the daemon default
    ///     to `{ nil }`.
    public init(
        wikiID: String,
        descriptor: WikiDescriptor,
        containerDirectory: URL,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: QueueEngine,
        extractionProvider: any QueueExtractionProvider,
        makeStore: @escaping (URL) throws -> WikiStore = { try StoreBackend.current.makeStore(databaseURL: $0) },
        pdf2mdScriptPathResolver: @escaping () -> String? = { nil }
    ) {
        self.wikiID = wikiID
        self.extractionCoordinator = extractionCoordinator
        self.queueEngine = queueEngine
        self.extractionProvider = extractionProvider

        // `var` so the Home-page seeding below can set `homePageID` before it
        // is committed to `self.descriptor`.
        var sessionDescriptor = descriptor

        let url = containerDirectory.appendingPathComponent("\(wikiID).sqlite", isDirectory: false)
        let model: WikiStoreModel
        // Captured across both store-open branches (file-backed + in-memory
        // fallback) so the Phase 1 Tantivy shadow service can read from the
        // same `WikiStore` the model wraps (the model keeps it `private`).
        var shadowStore: WikiStore?
        do {
            // `var`: the bus is set via the protocol's computed setter, which
            // the compiler treats as mutating through the `WikiStore`
            // existential.
            var store = try makeStore(url)
            // Attach the per-wiki event bus BEFORE the model is created, so the
            // model's `.external`→reload subscription (in its init) sees it. The
            // File Provider signaler and the change bridge subscribe to the
            // same bus from the app layer. See `plans/event-bus.md`.
            store.eventBus = WikiEventBus(wikiID: wikiID)
            shadowStore = store
            model = WikiStoreModel(store: store)
            // Seed a Home page when the store is empty (mirrors
            // `openActive` lines 334–341 + `createWiki`'s #315
            // linkage: a freshly-seeded Home page becomes the wiki's home
            // page when none is set yet).
            if model.summaries.isEmpty, let homeID = model.newPage(title: "Home") {
                if sessionDescriptor.homePageID == nil {
                    sessionDescriptor.homePageID = homeID
                }
            }
            // Off-main snapshot reads (debounced search) go through a
            // read-only pool over the same file. Only for real file-backed
            // DBs — a second connection to `:memory:` would see a different,
            // empty database.
            if FileManager.default.fileExists(atPath: url.path) {
                model.readPool = WikiReadPool(databaseURL: url)
            }
        } catch {
            // Opening the on-disk store failed (e.g. a corrupt DB the migration
            // self-heal couldn't repair). Degrade to an ephemeral in-memory
            // store so the app stays usable — the user sees an empty wiki rather
            // than a crash, and the on-disk file is left untouched for recovery.
            DebugLog.store("WikiSession: failed to open wiki \(wikiID), using in-memory: \(error)")
            let memory: SQLiteWikiStore
            do {
                memory = try SQLiteWikiStore(databaseURL: URL(fileURLWithPath: ":memory:"))
            } catch {
                // A fresh in-memory store builds only the current schema (no
                // ladder, no existing data), so this is unreachable in practice.
                // If it ever fails the process is unrecoverable — surface an
                // actionable message instead of an opaque `try!` trap.
                fatalError("WikiSession: in-memory fallback store failed to open for wiki \(wikiID): \(error)")
            }
            memory.eventBus = WikiEventBus(wikiID: wikiID)
            shadowStore = memory
            model = WikiStoreModel(store: memory)
        }
        self.store = model
        self.descriptor = sessionDescriptor

        // Phase 2 Tantivy search index (plans/tantivy-search-sidecar.md §4.4).
        // Phase 2 CUTOVER: Tantivy is now the PRIMARY BM25 leg of the hybrid
        // search. The service is injected into the model (`model.tantivySearch =
        // svc`) so the search path queries Tantivy first, falling back to FTS5
        // when Tantivy is unavailable/empty. Failures are non-fatal — the session
        // never breaks over a derived, rebuildable index; a failed start just
        // means no Tantivy results (FTS5 still answers). Reads happen off-main on
        // the indexer actor; the content source reads committed SQLite state
        // through its own recursive lock (no statement handle crosses a boundary).
        var shadowSearch: TantivySearchService?
        var shadowSync: TantivyShadowSync?
        if let shadowStore, let bus = shadowStore.eventBus {
            do {
                let contentSource = StoreBackedTantivyContentSource(store: shadowStore)
                let svc = try TantivySearchService(
                    wikiID: wikiID,
                    containerDirectory: containerDirectory,
                    contentSource: contentSource
                )
                let sync = TantivyShadowSync(service: svc, bus: bus)
                sync.start()
                shadowSearch = svc
                shadowSync = sync
                // Wire the service into the model's search path (Phase 2 cutover).
                model.tantivySearch = svc
            } catch {
                DebugLog.store("WikiSession: Tantivy search index disabled for wiki \(wikiID): \(error)")
            }
        }
        self.tantivyShadowSearch = shadowSearch
        self.tantivyShadowSync = shadowSync

        // Per-session gate: lane limits match the app-wide gate the launchers
        // previously shared. Each session gets its own so cross-wiki
        // isolation is structural.
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 3])
        self.generationGate = gate

        // Per-session launchers — both pair on this session's gate so ingest
        // and chat-turn generations in the SAME wiki coordinate, while a
        // different wiki's session runs independently.
        let agent = AgentLauncher(generationGate: gate, extractionCoordinator: extractionCoordinator)
        agent.pdf2mdScriptPathResolver = pdf2mdScriptPathResolver
        self.agentLauncher = agent

        let chat = AgentLauncher(generationGate: gate, extractionCoordinator: extractionCoordinator)
        chat.pdf2mdScriptPathResolver = pdf2mdScriptPathResolver
        self.chatLauncher = chat
    }

    // MARK: - Descriptor updates

    /// Refresh the in-memory descriptor when the registry mutates (rename /
    /// set home page). Called by the app layer after it mutates
    /// `WikiRegistryClient.wikis`. No-op for a different wiki id.
    public func updateDescriptor(_ newDescriptor: WikiDescriptor) {
        guard newDescriptor.id == wikiID else { return }
        descriptor = newDescriptor
    }

    // MARK: - Blob GC (#253)

    /// Preview orphaned blob storage for this wiki (Help menu). Runs a
    /// read-only dry run, then sets `pendingBlobVacuum` so the app-scene
    /// confirm alert appears.
    public func previewBlobVacuum() {
        pendingBlobVacuum = store.performBlobVacuum(dryRun: true)
    }

    /// Delete the orphaned blobs (the alert's Vacuum button), then clear the
    /// pending report.
    public func applyBlobVacuum() {
        _ = store.performBlobVacuum(dryRun: false)
        pendingBlobVacuum = nil
    }

    // MARK: - Vacuum All (blobs + activities, #257)

    /// Preview all reclaimable orphans (blobs + activities) for this wiki
    /// (Help menu). Runs a read-only dry run, then sets `pendingVacuumAll` so
    /// the app-scene confirm alert appears.
    public func previewVacuumAll() {
        pendingVacuumAll = store.performVacuumAll(dryRun: true)
    }

    /// Delete all orphaned blobs + activities (the alert's Vacuum button),
    /// then clear the pending report.
    public func applyVacuumAll() {
        _ = store.performVacuumAll(dryRun: false)
        pendingVacuumAll = nil
    }

    // MARK: - Search index upgrade

    /// Run the blocking search-index upgrade for this wiki's store (a no-op
    /// unless MiniLM is selected AND there is missing content). Safe to call
    /// repeatedly — `upgradeSearchIndex` is single-flight and idempotent.
    /// Driven by the app layer (scenePhase `.active` / wiki switch), never
    /// from the launch `.task`. While it runs a non-dismissible sheet blocks
    /// all UX so the upgrade is the sole owner of the store (no off-main
    /// SQLite).
    public func upgradeSearchIndex() async {
        await store.upgradeSearchIndex()
    }

    // MARK: - Tantivy search (Phase 2)

    /// Free-text search over this session's Tantivy index (Phase 2 primary BM25
    /// leg — plans/tantivy-search-sidecar.md §4.4). Returns kind-tagged hits with
    /// id/title/kind/score, decoupled from the store's typed summaries. Returns
    /// `nil` (not an empty list) when the Tantivy index was never built or
    /// failed to open, so a caller can distinguish "index unavailable (fall back
    /// to FTS5)" from "index queried, no matches."
    ///
    /// The production hybrid search uses this internally via
    /// `WikiStoreModel.resolveTantivyLeg(...)` — this public accessor is for
    /// direct/CLI/check queries that want the raw Tantivy hits without the
    /// semantic-cosine + RRF fusion the model applies.
    public func searchTantivy(
        query: String,
        kinds: [TantivyDocumentKind] = [],
        limit: Int = 20
    ) async -> [TantivyShadowSearchResult]? {
        guard let svc = tantivyShadowSearch else { return nil }
        return await svc.search(query: query, kinds: kinds, limit: limit)
    }
}
