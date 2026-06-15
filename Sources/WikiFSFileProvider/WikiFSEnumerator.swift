import FileProvider

/// Enumerates the children of one container from the SQLite projection, and
/// tracks change via a LIVE sync anchor (Phase 3 — the v0 ship gate).
///
/// Pagination: the children of a container are resolved once into a stable,
/// id-ordered array, then served in fixed-size slices keyed by an integer
/// offset carried in `NSFileProviderPage` (INITIAL §6). root/pages are tiny and
/// fit a single page; by-id/by-title paginate cleanly for large wikis.
///
/// Change signaling (the crux): the sync anchor is the live whole-database
/// change token (`Projection.changeToken()` — count:sum over pages, advancing
/// on ANY edit). When the app saves a page it calls `signalEnumerator`; the
/// daemon then asks `enumerateChanges` from its last anchor. If the token has
/// advanced we re-emit the container's page items — now carrying higher
/// `itemVersion`s (`contentVersion = page.version`) — so the daemon discards its
/// materialized copies and re-fetches fresh bytes. No sleeps: correctness comes
/// from the version-forced re-fetch (INITIAL §10).
final class WikiFSEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    /// The per-wiki projection (bound to this domain's `<ulid>.sqlite`). All
    /// reads — items AND the sync anchor — go through it, so the enumerator
    /// serves exactly the wiki its domain points at (multi-wiki, Phase 0).
    private let projection: Projection
    private let pageSize = 256

    /// The legacy spike/Phase-2 constant anchor. An incoming anchor that equals
    /// this (or is otherwise unparseable) is treated as expired so the daemon
    /// drops its cache and does a clean full `enumerateItems`.
    private static let legacyAnchor = Data("v2-sqlite".utf8)

    init(container: NSFileProviderItemIdentifier, projection: Projection) {
        self.container = container
        self.projection = projection
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let all = currentItems()
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
        let current = currentSyncAnchorData()
        let incoming = anchor.rawValue

        // A legacy/unparseable anchor predates this scheme: expire it so the
        // daemon discards its cache and re-enumerates from scratch.
        guard incoming != Self.legacyAnchor,
              String(data: incoming, encoding: .utf8) != nil else {
            observer.finishEnumeratingWithError(Self.expiredError)
            return
        }

        if incoming == current {
            // Nothing changed since the daemon's last anchor; advance to current.
            observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(current), moreComing: false)
            return
        }

        // Something changed: re-emit this container's page items. They now carry
        // higher itemVersions (contentVersion derives from the bumped per-page
        // version), so the daemon invalidates materialized copies and re-fetches.
        // NOTE: deletion semantics (didDeleteItems) are a known v0 gap.
        observer.didUpdate(currentItems())
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(current), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(currentSyncAnchorData()))
    }

    // MARK: - Helpers

    /// The current items for this container, freshly resolved from this wiki's
    /// SQLite DB.
    private func currentItems() -> [WikiFSItem] {
        projection.children(of: container).map { WikiFSItem(node: $0) }
    }

    /// The live anchor bytes: this wiki's whole-database change token (count:sum).
    private func currentSyncAnchorData() -> Data {
        Data(projection.changeToken().utf8)
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
