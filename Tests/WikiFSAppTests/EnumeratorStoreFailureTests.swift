#if os(macOS)
import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// A store that cannot be opened or read must give a retryable error, not
/// authoritative empty data. Before this, a failed read gave the `"0:0"`
/// token and an empty folder: `enumerateChanges` reported every known item
/// deleted and moved the anchor to `"0:0"`, `enumerateItems` seeded an empty
/// baseline, and `fetchContents` returned `noSuchItem`.
///
/// Each test uses two projections with the SAME wiki ID: a readable one, and
/// one whose database URL is missing or not a SQLite file. The enumerator's
/// known-item and anchor caches are keyed by wiki ID, so the broken
/// projection sees the state the readable one recorded, as a real extension
/// does when a read fails after earlier reads succeeded.
struct EnumeratorStoreFailureTests {

    // MARK: - Mock observers

    private final class MockEnumerationObserver: NSObject, NSFileProviderEnumerationObserver {
        var enumerated: [NSFileProviderItem] = []
        var finishedWithError: Error?

        func didEnumerate(_ updatedItems: [NSFileProviderItem]) { enumerated += updatedItems }
        func finishEnumerating(upTo page: NSFileProviderPage?) {}
        func finishEnumeratingWithError(_ error: Error) { finishedWithError = error }
    }

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

    /// How the broken projection's database fails.
    enum Breakage: CaseIterable {
        /// No file at the URL: the store cannot be opened.
        case missing
        /// A file that is not a SQLite database: open or the first read fails.
        case corrupt
    }

    private struct Seeded {
        let good: Projection
        let broken: Projection
        let store: GRDBWikiStore
        let pages: [WikiPage]
    }

    private func seed(_ breakage: Breakage) throws -> Seeded {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("wikifs-fail-\(UUID().uuidString).sqlite")
        let store = try GRDBWikiStore(databaseURL: url)
        let pages = try ["One", "Two", "Three"].map { try store.createPage(title: $0) }

        let brokenURL = dir.appendingPathComponent("wikifs-broken-\(UUID().uuidString).sqlite")
        if breakage == .corrupt {
            try Data(repeating: 0x41, count: 8192).write(to: brokenURL)
        }
        let wikiID = WikiID(rawValue: "fail-\(UUID().uuidString)")
        return Seeded(good: Projection(wikiID: wikiID, databaseURL: url),
                      broken: Projection(wikiID: wikiID, databaseURL: brokenURL),
                      store: store, pages: pages)
    }

