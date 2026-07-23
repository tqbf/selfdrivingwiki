#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import wikid

/// Tests for the daemon's lazy store resolution (#867).
///
/// The queue-engine and chat-host `storeResolver` closures both delegate to
/// `WikiDaemon.resolveStoreLazily(wikiID:)`. Before #867, the resolver only
/// consulted `openStores[wikiID]` and returned `nil` for any wiki the daemon
/// hadn't explicitly opened — so the first ingestion/chat for a wiki failed
/// with "No store for wikiID=…". These tests pin the lazy-open contract:
///
/// 1. An unregistered wikiID resolves to `nil`.
/// 2. A registered wiki whose store isn't cached gets lazily opened (and the
///    opened store actually works — the seeded Home page is readable).
/// 3. The second resolution returns the already-cached instance (no double-open).
struct DaemonStoreResolverTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-store-resolver-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create a registered wiki and return the daemon + its wikiID, with the
    /// store dropped from the cache so the resolver must lazy-open it.
    private func makeDaemonWithUncachedWiki() throws -> (WikiDaemon, String) {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let wikiData = try #require(daemon.createWiki(name: "ResolverTestWiki"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: wikiData)
        // `createWiki` opens + caches the store; drop it so the resolver hits
        // the lazy-open path (registry entry + DB file exist, cache empty).
        daemon.closeStore(wikiID: descriptor.id)
        return (daemon, descriptor.id)
    }

    // MARK: - AC.1 — unknown wikiID resolves to nil

    @Test func resolveStoreLazilyReturnsNilForUnknownWikiID() {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        // Registry is empty → no lazy open possible.
        #expect(daemon.resolveStoreLazily(wikiID: "not-a-registered-wiki") == nil)
    }

    // MARK: - AC.2 — registered wiki is lazily opened and cached

    @Test func resolveStoreLazilyOpensAndCachesStoreForKnownWikiID() async throws {
        let (daemon, wikiID) = try makeDaemonWithUncachedWiki()

        // Lazy-open: the store wasn't cached, but the wiki is registered and
        // its DB file exists on disk → the resolver opens + caches it.
        let store = try #require(daemon.resolveStoreLazily(wikiID: wikiID))

        // It's a real, correctly-opened store: the Home page `createWiki`
        // seeded is readable through it (proves we didn't get a stale/empty
        // handle and the bootstrap data round-tripped through the re-open).
        let pages = try store.listPages(sortBy: .newestFirst)
        #expect(pages.contains { $0.title == "Home" })
    }

    // MARK: - AC.3 — second call returns the already-open store (no double-open)

    @Test func resolveStoreLazilyReturnsCachedStoreOnSecondCall() async throws {
        let (daemon, wikiID) = try makeDaemonWithUncachedWiki()

        let first = try #require(daemon.resolveStoreLazily(wikiID: wikiID))
        let second = try #require(daemon.resolveStoreLazily(wikiID: wikiID))

        // `GRDBWikiStore` is a reference type — identity equality proves the
        // second call served the cached instance rather than re-opening.
        #expect(first === second)
    }
}
#endif
