import Foundation
import Observation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif

/// App-scoped, observable client for the multi-wiki registry
/// (`plans/llm-wiki.md` Phase 0; reshaped by the manager dissolution
/// — `plans/dissolve-wikimanager.md`; multi-window Phase 2b
/// — `plans/multi-window-ui.md`). This type carries ONLY the wiki
/// registry list, the active-wiki id (MRU launch + Option+click in-window
/// switch), and the create / select / rename / delete / export / import
/// operations. The per-wiki "active store" model + its launchers/vacuum
/// state live on the engine-layer ``WikiSession``, managed by
/// ``SessionManager`` which the app layer creates/destroys per-window in
/// `RootScene`.
///
/// **Identity is the ULID, never the display name** — `WikiDescriptor.dbFileName`
/// and `.domainIdentifier` both derive from `id`, so a rename never orphans the
/// DB or the mount.
///
/// File-Provider side effects are injected as closures (`registerDomain` /
/// `removeDomain` / `renameDomain` / `flushActiveStore`), so this type — and
/// thus the whole switcher logic — is unit-testable without importing
/// `FileProvider` (the same pattern the store's `eventBus` subscribers use to
/// keep `WikiFSCore` UI-free).
@MainActor
@Observable
public final class WikiRegistryClient {
    /// The wikis, most-recently-used first (drives the switcher list).
    public private(set) var wikis: [WikiDescriptor] = []

    /// The currently-selected wiki's id, or `nil` before the first wiki
    /// exists. Setting this (via ``select(_:)`` / ``activateMostRecent()``
    /// / ``deleteWiki(id:)``) is what drives session creation / destruction
    /// in the app layer's `.onChange(of: activeWikiID)` handler. The
    /// registry never opens a store itself — the per-wiki ``WikiSession``
    /// is constructed in the app layer.
    public private(set) var activeWikiID: WikiID?

    /// The App Group container directory holding every `<ulid>.sqlite` and the
    /// `wikis.json` registry. Injected so tests can use a temp dir.
    private let containerDirectory: URL

    /// Build the read-write store for a wiki's DB. Injected so tests can stub
    /// it; the app passes `GRDBWikiStore(databaseURL:)`. Used by
    /// `createDatabaseIfNeeded` / `importWiki` — store *opening* (the heavier
    /// path that also attaches the event bus + creates the model) is
    /// delegated to ``WikiSession``.
    private let makeStore: (URL) throws -> WikiStore

    /// The registry's access mode, handed down by the app composition from the
    /// launch-fixed `StoreModeConfiguration.resolvedMode` (default `.local` =
    /// today's behavior — the client itself never reads the environment).
    /// Remote mode makes this client a READ CACHE: `wikis.json` and the DB
    /// files are daemon-owned.
    @ObservationIgnored private let accessMode: WikiRegistryAccessMode

    /// The daemon lifecycle invoker for remote mode (`createWiki` /
    /// `renameWiki` / `deleteWiki`). `nil` in local mode (unused) and — in
    /// remote mode — a composition failure every mediated op surfaces as the
    /// typed ``WikiRegistryError/daemonInvokerUnavailable``; it NEVER falls
    /// back to a local write.
    @ObservationIgnored private let daemonInvoker: (any WikiRegistryDaemonInvoker)?

    /// Whether lifecycle ops mediate through the daemon and every local
    /// registry/DB write is unreachable.
    private var mediatingDaemon: Bool { accessMode == .remote }

    // MARK: - Injected side effects (kept `@ObservationIgnored` like the FP
    // closures below, so observing a `WikiRegistryClient` never re-renders
    // when a side-effect closure is reassigned).

    /// File-Provider domain registration side effects, injected from the app
    /// layer (which imports `FileProvider`). Both are async + best-effort.
    /// `registerDomain(id:displayName:)` adds the domain if absent;
    /// `removeDomain(id:)` tears it down on delete.
    @ObservationIgnored public var registerDomain: ((_ id: WikiID, _ displayName: String) async -> Void)?
    @ObservationIgnored public var removeDomain: ((_ id: WikiID) async -> Void)?
    /// Update a wiki domain's user-visible display name. Identity stays the ULID.
    @ObservationIgnored public var renameDomain: ((_ id: WikiID, _ displayName: String) async -> Void)?