    private static let firstPage = NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data)

    private func expectRetryable(_ error: Error?) throws {
        let error = try #require(error) as NSError
        #expect(error.domain == NSCocoaErrorDomain)
        #expect(error.code == NSFileReadUnknownError)
    }

    // MARK: - enumerateChanges

    @Test(arguments: Breakage.allCases)
    func unreadableStoreReportsNoDeletionsAndKeepsAnchor(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        let good = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.good)
        let broken = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.broken)

        // Seed the known-item baseline with the three pages.
        let enumObs = MockEnumerationObserver()
        good.enumerateItems(for: enumObs, startingAt: Self.firstPage)
        #expect(enumObs.enumerated.count == 3)

        // A change arrives; the store cannot be read when the system asks.
        let anchor = NSFileProviderSyncAnchor(Data(try s.good.checkedChangeToken().utf8))
        _ = try s.store.createPage(title: "Four")
        let changeObs = MockChangeObserver()
        broken.enumerateChanges(for: changeObs, from: anchor)

        #expect(changeObs.deleted.isEmpty)
        #expect(changeObs.updated.isEmpty)
        #expect(changeObs.finalAnchor == nil)
        try expectRetryable(changeObs.finishedWithError)

        // The baseline survived: once the store is readable again, the
        // change is a plain update with no deletions.
        let recovered = MockChangeObserver()
        good.enumerateChanges(for: recovered, from: anchor)
        #expect(recovered.finishedWithError == nil)
        #expect(recovered.deleted.isEmpty)
        #expect(recovered.updated.count == 4)
    }

    // MARK: - enumerateItems

    @Test(arguments: Breakage.allCases)
    func unreadableStoreDoesNotSeedAnEmptyBaseline(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        let broken = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.broken)

        let enumObs = MockEnumerationObserver()
        broken.enumerateItems(for: enumObs, startingAt: Self.firstPage)
        #expect(enumObs.enumerated.isEmpty)
        try expectRetryable(enumObs.finishedWithError)

        // No baseline was seeded, so a later change enumeration expires the
        // anchor and forces a full enumeration. An empty baseline would have
        // let it diff against nothing.
        let good = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.good)
        let anchor = NSFileProviderSyncAnchor(Data(try s.good.checkedChangeToken().utf8))
        try s.store.deletePage(id: s.pages[0].id)
        let changeObs = MockChangeObserver()
        good.enumerateChanges(for: changeObs, from: anchor)
        let error = try #require(changeObs.finishedWithError) as NSError
        #expect(error.code == NSFileProviderError.syncAnchorExpired.rawValue)
    }

    // MARK: - currentSyncAnchor

    @Test(arguments: Breakage.allCases)
    func unreadableStoreNeverReportsAPlaceholderAnchor(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        let broken = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.broken)
        let good = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.good)

        // No anchor read yet in this process: nil, not "0:0".
        var first: NSFileProviderSyncAnchor?? = .none
        broken.currentSyncAnchor { first = .some($0) }
        #expect(first == .some(nil))

        // After a good read, a failed read reports that last good anchor.
        var goodAnchor: NSFileProviderSyncAnchor?
        good.currentSyncAnchor { goodAnchor = $0 }
        var fallback: NSFileProviderSyncAnchor?
        broken.currentSyncAnchor { fallback = $0 }
        #expect(goodAnchor != nil)
        #expect(fallback == goodAnchor)
    }

    // MARK: - fetchContents

    @Test(arguments: Breakage.allCases)
    func unreadableStoreFetchIsRetryableNotNoSuchItem(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        let id = Projection.Identity.pageByID(s.pages[0].id.rawValue)

        guard case .failure(let error) = FileProviderExtension.contentsOutcome(for: id, in: s.broken) else {
            Issue.record("expected a failure from an unreadable store")
            return
        }
        try expectRetryable(error)
    }

    @Test func readableStoreFetchReportsNoSuchItemOnlyForGoneItems() throws {
        let s = try seed(.missing)
        let kept = Projection.Identity.pageByID(s.pages[0].id.rawValue)
        let gone = Projection.Identity.pageByID(s.pages[1].id.rawValue)
        try s.store.deletePage(id: s.pages[1].id)

        guard case .success(let (data, node)) = FileProviderExtension.contentsOutcome(for: kept, in: s.good) else {
            Issue.record("expected content for an existing page")
            return
        }
        #expect(!data.isEmpty)
        #expect(node.id == kept)

        guard case .failure(let error) = FileProviderExtension.contentsOutcome(for: gone, in: s.good) else {
            Issue.record("expected noSuchItem for a deleted page")
            return
        }
        #expect(error.domain == NSFileProviderErrorDomain)
        #expect(error.code == NSFileProviderError.noSuchItem.rawValue)
    }

    // MARK: - Projection

    /// The checked reads throw; the existing non-throwing reads keep their
    /// historical degrade-to-empty behavior for their other callers.
    @Test(arguments: Breakage.allCases)
    func checkedReadsThrowAndUncheckedReadsDegrade(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        let id = Projection.Identity.pageByID(s.pages[0].id.rawValue)

        #expect(throws: Projection.StoreUnavailable.self) {
            try s.broken.checkedChildren(of: Projection.Identity.pagesByID)
        }
        #expect(throws: Projection.StoreUnavailable.self) { try s.broken.checkedChangeToken() }
        #expect(throws: Projection.StoreUnavailable.self) { try s.broken.checkedNode(for: id) }

        #expect(s.broken.children(of: Projection.Identity.pagesByID).isEmpty)
        #expect(s.broken.changeToken() == "0:0")
        #expect(s.broken.node(for: id) == nil)

        // A readable store reports a gone item as nil, not as a failure.
        #expect(try s.good.checkedNode(for: Projection.Identity.pageByID("01ZZZZZZZZZZZZZZZZZZZZZZZZ")) == nil)
    }
}
#endif
