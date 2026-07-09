import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// Tests that `WikiFSEnumerator.enumerateChanges` reports deletions via
/// `didDeleteItems(_:)` (issue #111). Without that call, rows removed from
/// SQLite linger in the File Provider projection forever.
struct EnumeratorDeletionTests {

    // MARK: - Mock observers

    /// Captures everything a `WikiFSEnumerator` reports to the File Provider during an
    /// enumeration pass. Mirrors the real `NSFileProviderEnumerationObserver`
    /// surface the enumerator drives.
    private final class MockEnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
        var enumerated: [NSFileProviderItem] = []
        var lastPage: NSFileProviderPage?
        var finishedWithError: Error?

        func didEnumerate(_ updatedItems: [NSFileProviderItem]) { enumerated += updatedItems }
        func finishEnumerating(upTo page: NSFileProviderPage?) { lastPage = page }
        func finishEnumeratingWithError(_ error: Error) { finishedWithError = error }
    }

    /// Captures `didUpdate` / `didDeleteItems` / anchor-finish calls so a test can
    /// assert exactly which identifiers the enumerator told the File Provider to evict.
    private final class MockChangeObserver: NSObject, NSFileProviderChangeObserver {
        var updated: [NSFileProviderItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        var finalAnchor: NSFileProviderSyncAnchor?
        var finishedWithError: Error?

        func didUpdate(_ updatedItems: [NSFileProviderItem]) { updated += updatedItems }
        func didDeleteItems(withIdentifiers deletedItemIdentifiers: [NSFileProviderItemIdentifier]) {
            deleted += deletedItemIdentifiers
        }
        func finishEnumeratingChanges(upTo anchor: NSFileProviderSyncAnchor, moreComing: Bool) {
            finalAnchor = anchor
        }
        func finishEnumeratingWithError(_ error: Error) { finishedWithError = error }
    }

    // MARK: - Seed

    /// A projection backed by a temp DB with three sources (text, no `.md`
    /// siblings). The enumerator under test drives `sources/by-id`.
    private struct Seeded {
        let projection: Projection
        let store: SQLiteWikiStore
        let sources: [SourceSummary]
    }

    private func seed() throws -> Seeded {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-enum-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let s1 = try store.addSource(filename: "a.txt", data: Data("aaa".utf8), mimeType: "text/plain")
        let s2 = try store.addSource(filename: "b.txt", data: Data("bbb".utf8), mimeType: "text/plain")
        let s3 = try store.addSource(filename: "c.txt", data: Data("ccc".utf8), mimeType: "text/plain")
        let projection = Projection(wikiID: "enum-\(UUID().uuidString)", databaseURL: url)
        return Seeded(projection: projection, store: store, sources: [s1, s2, s3])
    }

    // MARK: - Tests

    @Test func deletingSourceReportsDidDeleteItems() throws {
        let s = try seed()
        let enumerator = WikiFSEnumerator(container: Projection.Identity.sourcesByID,
                                          projection: s.projection)

        // 1. Full enumeration — seeds the File Provider's known-item baseline.
        let enumObs = MockEnumerationObserver()
        enumerator.enumerateItems(for: enumObs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        let knownIDs = Set(enumObs.enumerated.map { $0.itemIdentifier })
        #expect(knownIDs.count == 3)

        // 2. Capture the anchor the File Provider would store.
        let anchor = NSFileProviderSyncAnchor(Data(s.projection.changeToken().utf8))

        // 3. Delete one source from the DB (advances the change token).
        let deletedID = Projection.Identity.sourceByID(s.sources[1].id.rawValue)
        try s.store.deleteSource(id: s.sources[1].id)

        // 4. The File Provider asks for changes from its last anchor.
        let changeObs = MockChangeObserver()
        enumerator.enumerateChanges(for: changeObs, from: anchor)

        // 5. The dropped identifier must be reported via didDeleteItems.
        #expect(changeObs.deleted.contains(deletedID))
        // Survivors come through didUpdate; the deleted one must NOT.
        let updatedIDs = Set(changeObs.updated.map { $0.itemIdentifier })
        #expect(!updatedIDs.contains(deletedID))
        #expect(updatedIDs.count == 2)
        #expect(changeObs.finishedWithError == nil)
    }

    @Test func noDeletionReportsNoDidDeleteItems() throws {
        let s = try seed()
        let enumerator = WikiFSEnumerator(container: Projection.Identity.sourcesByID,
                                          projection: s.projection)

        let enumObs = MockEnumerationObserver()
        enumerator.enumerateItems(for: enumObs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        #expect(enumObs.enumerated.count == 3)

        // An anchor from a state BEFORE these sources existed forces a token
        // difference but with nothing deleted → no didDeleteItems call.
        let staleAnchor = NSFileProviderSyncAnchor(Data("0:0".utf8))

        let changeObs = MockChangeObserver()
        enumerator.enumerateChanges(for: changeObs, from: staleAnchor)

        #expect(changeObs.deleted.isEmpty)
        // All three survive → all three reported via didUpdate.
        #expect(changeObs.updated.count == 3)
    }

    @Test func deletingPageReportsDidDeleteItems() throws {
        let s = try seed()
        let page = try s.store.createPage(title: "The Page")
        let enumerator = WikiFSEnumerator(container: Projection.Identity.pagesByID,
                                          projection: s.projection)

        let enumObs = MockEnumerationObserver()
        enumerator.enumerateItems(for: enumObs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        #expect(enumObs.enumerated.count == 1)

        let anchor = NSFileProviderSyncAnchor(Data(s.projection.changeToken().utf8))
        let deletedID = Projection.Identity.pageByID(page.id.rawValue)
        try s.store.deletePage(id: page.id)

        let changeObs = MockChangeObserver()
        enumerator.enumerateChanges(for: changeObs, from: anchor)

        #expect(changeObs.deleted == [deletedID])
        #expect(changeObs.updated.isEmpty)
        #expect(changeObs.finishedWithError == nil)
    }
}