    /// Flush any pending autosaves in the named wiki's model before the
    /// registry deletes its DB (``deleteWiki(id:)``) or runs a WAL checkpoint
    /// (``exportWiki(id:to:)``). The app injects this closure to delegate to
    /// `SessionManager.flushSession(for:)` for whichever wiki is being
    /// exported/deleted — the registry client itself never holds a store, so
    /// it cannot flush directly. Safe to leave `nil` in tests that never
    /// invoke those paths against an active wiki.
    @ObservationIgnored public var flushActiveStore: ((_ wikiID: WikiID) async -> Void)?

    // MARK: - Init

    public init(
        containerDirectory: URL,
        makeStore: @escaping (URL) throws -> WikiStore = { try StoreBackend.current.makeStore(databaseURL: $0) },
        accessMode: WikiRegistryAccessMode = .local,
        daemonInvoker: (any WikiRegistryDaemonInvoker)? = nil
    ) {
        self.containerDirectory = containerDirectory
        self.makeStore = makeStore
        self.accessMode = accessMode
        self.daemonInvoker = daemonInvoker
    }

    /// This wiki's `<ulid>.sqlite` inside the injected container directory.
    /// Built here (NOT via the global `DatabaseLocation` home-relative path) so
    /// the whole client is hermetically testable against a temp dir. The
    /// extension resolves the identical filename from `domain.identifier` on
    /// its side.
    private func databaseURL(forWikiID id: WikiID) -> URL {
        containerDirectory.appendingPathComponent("\(id.rawValue).sqlite", isDirectory: false)
    }

    /// Delete a wiki's `<ulid>.sqlite` plus its WAL `-wal`/`-shm` sidecars from
    /// the container directory. Best-effort; a missing sidecar is fine.
    private func deleteDatabaseFiles(forWikiID id: WikiID) {
        let fm = FileManager.default
        let main = databaseURL(forWikiID: id).path
        for suffix in ["", "-wal", "-shm"] {
            DebugLog.trying("clearStaleRegistry", operation: { try fm.removeItem(at: URL(fileURLWithPath: main + suffix)) })
        }
    }

    /// Persist the registry to `wikis.json`. LOCAL MODE ONLY: in remote mode
    /// the file is daemon-owned and this path is UNREACHABLE by contract —
    /// the assertion fires on a miswire (debug builds) and the write never
    /// happens (no silent local write ever shadows the daemon's file).
    /// `label` keeps each call site's historical `DebugLog.trying` tag.
    private func persistRegistry(_ registry: WikiRegistry, label: String = "registry.save") {
        if mediatingDaemon {
            assertionFailure(
                "WikiRegistryClient: reached a wikis.json write path in remote mode — the file is daemon-owned")
            DebugLog.store(
                "WikiRegistryClient: refused a local wikis.json write in remote mode (daemon-owned)")
            return
        }
        DebugLog.trying(label, operation: { try registry.save(to: containerDirectory) })
    }

    // MARK: - Launch

