#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFS

/// Tests for `FileProviderFacade`'s projection-drift self-heal
/// (`verifyProjection` / `checkProjectionAndReimportIfPersistentlyDrifted`):
/// compare the mount's `pages/by-id`/`pages/by-title` listing against the DB,
/// and call `reimportItems(below: .rootContainer)` when pages are
/// PERSISTENTLY missing on disk (`fileproviderd` can get individual items
/// permanently stuck — see `ProjectionDriftCheck`'s doc comment).
///
/// These drive `checkProjectionAndReimportIfPersistentlyDrifted` directly with
/// an already-resolved fake root URL, not the public `verifyProjection` entry
/// point — resolving a real mount root needs a live daemon (the same limit
/// `FileProviderFacadeMountPathTests` documents for `resolvePath`). Delays are
/// injected as no-ops and the directory listing is driven by a per-path QUEUE
/// (first call = the initial check, second call = the grace-period recheck),
/// so "drift resolves on recheck" is deterministic rather than a timing race.
@MainActor
struct FileProviderFacadeProjectionDriftTests {

    // swiftlint:disable:next unchecked_sendable
    private final class FakeDomainService: FileProviderDomainService, @unchecked Sendable {
        private let lock = NSLock()
        private var _reimportCount = 0
        var reimportCount: Int { lock.withLock { _reimportCount } }

        func add(id: WikiID, displayName: String) async throws {}
        func remove(id: WikiID, reason: DomainRemovalReason) async throws {}
        func domains() async -> [RegisteredDomain] { [] }
        func reimport(id: WikiID) async throws {
            lock.withLock { _reimportCount += 1 }
        }
    }

