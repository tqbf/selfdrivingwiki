import Foundation
import Observation
import SQLite3

/// Owns the multi-wiki foundation at the app layer (`plans/llm-wiki.md` Phase 0):
/// the registry of wikis, the currently-active store/model, and the create /
/// select / delete operations. One instance lives at App scope.
///
/// **Identity is the ULID, never the display name** — `WikiDescriptor.dbFileName`
/// and `.domainIdentifier` both derive from `id`, so a rename never orphans the
/// DB or the mount.
///
/// File-Provider side effects are injected as closures (`registerDomain` /
/// `removeDomain`), so this type — and thus the whole switcher logic — is
/// unit-testable without importing `FileProvider` (the same pattern the store's
/// `eventBus` subscribers use to keep `WikiFSCore` UI-free).
@MainActor
@Observable
public final class WikiManager {
    /// The wikis, most-recently-used first (drives the switcher list).
    public private(set) var wikis: [WikiDescriptor] = []

    /// The currently-selected wiki's id, or `nil` before the first wiki exists.
    public private(set) var activeWikiID: String?

    /// The active wiki's editing model — the sidebar/editor bind to THIS. Swapped
    /// wholesale on `select` (a fresh `WikiStoreModel` over the new wiki's DB), so
    /// no per-wiki filtering is needed anywhere downstream.
    public private(set) var activeStore: WikiStoreModel?

    /// Non-nil while the "Vacuum Orphaned Storage…" confirm alert is on screen
    /// (Help menu → `previewBlobVacuum()`). Carries the dry-run report shown in
    /// the alert; cleared on Cancel / Vacuum. Lives on the manager (not the
    /// model) so the app-scene alert has a stable observable across wiki switches.
    public var pendingBlobVacuum: BlobVacuumReport?

    /// Non-nil while the "Vacuum All…" confirm alert is on screen (Help menu →
    /// `previewVacuumAll()`). Carries the combined dry-run report for both blob
    /// and activity orphans; cleared on Cancel / Vacuum.
    public var pendingVacuumAll: VacuumReport?

    /// The App Group container directory holding every `<ulid>.sqlite` and the
    /// `wikis.json` registry. Injected so tests can use a temp dir.
    private let containerDirectory: URL

    /// Build the read-write store for a wiki's DB. Injected so tests can stub it;
    /// the app passes `SQLiteWikiStore(databaseURL:)`.
    private let makeStore: (URL) throws -> WikiStore

    /// File-Provider domain registration side effects, injected from the app
    /// layer (which imports `FileProvider`). Both are async + best-effort.
    /// `registerDomain(id:displayName:)` adds the domain if absent;
    /// `removeDomain(id:)` tears it down on delete.
    @ObservationIgnored public var registerDomain: ((_ id: String, _ displayName: String) async -> Void)?
    @ObservationIgnored public var removeDomain: ((_ id: String) async -> Void)?
    /// Update a wiki domain's user-visible display name. Identity stays the ULID.
    @ObservationIgnored public var renameDomain: ((_ id: String, _ displayName: String) async -> Void)?

    /// Invoked after the active store swaps (select / create / migrate). The app
    /// re-subscribes the File Provider signaler to the new store's `eventBus`.
    @ObservationIgnored public var onActiveStoreDidChange: (() -> Void)?

    public init(
        containerDirectory: URL,
        makeStore: @escaping (URL) throws -> WikiStore = { try SQLiteWikiStore(databaseURL: $0) }
    ) {
        self.containerDirectory = containerDirectory
        self.makeStore = makeStore
    }

    /// This wiki's `<ulid>.sqlite` inside the injected container directory. Built
    /// here (NOT via the global `DatabaseLocation` home-relative path) so the
    /// whole manager is hermetically testable against a temp dir. The extension
    /// resolves the identical filename from `domain.identifier` on its side.
    private func databaseURL(forWikiID id: String) -> URL {
        containerDirectory.appendingPathComponent("\(id).sqlite", isDirectory: false)
    }