    /// Load the registry, migrating the single v0 wiki into it as #1 on first
    /// run, and optionally mark the most-recently-used wiki as active.
    ///
    /// Pass `activateNow: false` when calling from `App.init()` so that only
    /// `wikis` is set before SwiftUI's first render. The initial NSTableView
    /// load (reloadData) then runs with data but no selection — avoiding an
    /// NSTableView reentrant-delegate warning (the log says it "will become an
    /// assert in the future") that fires when `activeWikiID` is set in the same
    /// SwiftUI transaction as `wikis`.  Call `activateMostRecent()` from `.task`
    /// to select the wiki after the first render completes (only selectRow, not
    /// a concurrent reloadData).
    ///
    /// With `activateNow: true`, sets ``activeWikiID`` to the MRU wiki. The
    /// app's `.onChange(of: activeWikiID)` is what actually kicks off
    /// ``WikiSession`` construction (the previous `openActive`
    /// path); this client never opens a store.
    public func bootstrap(activateNow: Bool = true) {
        var registry = WikiRegistry.load(from: containerDirectory)
        // The v0 legacy import is strictly first-run-only: it runs ONLY while
        // the registry is still empty. Once any wiki exists, a stray legacy
        // `WikiFS.sqlite` reappearing in the container (e.g. re-copied from
        // Application Support) must NOT spawn a duplicate wiki — see
        // `migrateLegacyWikiIfNeeded`.
        //
        // Remote mode: the DAEMON owns the legacy import (it runs once at
        // daemon start under the daemon's serialization — the daemon-side
        // `DaemonLegacyWikiImporter` port of this very logic). This branch is
        // a deliberate no-op here; the daemon's registry event (or the next
        // reload) surfaces the imported wiki in the cache.
        if registry.isEmpty, !mediatingDaemon {
            migrateLegacyWikiIfNeeded(into: &registry)
        }
        if registry.isEmpty {
            // Brand-new install with no legacy DB: seed one wiki so the app
            // always has something to show. Plan P1.3: the store open + Home
            // seed is async now — spawn it; the DB is created lazily on first
            // open regardless, and the registry row lands synchronously.
            let descriptor = WikiDescriptor.make(displayName: "My Wiki")
            if mediatingDaemon {
                // First-run seed through the daemon: the DB file is the
                // daemon's, the registry row is the daemon's write, and the
                // cache picks the wiki up from the reply + the registry
                // event. With no invoker injected this logs the typed error
                // and seeds nothing — it must never seed locally.
                let client = self
                Task { _ = await client.createWikiThroughDaemon(displayName: descriptor.displayName) }
            } else {
                let client = self
                Task { await client.createDatabaseIfNeeded(for: descriptor) }
                registry.add(descriptor)
                persistRegistry(registry, label: "migrateSingleWiki")
            }
        }
        wikis = registry.wikis
        if activateNow, let first = registry.mostRecentlyUsed {
            activeWikiID = first.id
        }
    }

    /// Mark the most-recently-used wiki as active. Call after
    /// `bootstrap(activateNow: false)` once NSTableView has completed its
    /// initial reloadData — i.e. from `.task` in the app's root view.
    public func activateMostRecent() {
        let registry = WikiRegistry.load(from: containerDirectory)
        if let first = registry.mostRecentlyUsed {
            activeWikiID = first.id
        }
    }

    /// Re-read `wikis.json` from disk and publish any change to ``wikis``.
    ///
    /// The app is not the only writer of the registry: `wikictl wiki create`
    /// and the `wikid` daemon both add wikis by writing the file directly. The
    /// change bridge calls this when it receives a wiki-change wake so that a
    /// wiki created while the app is running becomes visible here (#1374) —
    /// previously the bridge's per-wiki Darwin subscription was refreshed only
    /// from `.onChange(of: registry.wikis)`, which could not fire for a wiki
    /// this client had never learned about.
    ///
    /// Assigns only when the on-disk set actually differs, so a wake storm does
    /// not churn `@Observable` observers (and thus SwiftUI) with no-op writes.
    /// Returns whether ``wikis`` changed.
    ///
    /// Reads through ``WikiRegistry/loadStrictly(from:)``, NOT the lenient
    /// ``WikiRegistry/load(from:)``: the lenient loader degrades a corrupt file
    /// to an EMPTY registry, and assigning that here would drop every wiki from
    /// the live list over a partial write. On a read failure this KEEPS the
    /// in-memory list and returns `false` — the same call the daemon makes in
    /// `WikiDaemon.readDiskRegistry()`, where treating corruption as mass
    /// deletion destroys state. A missing file is still a valid empty registry
    /// (fresh install), so first-run behavior is unchanged.
    @discardableResult
    public func reloadFromDisk() -> Bool {
        let onDisk: [WikiDescriptor]
        do {
            onDisk = try WikiRegistry.loadStrictly(from: containerDirectory).wikis
        } catch {
            DebugLog.store(
                "WikiRegistryClient: registry unreadable, keeping \(wikis.count) wiki(s): \(error)")
            return false
        }
        guard onDisk != wikis else { return false }
        wikis = onDisk
        DebugLog.store(
            "WikiRegistryClient: reloaded registry from disk — \(onDisk.count) wiki(s)")
        return true
    }

    /// Register one File Provider domain per wiki (generalizes the
    /// single-domain add-if-absent). Call after `bootstrap`, once the FP
    /// closures are wired.
    public func registerAllDomains() async {
        for wiki in wikis {
            await registerDomain?(wiki.id, wiki.displayName)
        }
    }

    // MARK: - Operations (create / select / rename / delete / home page)

