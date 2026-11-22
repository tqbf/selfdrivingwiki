#if os(macOS)
import FileProvider
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSFileProvider

/// A store that cannot be read must give a retryable error, not
/// authoritative empty data. Before this, a failed read gave the `"0:0"`
/// token and an empty folder: `enumerateChanges` reported every known item
/// deleted and moved the anchor to `"0:0"`, `enumerateItems` seeded an empty
/// baseline, and `fetchContents` returned `noSuchItem`.
///
/// Phase 6: every read goes through the daemon's projection family over the
/// App Group domain socket, so "the store cannot be read" has two shapes,
/// both exercised here through the REAL socket fixture:
/// - ``Breakage/daemonStopped`` — the daemon is down; the socket file is
///   unlinked and reads fail with the transport-level `daemonNotRunning`.
/// - ``Breakage/wikiNotHosted`` — the daemon is live but the requested wiki
///   is not one it hosts; the daemon answers the typed store-open failure.
///   Unlike a stopped daemon this leaves the GOOD projection working, so the
///   historical good/broken pairing keeps its exact semantics (a broken
///   read never distorts what a working read reports).
///
/// Each test uses the SAME wiki for the good projection and (for the stopped
/// daemon) the broken one, so the enumerator's known-item and anchor caches —
/// keyed by wiki ID — see the state a working read recorded, as a real
/// extension does when a read fails after earlier reads succeeded.
@Suite(.serialized, .timeLimit(.minutes(5)))
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

    /// How the broken projection's data source fails.
    enum Breakage: CaseIterable {
        /// The daemon is down: the socket file is gone (ENOENT on connect).
        case daemonStopped
        /// The daemon is live but does not host the requested wiki: the
        /// daemon-side store resolution fails (the typed open failure).
        case wikiNotHosted
    }

    private struct Seeded {
        let good: Projection
        let broken: Projection
        let fixture: ProjectionSocketFixture
        let store: GRDBWikiStore
        let pages: [WikiPage]

        /// Apply the breakage to the broken projection. Called at the point
        /// in each test where reads start failing (after the good baseline
        /// is recorded where the test needs one).
        func applyBreakage(_ breakage: Breakage) {
            if case .daemonStopped = breakage {
                fixture.simulateDown()
            }
            // .wikiNotHosted needs no action: the broken projection targets
            // a wiki the daemon never hosted, from construction.
        }
    }

    private func seed(_ breakage: Breakage) throws -> Seeded {
        let fixture = try ProjectionSocketFixture.make(displayName: "EnumeratorStoreFailureTests")
        let pages = try ["One", "Two", "Three"].map { try fixture.store.createPage(title: $0) }

        let good = fixture.projection
        let broken: Projection
        switch breakage {
        case .daemonStopped:
            // Same wiki, same daemon — the transport goes away at
            // `applyBreakage` time.
            broken = fixture.projection
        case .wikiNotHosted:
            // Live daemon, but this projection names a wiki it never hosted:
            // every read resolves to the daemon-side store-open failure.
            let client = DaemonProjectionClient(
                wikiID: WikiID(rawValue: "unhosted-\(UUID().uuidString)"),
                containerDirectory: { [fixture] in fixture.container })
            broken = Projection(
                wikiID: client.wikiID, source: client)
        }
        return Seeded(good: good, broken: broken, fixture: fixture,
                      store: fixture.store, pages: pages)
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
        try s.store.createPage(title: "Four")
        s.applyBreakage(breakage)
        let changeObs = MockChangeObserver()
        broken.enumerateChanges(for: changeObs, from: anchor)

        #expect(changeObs.deleted.isEmpty)
        #expect(changeObs.updated.isEmpty)
        #expect(changeObs.finalAnchor == nil)
        try expectRetryable(changeObs.finishedWithError)

        // The baseline survived: once reads work again for the good
        // projection, the change is a plain update with no deletions. Only
        // the unhosted-wiki shape leaves the daemon (and the good
        // projection) alive; a stopped daemon cannot recover mid-test.
        if case .wikiNotHosted = breakage {
            let recovered = MockChangeObserver()
            good.enumerateChanges(for: recovered, from: anchor)
            #expect(recovered.finishedWithError == nil)
            #expect(recovered.deleted.isEmpty)
            #expect(recovered.updated.count == 4)
        }
    }

    // MARK: - enumerateItems

    @Test(arguments: Breakage.allCases)
    func unreadableStoreDoesNotSeedAnEmptyBaseline(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        s.applyBreakage(breakage)
        let broken = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.broken)

        let enumObs = MockEnumerationObserver()
        broken.enumerateItems(for: enumObs, startingAt: Self.firstPage)
        #expect(enumObs.enumerated.isEmpty)
        try expectRetryable(enumObs.finishedWithError)

        // No baseline was seeded, so a later change enumeration expires the
        // anchor and forces a full enumeration. An empty baseline would have
        // let it diff against nothing. The good leg needs a live daemon.
        if case .wikiNotHosted = breakage {
            let good = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.good)
            let anchor = NSFileProviderSyncAnchor(Data(try s.good.checkedChangeToken().utf8))
            try s.store.deletePage(id: s.pages[0].id)
            let changeObs = MockChangeObserver()
            good.enumerateChanges(for: changeObs, from: anchor)
            let error = try #require(changeObs.finishedWithError) as NSError
            #expect(error.code == NSFileProviderError.syncAnchorExpired.rawValue)
        }
    }

    // MARK: - currentSyncAnchor

    @Test(arguments: Breakage.allCases)
    func unreadableStoreNeverReportsAPlaceholderAnchor(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        let broken = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.broken)
        let good = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.good)

        // The good projection records the wiki's real anchor while reads
        // still work (for .daemonStopped this is the LAST chance — the stop
        // below is terminal).
        var goodAnchor: NSFileProviderSyncAnchor?
        good.currentSyncAnchor { goodAnchor = $0 }
        #expect(goodAnchor != nil)

        s.applyBreakage(breakage)

        // A failed read reports that last good anchor (same wiki), never a
        // placeholder such as "0:0". The unhosted-wiki shape targets a
        // DIFFERENT wiki id, so it has no last-anchor entry at all: nil,
        // also never a placeholder.
        var fallback: NSFileProviderSyncAnchor?
        broken.currentSyncAnchor { fallback = $0 }
        if case .daemonStopped = breakage {
            #expect(fallback == goodAnchor)
        } else {
            #expect(fallback == nil)
        }
    }

    /// With no anchor read for the wiki in this process, a failed anchor
    /// read reports nil — the historical first-read shape.
    @Test func daemonDownWithNoPriorAnchorReportsNil() throws {
        let s = try seed(.daemonStopped)
        let broken = WikiFSEnumerator(container: Projection.Identity.pagesByID, projection: s.broken)
        s.applyBreakage(.daemonStopped)

        var first: NSFileProviderSyncAnchor?? = .none
        broken.currentSyncAnchor { first = .some($0) }
        #expect(first == .some(nil))
    }

    // MARK: - fetchContents

    @Test(arguments: Breakage.allCases)
    func unreadableStoreFetchIsRetryableNotNoSuchItem(_ breakage: Breakage) throws {
        let s = try seed(breakage)
        let id = Projection.Identity.pageByID(s.pages[0].id.rawValue)
        s.applyBreakage(breakage)

        guard case .failure(let error) = FileProviderExtension.contentsOutcome(for: id, in: s.broken) else {
            Issue.record("expected a failure from an unreadable store")
            return
        }
        try expectRetryable(error)
    }

    @Test func readableStoreFetchReportsNoSuchItemOnlyForGoneItems() throws {
        let s = try seed(.daemonStopped)
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
        s.applyBreakage(breakage)

        #expect(throws: Projection.StoreUnavailable.self) {
            try s.broken.checkedChildren(of: Projection.Identity.pagesByID)
        }
        #expect(throws: Projection.StoreUnavailable.self) { try s.broken.checkedChangeToken() }
        #expect(throws: Projection.StoreUnavailable.self) { try s.broken.checkedNode(for: id) }

        #expect(s.broken.children(of: Projection.Identity.pagesByID).isEmpty)
        #expect(s.broken.changeToken() == "0:0")
        #expect(s.broken.node(for: id) == nil)

        // A readable store reports a gone item as nil, not as a failure
        // (needs the daemon up — the unhosted-wiki shape).
        if case .wikiNotHosted = breakage {
            #expect(try s.good.checkedNode(
                for: Projection.Identity.pageByID("01ZZZZZZZZZZZZZZZZZZZZZZZZ")) == nil)
        }
    }
}
#endif
