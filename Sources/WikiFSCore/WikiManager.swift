import Foundation
import Observation

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
/// unit-testable without importing `FileProvider` (the same pattern
/// `WikiStoreModel.onPageDidChange` uses to keep `WikiFSCore` UI-free).
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

    /// Invoked after the active store swaps (select / create / migrate). The app
    /// re-wires `onPageDidChange` to the new store's File Provider signaling.
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
    /// run, then open the most-recently-used wiki as the active store. Idempotent:
    /// re-running just reloads + reopens.
    public func bootstrap() {
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
        if let first = registry.mostRecentlyUsed {
            openActive(first.id)
        }
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

    /// Rename a wiki: change ONLY its display name (identity/DB/domain untouched).
    public func renameWiki(id: String, to displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var registry = WikiRegistry.load(from: containerDirectory)
        registry.rename(id: id, to: trimmed)
        try? registry.save(to: containerDirectory)
        wikis = registry.wikis
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
            let store = try makeStore(url)
            model = WikiStoreModel(store: store)
            if model.summaries.isEmpty { model.newPage(title: "Home") }
        } catch {
            print("WikiManager: failed to open wiki \(id), using in-memory: \(error)")
            // swiftlint:disable:next force_try
            let memory = try! SQLiteWikiStore(databaseURL: URL(fileURLWithPath: ":memory:"))
            model = WikiStoreModel(store: memory)
        }
        activeWikiID = id
        activeStore = model
        onActiveStoreDidChange?()
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
            print("WikiManager: createDatabase failed for \(descriptor.id): \(error)")
        }
    }

    /// Wrap a freshly-opened store in a model only when it has no pages, so the
    /// caller seeds a Home exactly once. Returns nil if pages already exist.
    private func makeModelIfEmpty(_ store: WikiStore) -> WikiStoreModel? {
        let model = WikiStoreModel(store: store)
        return model.summaries.isEmpty ? model : nil
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
            print("WikiManager: legacy migration failed: \(error)")
        }
    }
}