    /// Create a fresh wiki: a new `<ulid>.sqlite` seeded with the default
    /// schema (the existing `bootstrapSchema()` ladder, including the seeded
    /// `system_prompt`) plus a `Home` page, a registry entry, a new File
    /// Provider domain, and switch to it. Returns the new descriptor.
    ///
    /// Remote mode: the op routes through the daemon's XPC create (the ULID,
    /// the seeded DB, and the registry row are the daemon's); `nil` means the
    /// wiki was NOT created (typed error logged — never a local write). Local
    /// mode: exactly the pre-mediation behavior, always non-nil.
    @discardableResult
    public func createWiki(displayName: String) async -> WikiDescriptor? {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if mediatingDaemon {
            return await createWikiThroughDaemon(displayName: trimmed)
        }
        var descriptor = WikiDescriptor.make(displayName: trimmed.isEmpty ? "Untitled Wiki" : trimmed)
        // Opening a fresh GRDBWikiStore runs the full bootstrap ladder (pages +
        // system_prompt seed). A new wiki should have a Home page so its mount
        // is non-empty, mirroring the app's launch behavior. The seeded page
        // becomes the wiki's home page so the home button works without a
        // manual "Set as Home Page" step (#315).
        descriptor.homePageID = await createDatabaseIfNeeded(for: descriptor, seedHome: true)

        var registry = WikiRegistry.load(from: containerDirectory)
        registry.add(descriptor)
        persistRegistry(registry)
        wikis = registry.wikis

        await registerDomain?(descriptor.id, descriptor.displayName)
        select(descriptor.id)
        return descriptor
    }

