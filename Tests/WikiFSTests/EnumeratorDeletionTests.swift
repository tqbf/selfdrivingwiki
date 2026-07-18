import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// Tests that `WikiFSEnumerator.enumerateChanges` reports deletions via
/// `didDeleteItems(_:)` (issue #111). Without that call, rows removed from
/// SQLite linger in the File Provider projection forever.
@Suite(.tags(.integration))
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
        let store: GRDBWikiStore
        let sources: [SourceSummary]
    }

    private func seed() throws -> Seeded {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-enum-\(UUID().uuidString).sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
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

    // MARK: - Resource-kind coverage (#277 review point 2)

    @Test func deletingBookmarkRefReportsDidDeleteItems() throws {
        let s = try seed()
        // A page to point the bookmark ref at; the ref is a root-level leaf under
        // the top-level bookmarks container.
        let page = try s.store.createPage(title: "Target Page")
        let ref = try s.store.createBookmarkNode(
            parentID: nil, position: 0, kind: .pageRef, label: nil, targetID: page.id)
        let enumerator = WikiFSEnumerator(container: Projection.Identity.bookmarks,
                                          projection: s.projection)

        let enumObs = MockEnumerationObserver()
        enumerator.enumerateItems(for: enumObs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        #expect(enumObs.enumerated.count == 1)

        let anchor = NSFileProviderSyncAnchor(Data(s.projection.changeToken().utf8))
        let deletedID = Projection.Identity.bookmarkPageRef(ref.id)
        try s.store.deleteBookmarkNode(id: ref.id)

        let changeObs = MockChangeObserver()
        enumerator.enumerateChanges(for: changeObs, from: anchor)

        #expect(changeObs.deleted == [deletedID])
        #expect(changeObs.updated.isEmpty)
        #expect(changeObs.finishedWithError == nil)
    }

    @Test func deletingChatReportsDidDeleteItems() throws {
        let s = try seed()
        let chat = try s.store.createChat(kind: .edit, title: "A Chat")
        let enumerator = WikiFSEnumerator(container: Projection.Identity.chatsByID,
                                          projection: s.projection)

        let enumObs = MockEnumerationObserver()
        enumerator.enumerateItems(for: enumObs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        #expect(enumObs.enumerated.count == 1)

        let anchor = NSFileProviderSyncAnchor(Data(s.projection.changeToken().utf8))
        let deletedID = Projection.Identity.chatByID(chat.id.rawValue)
        try s.store.deleteChat(id: chat.id)

        let changeObs = MockChangeObserver()
        enumerator.enumerateChanges(for: changeObs, from: anchor)

        #expect(changeObs.deleted == [deletedID])
        #expect(changeObs.updated.isEmpty)
        #expect(changeObs.finishedWithError == nil)
    }

    // MARK: - Nested container deletion (#277 review point 3)

    @Test func deletingNestedFolderReportsDidDeleteItems() throws {
        let s = try seed()
        let page = try s.store.createPage(title: "Child Target")
        // A root folder containing one page-ref child.
        let folder = try s.store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder, label: "Folder", targetID: nil)
        _ = try s.store.createBookmarkNode(
            parentID: folder.id, position: 0, kind: .pageRef, label: nil, targetID: page.id)
        let enumerator = WikiFSEnumerator(container: Projection.Identity.bookmarks,
                                          projection: s.projection)

        // The root bookmarks container exposes only root nodes → just the folder.
        let enumObs = MockEnumerationObserver()
        enumerator.enumerateItems(for: enumObs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        #expect(enumObs.enumerated.count == 1)

        let anchor = NSFileProviderSyncAnchor(Data(s.projection.changeToken().utf8))
        let deletedID = Projection.Identity.bookmarkFolder(folder.id)
        try s.store.deleteBookmarkNode(id: folder.id)

        let changeObs = MockChangeObserver()
        enumerator.enumerateChanges(for: changeObs, from: anchor)

        #expect(changeObs.deleted == [deletedID])
        #expect(changeObs.finishedWithError == nil)
    }

    // MARK: - Restart baseline loss (#277 review point 1)

    @Test func missingBaselineAfterRestartExpiresAnchor() throws {
        // Simulates the post-restart state: the File Provider holds a still-valid
        // sync anchor and calls `enumerateChanges` WITHOUT a prior `enumerateItems`
        // in this process, so the in-memory known-item baseline is absent (#277).
        // Each test's projection uses a unique wikiID, so the baseline is nil here
        // exactly as it would be in a freshly-relaunched extension process.
        let s = try seed()
        let enumerator = WikiFSEnumerator(container: Projection.Identity.sourcesByID,
                                          projection: s.projection)

        // No `enumerateItems` — the baseline is never seeded (mirrors a restart).
        let anchor = NSFileProviderSyncAnchor(Data(s.projection.changeToken().utf8))
        try s.store.deleteSource(id: s.sources[0].id)

        let changeObs = MockChangeObserver()
        enumerator.enumerateChanges(for: changeObs, from: anchor)

        // With no baseline to diff against, the enumerator must NOT silently drop
        // the deletion; it expires the anchor so the framework re-enumerates.
        #expect(changeObs.deleted.isEmpty)
        let err = try #require(changeObs.finishedWithError)
        #expect((err as NSError).code == NSFileProviderError.syncAnchorExpired.rawValue)
    }
}
