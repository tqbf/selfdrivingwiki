#if os(macOS)
import CordisLoader
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
/// `generationGate` are per-session instances. (Chat is daemon-hosted after
/// Phase C4 — there is no per-session chat launcher.)
///
/// See `plans/dissolve-wikimanager.md` for the full dissolution rationale.
@MainActor
public protocol WikiSessionProtocol: AnyObject, Observable, Sendable {
    var wikiID: WikiID { get }
    var descriptor: WikiDescriptor { get }
    var store: WikiStoreModel { get }
    var agentLauncher: AgentLauncher { get }
    var extractionCoordinator: ExtractionCoordinator { get }
    var queueEngine: any QueueEngineClient { get }
    var extractionProvider: any QueueExtractionProvider { get }
    var generationGate: GenerationGate { get }
    var searchServices: any SearchServices { get }
    var pendingBlobVacuum: BlobVacuumReport? { get set }
    var pendingVacuumAll: VacuumReport? { get set }
    var pendingWikiLink: (url: URL, openInNewTab: Bool)? { get set }

    func updateDescriptor(_ descriptor: WikiDescriptor)
    func previewBlobVacuum()
    func applyBlobVacuum()
    func previewVacuumAll()
    func applyVacuumAll()
    func upgradeSearchIndex() async
    func searchTantivy(query: String, kinds: [TantivyDocumentKind], limit: Int) async -> [TantivyShadowSearchResult]?
    func shutdown() async
}

@MainActor
@Observable
public final class ProfileWikiSession: WikiSessionProtocol {
    /// Opaque child-profile ownership for production sessions. Explicit fixture
    /// sessions omit this lifetime and own only their test-created services.
    @ObservationIgnored private let profileLifetime: ProfileLifetime?
    /// The wiki's stable ULID. Guaranteed non-nil (a session only exists while
    /// a wiki is open). Views read `session.wikiID` instead of the old
    /// `activeWikiID ?? ""`.
    public let wikiID: WikiID

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

    /// Shared, app-wide extraction backend resolver (local pdf2md / Claude /
    /// Docling Serve). Passed in from the app; carries no per-wiki state, so
    /// one instance serves every session.
    public let extractionCoordinator: ExtractionCoordinator

    /// Shared, app-wide queue engine. One instance serves every session —
    /// the engine routes extraction work off-main via workers, and serializes
    /// via the persistent `queue.sqlite` store. Session views access it to
    /// enqueue extraction + await completion during ingest.
    ///
    /// Widened to `any QueueEngineClient` (Phase 0) so the source can flip
    /// from in-process `QueueEngine` to an `XPCQueueEngineProxy` without
    /// rewriting call sites. See `plans/daemon-workloads.md` Phase 0 §4.
    public let queueEngine: any QueueEngineClient

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