    /// The mediated ops' cache refresh: adopt the daemon's `wikis.json` write
    /// when the file is readable, but do NOT adopt a MISSING file as "empty" —
    /// the daemon's authoritative reply already proves the row exists and its
    /// file write may still be in flight (the registry event's reload lands
    /// the file version). Note `loadStrictly` returns a VALID EMPTY registry
    /// for a missing file (it only throws on corruption), so the existence
    /// check must be explicit. Corruption keeps the cache, same as
    /// ``reloadFromDisk()``.
    @discardableResult
    private func refreshCacheFromDaemonFile() -> Bool {
        let url = containerDirectory.appendingPathComponent(
            WikiRegistry.fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        let onDisk: WikiRegistry
        do {
            onDisk = try WikiRegistry.loadStrictly(from: containerDirectory)
        } catch {
            DebugLog.store(
                "WikiRegistryClient: registry unreadable, keeping \(wikis.count) wiki(s): \(error)")
            return false
        }
        guard onDisk.wikis != wikis else { return false }
        wikis = onDisk.wikis
        return true
    }

    /// The remote-mode create: the daemon mints everything (ULID, seeded DB
    /// with a Home page, registry row) and pushes a registry event; this
    /// client merges the authoritative reply into its cache and re-reads the
    /// daemon's file write. Every failure is a typed error logged here and NO
    /// local write — remote mode has no local fallback.
    private func createWikiThroughDaemon(displayName: String) async -> WikiDescriptor? {
        guard let invoker = daemonInvoker else {
            DebugLog.store(
                "WikiRegistryClient: createWiki in remote mode failed — \(WikiRegistryError.daemonInvokerUnavailable)")
            return nil
        }
        let name = trimmedOrUntitled(displayName)
        do {
            let descriptor = try await invoker.createWiki(name: name)
            // Adopt the daemon's file write first (it may already be on
            // disk), then merge the authoritative reply — the reply must
            // survive a refresh that ran before the daemon's file landed (the
            // registry event's later reload re-adopts the same row).
            refreshCacheFromDaemonFile()
            mergeIntoCache(descriptor)
            await registerDomain?(descriptor.id, descriptor.displayName)
            select(descriptor.id)
            return descriptor
        } catch {
            DebugLog.store("WikiRegistryClient: daemon createWiki failed: \(error)")
            return nil
        }
    }

    /// `WikiDescriptor.make`'s empty-name guard, shared by the local and the
    /// mediated create paths (the daemon applies the same fallback).
    private func trimmedOrUntitled(_ displayName: String) -> String {
        displayName.isEmpty ? "Untitled Wiki" : displayName
    }

    /// Insert (or refresh) one descriptor at the cache front — the MRU
    /// position — from an authoritative daemon reply. In-memory only; the
    /// daemon's own `wikis.json` write stays the durable source.
    private func mergeIntoCache(_ descriptor: WikiDescriptor) {
        wikis.removeAll { $0.id == descriptor.id }
        wikis.insert(descriptor, at: 0)
    }

    /// Switch the active wiki: bump its MRU position and set ``activeWikiID``.
    /// No-op if it's already active or unknown. Setting ``activeWikiID`` is
    /// observed by the app layer, which constructs the matching
    /// ``WikiSession`` (this client never opens a store itself).
    ///
    /// Remote mode: the in-memory selection still happens (it drives the app's
    /// session construction), but the MRU bump is NOT persisted — there is no
    /// daemon op for a touch in this slice and `wikis.json` is daemon-owned.
    /// The concession is logged; MRU ordering refreshes from the daemon's
    /// file on the next registry event / reload.
    public func select(_ id: WikiID) {
        guard descriptorExists(id) else { return }
        guard id != activeWikiID else { return }
        if mediatingDaemon {
            DebugLog.store(
                "WikiRegistryClient: select in remote mode sets the active wiki in memory only (daemon-owned MRU ordering)")
            activeWikiID = id
            return
        }
        var registry = WikiRegistry.load(from: containerDirectory)
        registry.touch(id: id)
        persistRegistry(registry)
        wikis = registry.wikis
        activeWikiID = id
    }

    /// Rename a wiki: change ONLY its display name (identity/DB untouched).
    ///
    /// Remote mode: the rename routes through the daemon's XPC op; the cache
    /// refreshes from the daemon's reply + its registry event, and NO local
    /// write happens (typed errors logged, cache unchanged on failure).
    public func renameWiki(id: WikiID, to displayName: String) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mediatingDaemon {
            guard let invoker = daemonInvoker else {
                DebugLog.store(
                    "WikiRegistryClient: renameWiki in remote mode failed — \(WikiRegistryError.daemonInvokerUnavailable)")
                return
            }
            do {
                let renamed = try await invoker.renameWiki(id: id, to: trimmed)
                guard renamed else {
                    DebugLog.store(
                        "WikiRegistryClient: renameWiki in remote mode failed — \(WikiRegistryError.daemonOperationFailed("rename"))")
                    return
                }
                // Refresh first (adopt the daemon's file write if it landed),
                // then apply the authoritative reply name — a refresh that
                // ran before the daemon's file landed must not revert or wipe
                // the rename.
                refreshCacheFromDaemonFile()
                mergeIntoCacheNamed(id: id, displayName: trimmed)
                await renameDomain?(id, trimmed)
            } catch {
                DebugLog.store("WikiRegistryClient: daemon renameWiki failed: \(error)")
            }
            return
        }
        var registry = WikiRegistry.load(from: containerDirectory)
        registry.rename(id: id, to: trimmed)
        persistRegistry(registry)
        wikis = registry.wikis
        await renameDomain?(id, trimmed)
    }

    /// Apply a daemon-authoritative rename to the cache (in-memory; the
    /// daemon's `wikis.json` write is the durable source). No-op for an id
    /// the cache doesn't hold.
    private func mergeIntoCacheNamed(id: WikiID, displayName: String) {
        guard let index = wikis.firstIndex(where: { $0.id == id }) else { return }
        wikis[index].displayName = displayName
    }

    /// Set (or clear, with `nil`) a wiki's home page — the page its home
    /// button navigates to.
    ///
    /// Remote mode: no daemon op carries the home-page pointer in this slice,
    /// so this is a CACHE-ONLY update (never a local `wikis.json` write).
    /// It is logged, and the next registry event / reload restores the
    /// daemon's durable value.
    public func setHomePage(id: WikiID, pageID: PageID?) {
        guard descriptorExists(id) else { return }
        if mediatingDaemon {
            DebugLog.store(
                "WikiRegistryClient: setHomePage in remote mode updates the cache only (daemon-owned registry; no home-page op yet)")
            if let index = wikis.firstIndex(where: { $0.id == id }) {
                wikis[index].homePageID = pageID
            }
            return
        }
        var registry = WikiRegistry.load(from: containerDirectory)
        registry.setHomePage(id: id, pageID: pageID)
        persistRegistry(registry)
        wikis = registry.wikis
    }