    /// A `listDirectory` fake driven by a per-path QUEUE of successive
    /// results: the Nth call to a given path returns the Nth queued array
    /// (the last entry repeats once exhausted), so a test can express "the
    /// first check sees X, the recheck sees Y" without any real waiting.
    // swiftlint:disable:next unchecked_sendable
    private final class DirectoryFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [[String]]]
        private var failingAll = false
        private var _listCount = 0

        init(_ queues: [String: [[String]]]) { self.queues = queues }

        /// Listings served so far. Lets a "no reimport" test prove the check
        /// really compared the fixture instead of skipping early.
        var listCount: Int { lock.withLock { _listCount } }

        func failAllListings() { lock.withLock { failingAll = true } }

        func list(_ url: URL) async -> [String]? {
            lock.withLock {
                _listCount += 1
                if failingAll { return nil }
                guard var queue = queues[url.path] else { return [] }
                guard queue.count > 1 else { return queue.first ?? [] }
                let next = queue.removeFirst()
                queues[url.path] = queue
                return next
            }
        }
    }

    private static let wikiID = WikiID(rawValue: "01HZZZDRIFTONE")
    private static let root = URL(fileURLWithPath: "/tmp/fake-mount-root-for-tests")
    private static let byIDPath = root.appendingPathComponent(IndexGenerators.pagesByIDPath).path
    private static let byTitlePath = root.appendingPathComponent(IndexGenerators.pagesByTitlePath).path

    private static let home = ProjectionDriftCheck.ExpectedPage(
        id: PageID(rawValue: "01AAAAAAAAAAAAAAAAAAAAAAAA"), title: "Home")
    private static let about = ProjectionDriftCheck.ExpectedPage(
        id: PageID(rawValue: "01BBBBBBBBBBBBBBBBBBBBBBBB"), title: "About")

    private static let homeByIDFile = FilenameEscaping.byIDFilename(pageID: home.id.rawValue)
    private static let aboutByIDFile = FilenameEscaping.byIDFilename(pageID: about.id.rawValue)
    private static let homeByTitleFile = FilenameEscaping.byTitleFilename(title: home.title, pageID: home.id.rawValue)
    private static let aboutByTitleFile = FilenameEscaping.byTitleFilename(title: about.title, pageID: about.id.rawValue)

    private func makeFacade(fixture: DirectoryFixture, service: FakeDomainService) -> FileProviderFacade {
        FileProviderFacade(
            domainService: service,
            sleepFor: { _ in },
            listDirectory: { [fixture] url in await fixture.list(url) }
        )
    }

    private func expectedPages() -> [ProjectionDriftCheck.ExpectedPage] { [Self.home, Self.about] }

    // MARK: - No drift

    @Test func noDriftDoesNotReimport() async {
        let fixture = DirectoryFixture([
            Self.byIDPath: [[Self.homeByIDFile, Self.aboutByIDFile]],
            Self.byTitlePath: [[Self.homeByTitleFile, Self.aboutByTitleFile]],
        ])
        let service = FakeDomainService()
        let facade = makeFacade(fixture: fixture, service: service)

        await facade.checkProjectionAndReimportIfPersistentlyDrifted(
            forWikiID: Self.wikiID, displayName: "Test Wiki", root: Self.root, expectedPages: expectedPages)

        #expect(service.reimportCount == 0)
        #expect(fixture.listCount == 2, "one by-id and one by-title listing, no recheck")
    }

    // MARK: - Transient drift

    @Test func transientDriftThatResolvesByRecheckDoesNotReimport() async {
        // First call (the initial check) is missing "About"; the second call
        // (the grace-period recheck) has it — it propagated in the meantime.
        let fixture = DirectoryFixture([
            Self.byIDPath: [[Self.homeByIDFile], [Self.homeByIDFile, Self.aboutByIDFile]],
            Self.byTitlePath: [[Self.homeByTitleFile], [Self.homeByTitleFile, Self.aboutByTitleFile]],
        ])
        let service = FakeDomainService()
        let facade = makeFacade(fixture: fixture, service: service)

        await facade.checkProjectionAndReimportIfPersistentlyDrifted(
            forWikiID: Self.wikiID, displayName: "Test Wiki", root: Self.root, expectedPages: expectedPages)

        #expect(service.reimportCount == 0)
        #expect(fixture.listCount == 4, "initial check plus the grace-period recheck")
    }

    // MARK: - Persistent drift

    @Test func persistentDriftReimportsExactlyOnce() async {
        let fixture = DirectoryFixture([
            Self.byIDPath: [[Self.homeByIDFile]],
            Self.byTitlePath: [[Self.homeByTitleFile]],
        ])
        let service = FakeDomainService()
        let facade = makeFacade(fixture: fixture, service: service)

        await facade.checkProjectionAndReimportIfPersistentlyDrifted(
            forWikiID: Self.wikiID, displayName: "Test Wiki", root: Self.root, expectedPages: expectedPages)

        #expect(service.reimportCount == 1)
    }

    @Test func secondOpenInTheSameLaunchDoesNotReimportAgain() async {
        let fixture = DirectoryFixture([
            Self.byIDPath: [[Self.homeByIDFile]],
            Self.byTitlePath: [[Self.homeByTitleFile]],
        ])
        let service = FakeDomainService()
        let facade = makeFacade(fixture: fixture, service: service)

        await facade.checkProjectionAndReimportIfPersistentlyDrifted(
            forWikiID: Self.wikiID, displayName: "Test Wiki", root: Self.root, expectedPages: expectedPages)
        #expect(service.reimportCount == 1)

        // Simulate the wiki being opened again in the same process — drift is
        // still persistent (the fixture's last queued entry repeats), but the
        // guard must suppress a second reimport.
        await facade.checkProjectionAndReimportIfPersistentlyDrifted(
            forWikiID: Self.wikiID, displayName: "Test Wiki", root: Self.root, expectedPages: expectedPages)

        #expect(service.reimportCount == 1)
    }

    // MARK: - Listing failure

    @Test func listingFailureDoesNotReimport() async {
        let fixture = DirectoryFixture([
            Self.byIDPath: [[Self.homeByIDFile]],
            Self.byTitlePath: [[Self.homeByTitleFile]],
        ])
        fixture.failAllListings()
        let service = FakeDomainService()
        let facade = makeFacade(fixture: fixture, service: service)

        await facade.checkProjectionAndReimportIfPersistentlyDrifted(
            forWikiID: Self.wikiID, displayName: "Test Wiki", root: Self.root, expectedPages: expectedPages)

        #expect(service.reimportCount == 0)
        #expect(fixture.listCount == 2)
    }

    @Test func hungListingTimesOutAndDoesNotReimport() async {
        let service = FakeDomainService()
        let facade = FileProviderFacade(
            domainService: service,
            sleepFor: { _ in },
            listDirectory: { _ in
                // Stands in for a listing blocked on fileproviderd. Returns
                // early only when the timeout cancels it.
                // swiftlint:disable:next silent_try_optional
                try? await Task.sleep(for: .seconds(60))
                return []
            },
            projectionListingTimeout: .milliseconds(50))

        let started = ContinuousClock.now
        await facade.checkProjectionAndReimportIfPersistentlyDrifted(
            forWikiID: Self.wikiID, displayName: "Test Wiki", root: Self.root, expectedPages: expectedPages)

        #expect(service.reimportCount == 0)
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}
#endif