    /// Stable search facade. It remains unavailable until asynchronous runtime
    /// startup and event catch-up complete, then delegates to the private child.
    public let searchServices: any SearchServices

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
    @ObservationIgnored private let searchCompositionOwner: SearchCompositionOwner

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
    /// - Throws: If the on-disk store cannot be opened (e.g. a corrupt DB the
    ///   migration self-heal couldn't repair), the underlying `WikiStoreError`
    ///   is rethrown. There is **no in-memory fallback** — the caller
    ///   (`SessionManager`) records the error and surfaces a user-visible
    ///   message so the user understands their data isn't gone, the file just
    ///   couldn't be opened (issue #881).
    ///
    /// - Parameters:
    ///   - wikiID: The wiki's ULID.
    ///   - descriptor: The registry descriptor (display name / home page).
    ///   - containerDirectory: The App Group container holding the
    ///     `<ulid>.sqlite` file.
    ///   - extractionCoordinator: Shared, app-wide extraction backend resolver.
    ///   - makeStore: Injection seam for tests; defaults to
    ///     `GRDBWikiStore(databaseURL:)`.
    ///   - pdf2mdScriptPathResolver: Resolves the bundled `pdf2md` script path
    ///     for the agent seatbelt. The app passes a closure delegating to
    ///     `PdfExtractionService.resolveScript()`; tests / the daemon default
    ///     to `{ nil }`.
    public init(
        wikiID: WikiID,
        descriptor: WikiDescriptor,
        store: WikiStoreModel,
        searchCompositionOwner: SearchCompositionOwner,
        generationGate: GenerationGate,
        agentLauncher: AgentLauncher,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: any QueueEngineClient,
        extractionProvider: any QueueExtractionProvider,
        htmlMarkdownExtractor: (any HtmlMarkdownExtractor)? = nil,
        htmlBackend: HtmlExtractionBackend? = nil,
        podcastBackend: PodcastTranscriptionBackend? = nil,
        profileLifetime: ProfileLifetime
    ) {
        self.profileLifetime = profileLifetime
        self.wikiID = wikiID
        self.extractionCoordinator = extractionCoordinator
        self.queueEngine = queueEngine
        self.extractionProvider = extractionProvider
        self.store = store
        self.searchCompositionOwner = searchCompositionOwner
        self.searchServices = searchCompositionOwner.services
        self.generationGate = generationGate
        self.agentLauncher = agentLauncher

        var sessionDescriptor = descriptor
        if store.summaries.isEmpty, let homeID = store.newPage(title: "Home"), sessionDescriptor.homePageID == nil {
            sessionDescriptor.homePageID = homeID
        }
        self.descriptor = sessionDescriptor

        // UI adaptation only: the child profile has already constructed all
        // per-wiki domain services before this observable facade is initialized.
        store.htmlMarkdownExtractor = htmlMarkdownExtractor
        store.htmlBackend = htmlBackend
        store.podcastBackend = podcastBackend
    }

    /// Explicit fixture initializer for tests that do not boot a Cordis profile.
    public init(
        testFixtureWikiID wikiID: WikiID,
        descriptor: WikiDescriptor,
        store: WikiStoreModel,
        searchCompositionOwner: SearchCompositionOwner,
        generationGate: GenerationGate,
        agentLauncher: AgentLauncher,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: any QueueEngineClient,
        extractionProvider: any QueueExtractionProvider,
        htmlMarkdownExtractor: (any HtmlMarkdownExtractor)? = nil,
        htmlBackend: HtmlExtractionBackend? = nil,
        podcastBackend: PodcastTranscriptionBackend? = nil
    ) {
        self.profileLifetime = nil
        self.wikiID = wikiID
        self.extractionCoordinator = extractionCoordinator
        self.queueEngine = queueEngine
        self.extractionProvider = extractionProvider
        self.store = store
        self.searchCompositionOwner = searchCompositionOwner
        self.searchServices = searchCompositionOwner.services
        self.generationGate = generationGate
        self.agentLauncher = agentLauncher

        var sessionDescriptor = descriptor
        if store.summaries.isEmpty, let homeID = store.newPage(title: "Home"), sessionDescriptor.homePageID == nil {
            sessionDescriptor.homePageID = homeID
        }
        self.descriptor = sessionDescriptor
        store.htmlMarkdownExtractor = htmlMarkdownExtractor
        store.htmlBackend = htmlBackend
        store.podcastBackend = podcastBackend
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
    /// failed to open, so a caller can distinguish "index unavailable (no BM25
    /// leg post-#634 — FTS5 was dropped)" from "index queried, no matches."
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
        do {
            return try await searchServices.search(query: query, kinds: kinds, limit: limit)
        } catch {
            DebugLog.store("WikiSession: Tantivy search unavailable for wiki \(wikiID.rawValue): \(error)")
            return nil
        }
    }

    public func shutdownSearchRuntime() async {
        await searchCompositionOwner.shutdown()
    }

    public func shutdown() async {
        await shutdownSearchRuntime()
        guard let profileLifetime else { return }
        do {
            try await profileLifetime.shutdown()
        } catch {
            DebugLog.store("Per-wiki profile shutdown failed: \(error)")
        }
    }
}

#endif