    /// Export one wiki as a single SQLite file. A WAL checkpoint runs first so
    /// the copied `.sqlite` contains the latest committed pages, files, prompt,
    /// index, and log without requiring `-wal` / `-shm` sidecars. If the wiki
    /// is active, flushes pending autosaves first via the injected
    /// ``flushActiveStore`` closure (this client does not own the store).
    ///
    /// Remote mode: THROWS ``WikiRegistryError/daemonOwnedSurface`` before
    /// touching anything — the DB file is the daemon's, and a client-side
    /// checkpoint would open it directly (the daemon gains an export op in a
    /// later slice).
    public func exportWiki(id: WikiID, to destinationURL: URL) throws {
        if mediatingDaemon {
            throw WikiRegistryError.daemonOwnedSurface("export")
        }
        guard descriptorExists(id) else { throw WikiRegistryError.unknownWiki(id) }
        Task { await flushActiveStore?(id) }
        let sourceURL = databaseURL(forWikiID: id)
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            throw WikiRegistryError.exportWouldOverwriteSource
        }
        try checkpointDatabase(at: sourceURL)

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
    }

    /// Import a standalone SQLite wiki file as a new wiki with a new ULID and
    /// a caller-provided display name. The source file is copied, opened once
    /// to validate / migrate it, registered, and selected.
    ///
    /// Remote mode: THROWS ``WikiRegistryError/daemonOwnedSurface`` — the
    /// client must not copy a DB into the daemon's container or write the
    /// daemon's `wikis.json` (the daemon gains an import op in a later
    /// slice).
    @discardableResult
    public func importWiki(from sourceURL: URL, displayName: String) async throws -> WikiDescriptor {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WikiRegistryError.emptyDisplayName }
        if mediatingDaemon {
            throw WikiRegistryError.daemonOwnedSurface("import")
        }

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

    /// Delete a wiki: remove its File Provider domain, its registry entry, and
    /// its DB file(s). If it was active, flush its pending saves first (via the
    /// injected ``flushActiveStore`` closure), then switch to the next
    /// most-recently-used wiki (or clear ``activeWikiID`` if it was the last
    /// one). The app layer's `.onChange(of: activeWikiID)` tears down the old
    /// session and stands up the new one — this client never holds a session.
    ///
    /// Remote mode: the daemon owns the registry row AND the DB files; the op
    /// routes through the daemon's XPC delete. The client-side File Provider
    /// domain teardown (a projection concern, not registry ownership) still
    /// runs, and the cache refreshes from the daemon's reply + registry event.
    /// Failures are typed errors logged here — no local write, no local cache
    /// removal for a wiki the daemon refused to delete.
    public func deleteWiki(id: WikiID) async {
        // Flush any pending edits in the wiki being deleted, so we don't
        // strand writes in a DB we're about to delete. The closure resolves
        // to the live session's store at the app layer; nil-safe. In remote
        // mode the session's store is the daemon-backed client, so the flush
        // still lands daemon-side before the daemon removes the file.
        Task { await flushActiveStore?(id) }

        if mediatingDaemon {
            guard let invoker = daemonInvoker else {
                DebugLog.store(
                    "WikiRegistryClient: deleteWiki in remote mode failed — \(WikiRegistryError.daemonInvokerUnavailable)")
                return
            }
            do {
                let deleted = try await invoker.deleteWiki(id: id)
                guard deleted else {
                    DebugLog.store(
                        "WikiRegistryClient: deleteWiki in remote mode failed — \(WikiRegistryError.daemonOperationFailed("delete"))")
                    return
                }
            } catch {
                DebugLog.store("WikiRegistryClient: daemon deleteWiki failed: \(error)")
                return
            }
            await removeDomain?(id)
            // Drop the deleted wiki from the cache and adopt the daemon's
            // file write (the registry event's reload is idempotent).
            wikis.removeAll { $0.id == id }
            reloadFromDisk()
            if id == activeWikiID {
                if let next = wikis.first {
                    select(next.id)
                } else {
                    activeWikiID = nil
                }
            }
            return
        }

        await removeDomain?(id)

        var registry = WikiRegistry.load(from: containerDirectory)
        registry.remove(id: id)
        persistRegistry(registry)
        deleteDatabaseFiles(forWikiID: id)
        wikis = registry.wikis

        if id == activeWikiID {
            if let next = registry.mostRecentlyUsed {
                select(next.id)
            } else {
                activeWikiID = nil
            }
        }
    }

    // MARK: - Internals

    private func descriptorExists(_ id: WikiID) -> Bool {
        wikis.contains { $0.id == id }
    }

    /// Create the wiki's DB file if absent by opening it once (which runs the
    /// bootstrap ladder), optionally seeding a Home page.
    /// Returns the seeded Home page's ID (when `seedHome` seeds one), so the
    /// caller can wire it into `WikiDescriptor.homePageID`.
    @discardableResult
    private func createDatabaseIfNeeded(for descriptor: WikiDescriptor, seedHome: Bool = false) async -> PageID? {
        let url = databaseURL(forWikiID: descriptor.id)
        do {
            let store = try makeStore(url)
            if seedHome, let model = await makeModelIfEmpty(store) {
                return await model.newPage(title: "Home")
            }
        } catch {
            DebugLog.store("WikiRegistryClient: createDatabase failed for \(descriptor.id.rawValue): \(error)")
        }
        return nil
    }

    /// Wrap a freshly-opened store in a model only when it has no pages, so
    /// the caller seeds a Home exactly once. Returns nil if pages already
    /// exist.
    private func makeModelIfEmpty(_ store: WikiStore) async -> WikiStoreModel? {
        let model = WikiStoreModel(store: store)
        // Plan P1.3: construction performs no store work — bootstrap the
        // projections before the emptiness check means anything.
        await model.bootstrapFromStore()
        return model.summaries.isEmpty ? model : nil
    }

    /// Force any committed WAL pages back into the main database file so backup
    /// export can be a single portable `.sqlite` file.
    ///
    /// A TRUNCATE checkpoint blocked by a concurrent reader reports
    /// `busy = 1` in its result ROW while `sqlite3_exec` still returns
    /// `SQLITE_OK` — so the pragma must be stepped as a query and the busy
    /// column checked, or a blocked checkpoint silently exports a `.sqlite`
    /// missing the newest commits (no `-wal` sidecar is copied). Phase 0's
    /// `WikiReadService` made an in-flight in-process reader possible for the
    /// first time (a debounced search read racing an export); the 5s busy
    /// wait comfortably outlasts any pooled search statement, and if the
    /// checkpoint is STILL blocked we fail the export loudly rather than
    /// write a stale backup.
    private func checkpointDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            if let handle { sqlite3_close(handle) }
            throw WikiRegistryError.sqlite(message)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)

        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(handle, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &stmt, nil)
        guard prep == SQLITE_OK, stmt != nil else {
            throw WikiRegistryError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WikiRegistryError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        // Result row: (busy, wal frames, frames checkpointed).
        guard sqlite3_column_int(stmt, 0) == 0 else {
            throw WikiRegistryError.sqlite(
                "wal_checkpoint(TRUNCATE) blocked by a concurrent reader; export aborted to avoid a stale backup")
        }
    }

    // MARK: - v0 migration

    /// Migrate the single pre-multi-wiki `WikiFS.sqlite` into the registry as
    /// wiki #1, preserving all content. The caller (`bootstrap`) invokes this
    /// ONLY while the registry is still empty — that empty-registry gate is
    /// the one-time guard: once any wiki exists, a lingering / re-copied
    /// legacy file can never produce a duplicate. As a belt-and-suspenders
    /// local check this also no-ops unless (a) the legacy file exists AND (b)
    /// its ULID target is absent.
    ///
    /// We RENAME the legacy `WikiFS.sqlite` (and its `-wal`/`-shm` sidecars)
    /// to `<ulid>.sqlite` so the per-wiki path scheme is uniform from then on
    /// — the extension can derive the DB filename from `domain.identifier`
    /// with no special-case for "the legacy one". The content (pages, files,
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
            // Move the WAL sidecars too so no committed-but-uncheckpointed data
            // is stranded. Missing sidecars are fine (already checkpointed).
            for suffix in ["-wal", "-shm"] {
                let from = URL(fileURLWithPath: legacy.path + suffix)
                let to = URL(fileURLWithPath: target.path + suffix)
                if fm.fileExists(atPath: from.path) {
                    DebugLog.trying("importLegacyWiki move sidecar", operation: { try fm.moveItem(at: from, to: to) })
                }
            }
            registry.add(descriptor)
            DebugLog.trying("importLegacyWiki save", operation: { try registry.save(to: containerDirectory) })
        } catch {
            DebugLog.store("WikiRegistryClient: legacy migration failed: \(error)")
        }
    }
}