    /// Delete a wiki's `<ulid>.sqlite` plus its WAL `-wal`/`-shm` sidecars from
    /// the container directory. Best-effort; a missing sidecar is fine.
    private func deleteDatabaseFiles(forWikiID id: String) {
        let fm = FileManager.default
        let main = databaseURL(forWikiID: id).path
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: main + suffix))
        }
    }

    // MARK: - Launch

    /// Load the registry, migrating the single v0 wiki into it as #1 on first
    /// run, and optionally open the most-recently-used wiki as the active store.
    ///
    /// Pass `activateNow: false` when calling from `App.init()` so that only
    /// `wikis` is set before SwiftUI's first render.  The initial NSTableView
    /// load (reloadData) then runs with data but no selection — avoiding an
    /// NSTableView reentrant-delegate warning (the log says it "will become an
    /// assert in the future") that fires when `activeWikiID` is set in the same
    /// SwiftUI transaction as `wikis`.  Call `activateMostRecent()` from `.task`
    /// to select the wiki after the first render completes (only selectRow, not a
    /// concurrent reloadData).
    public func bootstrap(activateNow: Bool = true) {
        var registry = WikiRegistry.load(from: containerDirectory)
        // The v0 legacy import is strictly first-run-only: it runs ONLY while the
        // registry is still empty. Once any wiki exists, a stray legacy
        // `WikiFS.sqlite` reappearing in the container (e.g. re-copied from
        // Application Support) must NOT spawn a duplicate wiki — see
        // `migrateLegacyWikiIfNeeded`.
        if registry.isEmpty {
            migrateLegacyWikiIfNeeded(into: &registry)
        }
        if registry.isEmpty {
            // Brand-new install with no legacy DB: seed one wiki so the app always
            // has something to show.
            let descriptor = WikiDescriptor.make(displayName: "My Wiki")
            createDatabaseIfNeeded(for: descriptor)
            registry.add(descriptor)
            try? registry.save(to: containerDirectory)
        }
        wikis = registry.wikis
        if activateNow, let first = registry.mostRecentlyUsed {
            openActive(first.id)
        }
    }

    /// Open the most-recently-used wiki as the active store.  Call after
    /// `bootstrap(activateNow: false)` once NSTableView has completed its
    /// initial reloadData — i.e. from `.task` in the app's root view.
    public func activateMostRecent() {
        let registry = WikiRegistry.load(from: containerDirectory)
        if let first = registry.mostRecentlyUsed {
            openActive(first.id)
        }
    }

    // MARK: - Blob GC (#253)

    /// Preview orphaned blob storage for the active wiki (Help menu). Runs a
    /// read-only dry run, then sets `pendingBlobVacuum` so the app-scene confirm
    /// alert appears. No-op when no wiki is active.
    public func previewBlobVacuum() {
        guard let model = activeStore else { return }
        pendingBlobVacuum = model.performBlobVacuum(dryRun: true)
    }

    /// Delete the orphaned blobs (the alert's Vacuum button), then clear the
    /// pending report. Runs against whichever store is active at click time.
    public func applyBlobVacuum() {
        _ = activeStore?.performBlobVacuum(dryRun: false)
        pendingBlobVacuum = nil
    }

    // MARK: - Vacuum All (blobs + activities, #257)

    /// Preview all reclaimable orphans (blobs + activities) for the active wiki
    /// (Help menu). Runs a read-only dry run, then sets `pendingVacuumAll` so
    /// the app-scene confirm alert appears. No-op when no wiki is active.
    public func previewVacuumAll() {
        guard let model = activeStore else { return }
        pendingVacuumAll = model.performVacuumAll(dryRun: true)
    }

    /// Delete all orphaned blobs + activities (the alert's Vacuum button), then
    /// clear the pending report.
    public func applyVacuumAll() {
        _ = activeStore?.performVacuumAll(dryRun: false)
        pendingVacuumAll = nil
    }

    /// Register one File Provider domain per wiki (generalizes the single-domain
    /// add-if-absent). Call after `bootstrap`, once the FP closures are wired.
    public func registerAllDomains() async {
        for wiki in wikis {
            await registerDomain?(wiki.id, wiki.displayName)
        }
    }

    // MARK: - Operations (create / select / rename / delete)

    /// Create a fresh wiki: a new `<ulid>.sqlite` seeded with the default schema
    /// (the existing `bootstrapSchema()` ladder, including the seeded
    /// `system_prompt`), a registry entry, a new File Provider domain, and switch
    /// to it. Returns the new descriptor.
    @discardableResult
    public func createWiki(displayName: String) async -> WikiDescriptor {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = WikiDescriptor.make(displayName: trimmed.isEmpty ? "Untitled Wiki" : trimmed)
        // Opening a fresh SQLiteWikiStore runs the full bootstrap ladder (pages +
        // system_prompt seed). A new wiki should have a Home page so its mount is
        // non-empty, mirroring the app's launch behavior.
        createDatabaseIfNeeded(for: descriptor, seedHome: true)

        var registry = WikiRegistry.load(from: containerDirectory)
        registry.add(descriptor)
        try? registry.save(to: containerDirectory)
        wikis = registry.wikis

        await registerDomain?(descriptor.id, descriptor.displayName)
        select(descriptor.id)
        return descriptor
    }

    /// Switch the active wiki: bump its MRU position and swap `activeStore` to a
    /// fresh model over its DB. No-op if it's already active or unknown.
    public func select(_ id: String) {
        guard descriptorExists(id) else { return }
        guard id != activeWikiID else { return }
        var registry = WikiRegistry.load(from: containerDirectory)
        registry.touch(id: id)
        try? registry.save(to: containerDirectory)
        wikis = registry.wikis
        openActive(id)
    }

    /// Rename a wiki: change ONLY its display name (identity/DB untouched).
    public func renameWiki(id: String, to displayName: String) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var registry = WikiRegistry.load(from: containerDirectory)
        registry.rename(id: id, to: trimmed)
        try? registry.save(to: containerDirectory)
        wikis = registry.wikis
        await renameDomain?(id, trimmed)
    }

    /// Export one wiki as a single SQLite file. A WAL checkpoint runs first so
    /// the copied `.sqlite` contains the latest committed pages, files, prompt,
    /// index, and log without requiring `-wal` / `-shm` sidecars.
    public func exportWiki(id: String, to destinationURL: URL) throws {
        guard descriptorExists(id) else { throw WikiManagerError.unknownWiki(id) }
        if id == activeWikiID { activeStore?.flushPendingSaves() }
        let sourceURL = databaseURL(forWikiID: id)
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw WikiManagerError.exportWouldOverwriteSource
        }
        try checkpointDatabase(at: sourceURL)

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
    }

    /// Import a standalone SQLite wiki file as a new wiki with a new ULID and a
    /// caller-provided display name. The source file is copied, opened once to
    /// validate/migrate it, registered, and selected.
    @discardableResult
    public func importWiki(from sourceURL: URL, displayName: String) async throws -> WikiDescriptor {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WikiManagerError.emptyDisplayName }

        let descriptor = WikiDescriptor.make(displayName: trimmed)
        let destinationURL = databaseURL(forWikiID: descriptor.id)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            _ = try makeStore(destinationURL)
        } catch {
            deleteDatabaseFiles(forWikiID: descriptor.id)
            throw error
        }

        var registry = WikiRegistry.load(from: containerDirectory)
        registry.add(descriptor)
        try registry.save(to: containerDirectory)
        wikis = registry.wikis

        await registerDomain?(descriptor.id, descriptor.displayName)
        select(descriptor.id)
        return descriptor
    }

    /// Delete a wiki: remove its File Provider domain, its registry entry, and its
    /// DB file(s). If it was active, switch to the next most-recently-used wiki
    /// (or clear the active store if it was the last one).
    public func deleteWiki(id: String) async {
        // Flush any pending edits in the active store before tearing down, so we
        // don't write into a DB we're about to delete after the fact.
        if id == activeWikiID { activeStore?.flushPendingSaves() }

        await removeDomain?(id)

        var registry = WikiRegistry.load(from: containerDirectory)
        registry.remove(id: id)
        try? registry.save(to: containerDirectory)
        deleteDatabaseFiles(forWikiID: id)
        wikis = registry.wikis

        if id == activeWikiID {
            if let next = registry.mostRecentlyUsed {
                openActive(next.id)
            } else {
                activeWikiID = nil
                activeStore = nil
                onActiveStoreDidChange?()
            }
        }
    }

    // MARK: - Internals

    private func descriptorExists(_ id: String) -> Bool {
        wikis.contains { $0.id == id }
    }

    /// Open (or reopen) `id` as the active wiki: build a fresh `WikiStoreModel`
    /// over its DB. On store-open failure, fall back to an in-memory store so the
    /// app still functions (matching the app's existing launch fallback).
    private func openActive(_ id: String) {
        let model: WikiStoreModel
        do {
            let url = databaseURL(forWikiID: id)
            // `var`: the bus is set via the protocol's computed setter, which the
            // compiler treats as mutating through the `WikiStore` existential.
            var store = try makeStore(url)
            // Attach the per-wiki event bus BEFORE the model is created, so the
            // model's `.external`→reload subscription (in its init) sees it. The
            // File Provider signaler and the change bridge subscribe to the same
            // bus from the app layer. See `plans/event-bus.md`.
            store.eventBus = WikiEventBus(wikiID: id)
            model = WikiStoreModel(store: store)
            if model.summaries.isEmpty { model.newPage(title: "Home") }
            // Off-main snapshot reads (debounced search) go through a read-only
            // pool over the same file. Only for real file-backed DBs — a second
            // connection to `:memory:` would see a different, empty database.
            if FileManager.default.fileExists(atPath: url.path) {
                model.readPool = WikiReadPool(databaseURL: url)
            }
        } catch {
            DebugLog.store("WikiManager: failed to open wiki \(id), using in-memory: \(error)")
            // swiftlint:disable:next force_try
            let memory = try! SQLiteWikiStore(databaseURL: URL(fileURLWithPath: ":memory:"))
            memory.eventBus = WikiEventBus(wikiID: id)
            model = WikiStoreModel(store: memory)
        }
        activeWikiID = id
        activeStore = model
        onActiveStoreDidChange?()
        // The search-index upgrade is NOT triggered here. It is a one-time,
        // blocking, main-thread-only operation (the sole owner of the store while
        // it runs — see `docs/skills/sqlite-concurrency/SKILL.md`) driven by the
        // app layer via ``WikiManager/upgradeActiveStoreSearchIndex()`` from
        // `scenePhase == .active` and on wiki switch. Running it inline here would
        // race the launch first-render window (an NSTableView reentrant-delegate
        // warning); new content embeds inline at write time, so the upgrade is
        // rarely needed.
    }

    /// Run the blocking search-index upgrade for the active store (a no-op
    /// unless MiniLM is selected AND there is missing content). Safe to call
    /// repeatedly — `upgradeSearchIndex` is single-flight and idempotent. Driven
    /// by the app layer (scenePhase `.active` / wiki switch), never from the
    /// launch `.task`. While it runs a non-dismissible sheet blocks all UX so the
    /// upgrade is the sole owner of the store (no off-main SQLite).
    public func upgradeActiveStoreSearchIndex() async {
        await activeStore?.upgradeSearchIndex()
    }

    /// Create the wiki's DB file if absent by opening it once (which runs the
    /// bootstrap ladder), optionally seeding a Home page.
    private func createDatabaseIfNeeded(for descriptor: WikiDescriptor, seedHome: Bool = false) {
        let url = databaseURL(forWikiID: descriptor.id)
        do {
            let store = try makeStore(url)
            if seedHome, let model = makeModelIfEmpty(store) {
                model.newPage(title: "Home")
            }
        } catch {
            DebugLog.store("WikiManager: createDatabase failed for \(descriptor.id): \(error)")
        }
    }

    /// Wrap a freshly-opened store in a model only when it has no pages, so the
    /// caller seeds a Home exactly once. Returns nil if pages already exist.
    private func makeModelIfEmpty(_ store: WikiStore) -> WikiStoreModel? {
        let model = WikiStoreModel(store: store)
        return model.summaries.isEmpty ? model : nil
    }

    /// Force any committed WAL pages back into the main database file so backup
    /// export can be a single portable `.sqlite` file.
    ///
    /// A TRUNCATE checkpoint blocked by a concurrent reader reports `busy = 1`
    /// in its result ROW while `sqlite3_exec` still returns `SQLITE_OK` — so the
    /// pragma must be stepped as a query and the busy column checked, or a
    /// blocked checkpoint silently exports a `.sqlite` missing the newest
    /// commits (no `-wal` sidecar is copied). Phase 0's `WikiReadPool` made an
    /// in-flight in-process reader possible for the first time (a debounced
    /// search read racing an export); the 5s busy wait comfortably outlasts any
    /// pooled search statement, and if the checkpoint is STILL blocked we fail
    /// the export loudly rather than write a stale backup.
    private func checkpointDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            if let handle { sqlite3_close(handle) }
            throw WikiManagerError.sqlite(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)

        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(handle, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &stmt, nil)
        guard prep == SQLITE_OK, stmt != nil else {
            throw WikiManagerError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WikiManagerError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        // Result row: (busy, wal frames, frames checkpointed).
        guard sqlite3_column_int(stmt, 0) == 0 else {
            throw WikiManagerError.sqlite(
                "wal_checkpoint(TRUNCATE) blocked by a concurrent reader; export aborted to avoid a stale backup")
        }
    }

    // MARK: - v0 migration

    /// Migrate the single pre-multi-wiki `WikiFS.sqlite` into the registry as
    /// wiki #1, preserving all content. The caller (`bootstrap`) invokes this
    /// ONLY while the registry is still empty — that empty-registry gate is the
    /// one-time guard: once any wiki exists, a lingering / re-copied legacy file
    /// can never produce a duplicate. As a belt-and-suspenders local check this
    /// also no-ops unless (a) the legacy file exists AND (b) its ULID target is
    /// absent.
    ///
    /// We RENAME the legacy `WikiFS.sqlite` (and its `-wal`/`-shm` sidecars) to
    /// `<ulid>.sqlite` so the per-wiki path scheme is uniform from then on — the
    /// extension can derive the DB filename from `domain.identifier` with no
    /// special-case for "the legacy one". The content (pages, files,
    /// system_prompt) rides along untouched in the same file.
    private func migrateLegacyWikiIfNeeded(into registry: inout WikiRegistry) {
        let fm = FileManager.default
        let legacy = containerDirectory.appendingPathComponent(
            DatabaseLocation.legacyDatabaseFileName, isDirectory: false)
        guard fm.fileExists(atPath: legacy.path) else { return }

        // Mint the descriptor for the migrated wiki and move the file to its
        // ULID-keyed name. If the move fails, leave everything as-is (the app
        // can retry next launch).
        let descriptor = WikiDescriptor.make(displayName: "Self Driving Wiki")
        let target = databaseURL(forWikiID: descriptor.id)
        guard !fm.fileExists(atPath: target.path) else { return }

        do {
            try fm.moveItem(at: legacy, to: target)
            // Move the WAL sidecars too so no committed-but-uncheckpointed data is
            // stranded. Missing sidecars are fine (already checkpointed).
            for suffix in ["-wal", "-shm"] {
                let from = URL(fileURLWithPath: legacy.path + suffix)
                let to = URL(fileURLWithPath: target.path + suffix)
                if fm.fileExists(atPath: from.path) {
                    try? fm.moveItem(at: from, to: to)
                }
            }
            registry.add(descriptor)
            try? registry.save(to: containerDirectory)
        } catch {
            DebugLog.store("WikiManager: legacy migration failed: \(error)")
        }
    }
}
