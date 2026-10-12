#if os(macOS)  // File Provider extension — macOS-only (FileProvider framework)
import FileProvider
import os
import WikiFSTypes

/// Enumerates the children of one container from the SQLite projection, and
/// tracks change via a LIVE sync anchor (Phase 3 — the v0 ship gate).
///
/// Pagination: the children of a container are resolved once into a stable,
/// id-ordered array, then served in fixed-size slices keyed by an integer
/// offset carried in `NSFileProviderPage` (INITIAL §6). root/pages are tiny and
/// fit a single page; by-id/by-title paginate cleanly for large wikis.
///
/// Change signaling (the crux): the sync anchor is the live whole-database
/// change token (`Projection.checkedChangeToken()` — per-table folds plus the
/// v57 change revision, which advances on every write). When the app saves a page it calls `signalEnumerator`; the
/// File Provider then asks `enumerateChanges` from its last anchor. If the token has
/// advanced we re-emit the container's items — now carrying higher
/// `itemVersion`s (`contentVersion = page.version`) — so the File Provider discards its
/// materialized copies and re-fetches fresh bytes. Deletions are reported via
/// `didDeleteItems(_:)` by diffing the last-reported item set against the
/// current one (issue #111). No sleeps: correctness comes from the
/// version-forced re-fetch (INITIAL §10).
final class WikiFSEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    /// The per-wiki projection (bound to this domain's `<ulid>.sqlite`). All
    /// reads — items AND the sync anchor — go through it, so the enumerator
    /// serves exactly the wiki its domain points at (multi-wiki, Phase 0).
    private let projection: Projection
    private let pageSize = 256

    /// The legacy spike/Phase-2 constant anchor. An incoming anchor that equals
    /// this (or is otherwise unparseable) is treated as expired so the File Provider
    /// drops its cache and does a clean full `enumerateItems`.
    private static let legacyAnchor = Data("v2-sqlite".utf8)

    /// Process-wide, lock-guarded record of the item identifiers each
    /// container's enumerator last handed the File Provider — keyed by
    /// wiki + container so two wikis/containers never collide. Lets
    /// `enumerateChanges` diff the previous set against the current one and call
    /// `observer.didDeleteItems(_:)` for identifiers that dropped out.
    ///
    /// Without this, deleted pages/sources linger in the File Provider's materialized
    /// cache forever: `didUpdate(_:)` only refreshes items the File Provider ALREADY
    /// knows about, so a row removed from SQLite has no way to leave the
    /// projection (issue #111). The set is seeded by `enumerateItems` and
    /// refreshed on every `enumerateChanges`. It survives enumerator recreation
    /// within one extension process, but NOT an extension process restart (it is
    /// in-memory only). On restart the File Provider may call `enumerateChanges`
    /// directly with its persisted anchor; `enumerateChanges` detects the missing
    /// baseline and expires the anchor so the framework re-enumerates and re-seeds
    /// the set (#277).
    private final class KnownItemSet: @unchecked Sendable {
        private let lock = NSLock()
        private var sets: [String: Set<NSFileProviderItemIdentifier>] = [:]
        func get(_ key: String) -> Set<NSFileProviderItemIdentifier>? {
            lock.lock(); defer { lock.unlock() }
            return sets[key]
        }
        func set(_ key: String, _ ids: Set<NSFileProviderItemIdentifier>) {
            lock.lock(); defer { lock.unlock() }
            sets[key] = ids
        }
    }
    private static let knownItems = KnownItemSet()

    /// Process-wide record of the last change token each wiki's store
    /// returned. `currentSyncAnchor` falls back to it when the store cannot be
    /// read, instead of reporting a placeholder as a real anchor. An old
    /// anchor is safe: `enumerateChanges` from it re-emits the current items
    /// and diffs against the known-item set, so it can only over-report.
    private static let lastAnchors = OSAllocatedUnfairLock(initialState: [String: Data]())

    /// Unique key for the per-(wiki, container) known-item cache.
    private var cacheKey: String { "\(projection.wikiID)/\(container.rawValue)" }

    init(container: NSFileProviderItemIdentifier, projection: Projection) {
        self.container = container
        self.projection = projection
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let all: [WikiFSItem]
        do {
            all = try currentItems()
        } catch {
            // Unknown, not empty: do not seed an empty baseline (a later
            // `enumerateChanges` would then miss real deletions) and do not
            // report an empty folder. The system retries the enumeration.
            observer.finishEnumeratingWithError(Self.retryableError(error))
            return
        }
        // Seed the File Provider's known-item baseline so a later `enumerateChanges` can
        // diff and report deletions (#111). `all` is always the FULL child set
        // (pagination only slices it for serving), so this is correct on every
        // page, not just the last.
        Self.knownItems.set(cacheKey, Set(all.map(\.itemIdentifier)))
        let start = Self.offset(from: page)
        guard start < all.count else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        let end = min(start + pageSize, all.count)
        observer.didEnumerate(Array(all[start..<end]))
        if end < all.count {
            observer.finishEnumerating(upTo: Self.page(forOffset: end))
        } else {
            observer.finishEnumerating(upTo: nil)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let incoming = anchor.rawValue

        // A legacy/unparseable anchor predates this scheme: expire it so the
        // File Provider discards its cache and re-enumerates from scratch.
        guard incoming != Self.legacyAnchor,
              String(data: incoming, encoding: .utf8) != nil else {
            observer.finishEnumeratingWithError(Self.expiredError)
            return
        }

        // A store that cannot be read says nothing about what changed. Before
        // this check a failed read gave the `"0:0"` token and an empty item
        // list, so every known item was reported deleted and the anchor moved
        // to `"0:0"`. Report a retryable error instead: no deletions, and the
        // system keeps its anchor.
        let current: Data
        do {
            current = try currentSyncAnchorData()
        } catch {
            observer.finishEnumeratingWithError(Self.retryableError(error))
            return
        }

        if incoming == current {
            // Nothing changed since the File Provider's last anchor; advance to current.
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(current), moreComing: false)
            return
        }

        // Something changed: re-emit this container's items. They now carry
        // higher itemVersions (contentVersion derives from the bumped per-page
        // version), so the File Provider invalidates materialized copies and re-fetches.
        // Resolved only after the no-change fast path: building `.workingSet`
        // is the expensive enumeration (#291).
        let items: [WikiFSItem]
        do {
            items = try currentItems()
        } catch {
            observer.finishEnumeratingWithError(Self.retryableError(error))
            return
        }
        let currentIDs = Set(items.map(\.itemIdentifier))

        // Baseline-missing guard (#277): the known-item set is process-static —
        // it does NOT survive an extension process restart. The sync anchor, by
        // contrast, is persisted by the File Provider framework across restarts,
        // so on relaunch the framework can call `enumerateChanges(from: validAnchor)`
        // WITHOUT a prior `enumerateItems`. Diffing against an empty set would
        // silently drop every deletion that landed while the process was down —
        // reintroducing #111 after any routine extension relaunch. Instead, when
        // the baseline is absent we expire the anchor: the framework discards its
        // cache and does a clean full `enumerateItems`, which re-seeds the
        // baseline. The cost is one full re-enumeration per container after a restart.
        guard let known = Self.knownItems.get(cacheKey) else {
            observer.finishEnumeratingWithError(Self.expiredError)
            return
        }

        observer.didUpdate(items)

        // Report deletions: identifiers the File Provider knew about that are no longer
        // present. `didUpdate` only refreshes survivors — without `didDeleteItems`
        // the File Provider has no signal to evict removed rows, so they linger forever
        // (#111). We diff the last-reported set (seeded by `enumerateItems` /
        // the prior `enumerateChanges`) against the current one.
        let deleted = known.subtracting(currentIDs)
        if !deleted.isEmpty {
            observer.didDeleteItems(withIdentifiers: Array(deleted))
        }
        Self.knownItems.set(cacheKey, currentIDs)

        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(current), moreComing: false)
    }

    /// The current anchor. When the store cannot be read, the last anchor
    /// this process read for the wiki, or nil if there is none. Never a
    /// placeholder such as `"0:0"`: the system would store it as a real
    /// position and diff later changes against it.
    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        do {
            completionHandler(NSFileProviderSyncAnchor(try currentSyncAnchorData()))
        } catch {
            DebugLog.fileprovider("currentSyncAnchor \(cacheKey): \(error)")
            let key = projection.wikiID.rawValue
            completionHandler(Self.lastAnchors.withLock { $0[key] }.map { NSFileProviderSyncAnchor($0) })
        }
    }

    // MARK: - Helpers

    /// The current items for this container, freshly resolved from this wiki's
    /// SQLite DB. Throws `Projection.StoreUnavailable` when the store could
    /// not be read.
    private func currentItems() throws -> [WikiFSItem] {
        try projection.checkedChildren(of: container).map { WikiFSItem(node: $0) }
    }

    /// The live anchor bytes: this wiki's whole-database change token. Throws
    /// `Projection.StoreUnavailable` when the store could not be read.
    private func currentSyncAnchorData() throws -> Data {
        let anchor = Data(try projection.checkedChangeToken().utf8)
        let key = projection.wikiID.rawValue
        Self.lastAnchors.withLock { $0[key] = anchor }
        return anchor
    }

    /// The error for a failed store read. See
    /// `Projection.StoreUnavailable.fileProviderError` for why it is a
    /// transient Cocoa error and not `serverUnreachable`.
    private static func retryableError(_ error: Error) -> NSError {
        DebugLog.fileprovider("enumeration failed, system will retry: \(error)")
        if let failure = error as? Projection.StoreUnavailable {
            return failure.fileProviderError
        }
        return Projection.StoreUnavailable(reason: "\(error)").fileProviderError
    }

    private static var expiredError: NSError {
        NSError(domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.syncAnchorExpired.rawValue)
    }

    /// Decode an integer offset from an `NSFileProviderPage`. The initial-page
    /// sentinels decode to 0.
    private static func offset(from page: NSFileProviderPage) -> Int {
        let data = page.rawValue
        if data == NSFileProviderPage.initialPageSortedByName as Data { return 0 }
        if data == NSFileProviderPage.initialPageSortedByDate as Data { return 0 }
        guard let text = String(data: data, encoding: .utf8), let n = Int(text) else { return 0 }
        return n
    }

    private static func page(forOffset offset: Int) -> NSFileProviderPage {
        NSFileProviderPage(Data(String(offset).utf8))
    }
}
#endif  // os(macOS)