// MARK: - Daemon mediation (Phase 3 slice 2, plans/daemon-only-access.md 3.2)

/// The registry's access mode, handed down by the caller from the app's
/// launch-fixed store-mode resolution (`StoreModeConfiguration.resolvedMode`
/// in WikiCtlCore → its `StoreAccessMode` value domain). WikiFSCore sits
/// BELOW WikiFSEngine in the module graph, so the mode crosses this boundary
/// as this mirrored enum — the client never reads the environment itself
/// (the same hand-down convention `StoreAccessMode` documents).
public enum WikiRegistryAccessMode: String, Sendable {
    /// This process owns `wikis.json` and the DB files (today's local dev
    /// behavior, and the DEBUG `allowLocalStore` override). Every write path
    /// stays exactly as it was.
    case local
    /// The daemon owns `wikis.json` and the DB files. This client is a READ
    /// CACHE: lifecycle ops route to the daemon's XPC ops through the
    /// injected ``WikiRegistryDaemonInvoker``, the file is only ever read,
    /// and refreshes come from daemon registry events + ``reloadFromDisk()``.
    case remote
}

/// The daemon-mediated registry lifecycle operations the client routes to in
/// `remote` mode (the daemon's existing XPC wiki family — `WikiDaemonProtocol`
/// create/rename/delete). Injected so tests and the fixture daemon harness
/// can stub it; the WikiCtlCore adapter conforms it over
/// ``WikiDaemonConnection``.
///
/// Throwing is the failure contract: a typed error from here is logged at the
/// op site and NO local write happens — in remote mode there is no local
/// fallback.
public protocol WikiRegistryDaemonInvoker: Sendable {
    /// Create a wiki daemon-side (registry row + seeded DB + Home page).
    /// Returns the authoritative descriptor (the daemon minted the ULID).
    func createWiki(name: String) async throws -> WikiDescriptor
    /// Rename a wiki's display name daemon-side. `false` = the daemon refused
    /// (unknown id, empty name, unreadable registry).
    func renameWiki(id: WikiID, to name: String) async throws -> Bool
    /// Delete a wiki daemon-side (registry row + DB files). `false` = refused.
    func deleteWiki(id: WikiID) async throws -> Bool
}

/// Errors raised by ``WikiRegistryClient``'s export / import paths and the
/// WAL checkpoint that precedes export. Renamed from the original
/// `WikiManagerError` as part of the manager dissolution
/// (`plans/dissolve-wikimanager.md`).
public enum WikiRegistryError: Error, Equatable, CustomStringConvertible {
    case emptyDisplayName
    case exportWouldOverwriteSource
    case sqlite(String)
    case unknownWiki(WikiID)
    /// Remote mode with no ``WikiRegistryDaemonInvoker`` injected: the
    /// lifecycle op cannot be mediated. NEVER falls back to a local write —
    /// the caller (app composition) failed to wire the daemon connection.
    case daemonInvokerUnavailable
    /// The daemon refused or failed the mediated op (returned `false` or
    /// threw). The payload describes the op for diagnostics.
    case daemonOperationFailed(String)
    /// A surface that stays daemon-owned in remote mode was reached client-
    /// side (export/import/legacy-import in this slice). The client must not
    /// open or copy the daemon's DB files; the daemon gains these ops in a
    /// later slice.
    case daemonOwnedSurface(String)

    public var description: String {
        switch self {
        case .emptyDisplayName:
            return "Wiki name cannot be empty."
        case .exportWouldOverwriteSource:
            return "Choose a backup location outside the wiki's backing database file."
        case .sqlite(let message):
            return "SQLite checkpoint failed: \(message)"
        case .unknownWiki(let id):
            return "No wiki exists with id \(id.rawValue)."
        case .daemonInvokerUnavailable:
            return "Wiki lifecycle needs the daemon connection (remote mode) — none was injected."
        case .daemonOperationFailed(let op):
            return "The daemon refused the wiki \(op) operation."
        case .daemonOwnedSurface(let surface):
            return "Wiki \(surface) is owned by the daemon in remote mode."
        }
    }
}
