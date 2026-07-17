import Foundation
import Testing
@testable import WikiFSCore
@testable import wikid

/// Tests for the `WikiDaemon` — the daemon's in-process registry + store
/// lifecycle logic. These test the daemon directly (not over XPC), using a
/// temp container directory for hermetic isolation. See
/// `plans/multi-wiki-daemon.md` §4.2 + §9 (Phase 1E).
struct WikiDaemonTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDaemon(dir: URL) -> WikiDaemon {
        WikiDaemon(containerDirectory: dir)
    }

    // MARK: - Registry: listWikis

    @Test func listWikisEmptyOnFreshDirectory() {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = daemon.listWikis()
        let wikis = try! JSONDecoder().decode([WikiDescriptor].self, from: data)
        #expect(wikis.isEmpty)
    }

    @Test func listWikisReturnsCreatedWikis() {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Alpha")
        _ = daemon.createWiki(name: "Beta")
        let data = daemon.listWikis()
        let wikis = try! JSONDecoder().decode([WikiDescriptor].self, from: data)
        #expect(wikis.count == 2)
        // MRU: most recently created/used first. Beta was created last.
        #expect(wikis[0].displayName == "Beta")
        #expect(wikis[1].displayName == "Alpha")
    }

    // MARK: - Registry: createWiki

    @Test func createWikiReturnsDescriptor() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "My Wiki"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)
        #expect(descriptor.displayName == "My Wiki")
        #expect(!descriptor.id.isEmpty)
        #expect(descriptor.homePageID != nil)  // Home page is seeded
    }

    @Test func createWikiTrimsWhitespace() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "  Spaced  "))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)
        #expect(descriptor.displayName == "Spaced")
    }

    @Test func createWikiUsesDefaultNameForEmpty() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "   "))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)
        #expect(descriptor.displayName == "Untitled Wiki")
    }

    @Test func createWikiCreatesDBFile() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Test"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)
        let dbURL = dir.appendingPathComponent("\(descriptor.id).sqlite")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
    }

    @Test func createWikiSeedsHomePage() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Test"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)
        #expect(descriptor.homePageID != nil)

        // Verify the Home page actually exists in the DB
        let dbURL = dir.appendingPathComponent("\(descriptor.id).sqlite")
        let store = try SQLiteWikiStore(databaseURL: dbURL)
        let pages = try store.listPages(sortBy: .newestFirst)
        #expect(pages.count == 1)
        #expect(pages[0].title == "Home")
    }

    @Test func createWikiPersistsToRegistry() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "Persisted")
        // Re-load the registry from disk — it should survive
        let registry = WikiRegistry.load(from: dir)
        #expect(registry.wikis.count == 1)
        #expect(registry.wikis[0].displayName == "Persisted")
    }

    // MARK: - Registry: resolveWiki

    @Test func resolveWikiByULID() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let createData = try #require(daemon.createWiki(name: "Find Me"))
        let created = try JSONDecoder().decode(WikiDescriptor.self, from: createData)

        let resolveData = try #require(daemon.resolveWiki(selector: created.id))
        let resolved = try JSONDecoder().decode(WikiDescriptor.self, from: resolveData)
        #expect(resolved.id == created.id)
        #expect(resolved.displayName == "Find Me")
    }

    @Test func resolveWikiByDisplayName() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        _ = daemon.createWiki(name: "By Name")

        let resolveData = try #require(daemon.resolveWiki(selector: "By Name"))
        let resolved = try JSONDecoder().decode(WikiDescriptor.self, from: resolveData)
        #expect(resolved.displayName == "By Name")
    }

    @Test func resolveWikiReturnsNilForUnknown() {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        #expect(daemon.resolveWiki(selector: "nonexistent") == nil)
    }

    @Test func resolveWikiULIDTakesPrecedenceOverDisplayName() throws {
        // If a wiki's displayName happens to match another wiki's ULID,
        // the ULID lookup should win (mirrors WikiResolver behavior).
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let createData = try #require(daemon.createWiki(name: "Alpha"))
        let alpha = try JSONDecoder().decode(WikiDescriptor.self, from: createData)
        _ = daemon.createWiki(name: "Beta")
        // Resolve by Alpha's ULID — should get Alpha, not Beta
        let resolveData = try #require(daemon.resolveWiki(selector: alpha.id))
        let resolved = try JSONDecoder().decode(WikiDescriptor.self, from: resolveData)
        #expect(resolved.id == alpha.id)
    }

    // MARK: - Registry: deleteWiki

    @Test func deleteWikiRemovesFromRegistry() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Delete Me"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        let success = daemon.deleteWiki(id: descriptor.id)
        #expect(success)

        let registry = WikiRegistry.load(from: dir)
        #expect(registry.wikis.isEmpty)
    }

    @Test func deleteWikiRemovesDBFiles() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Delete Me"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)
        let dbURL = dir.appendingPathComponent("\(descriptor.id).sqlite")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        _ = daemon.deleteWiki(id: descriptor.id)
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-shm"))
    }

    // MARK: - Registry: renameWiki

    @Test func renameWikiChangesDisplayNameOnly() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Old Name"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        let success = daemon.renameWiki(id: descriptor.id, name: "New Name")
        #expect(success)

        let resolveData = try #require(daemon.resolveWiki(selector: descriptor.id))
        let resolved = try JSONDecoder().decode(WikiDescriptor.self, from: resolveData)
        #expect(resolved.displayName == "New Name")
        #expect(resolved.id == descriptor.id)  // Identity unchanged
    }

    @Test func renameWikiRejectsEmptyName() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Test"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        let success = daemon.renameWiki(id: descriptor.id, name: "   ")
        #expect(!success)
    }

    @Test func renameWikiReturnsFalseForUnknownID() {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let success = daemon.renameWiki(id: "nonexistent", name: "Whatever")
        #expect(!success)
    }

    // MARK: - Store lifecycle: openStore

    @Test func openStoreReturnsTrueForExistingWiki() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Open Me"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        let success = daemon.openStore(wikiID: descriptor.id)
        #expect(success)
    }

    @Test func openStoreReturnsFalseForUnknownWiki() {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let success = daemon.openStore(wikiID: "nonexistent")
        #expect(!success)
    }

    @Test func openStoreIsIdempotent() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Test"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        #expect(daemon.openStore(wikiID: descriptor.id))
        #expect(daemon.openStore(wikiID: descriptor.id))  // Second open is a no-op
    }

    // MARK: - Store lifecycle: closeStore

    @Test func closeStoreDoesNotCrash() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Close Me"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        _ = daemon.openStore(wikiID: descriptor.id)
        daemon.closeStore(wikiID: descriptor.id)  // Should not crash

        // Reopening should work after close
        #expect(daemon.openStore(wikiID: descriptor.id))
    }

    // MARK: - Store lifecycle: changeToken

    @Test func changeTokenReturnsNonEmptyForOpenStore() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Token Test"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        _ = daemon.openStore(wikiID: descriptor.id)
        let token = daemon.changeToken(wikiID: descriptor.id)
        #expect(!token.isEmpty)
    }

    @Test func changeTokenReturnsEmptyForUnknownWiki() {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let token = daemon.changeToken(wikiID: "nonexistent")
        #expect(token.isEmpty)
    }

    /// When the store's `changeToken()` (or its transient open) throws, the
    /// daemon must NOT swallow the error as `""` ("no changes" → stale File
    /// Provider projection, #487). It must log and return a sentinel the caller
    /// can distinguish from a genuine token — and that never matches a cached
    /// anchor, so the enumerator re-syncs.
    @Test func changeTokenReturnsSentinelOnStoreError() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let data = try #require(daemon.createWiki(name: "Corrupt Test"))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: data)

        // Force the transient-open path (store not held in `openStores`)
        daemon.closeStore(wikiID: descriptor.id)

        // Corrupt the DB so SQLiteWikiStore(databaseURL:) throws (SQLITE_NOTADB)
        let dbURL = dir.appendingPathComponent("\(descriptor.id).sqlite", isDirectory: false)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
        }
        try Data("not a sqlite database".utf8).write(to: dbURL)

        let token = daemon.changeToken(wikiID: descriptor.id)
        #expect(token == WikiDaemon.errorTokenSentinel)
        // Sentinel is distinguishable from both a genuine token (colon-joined
        // integers) and from `""` (unknown wiki).
        #expect(!token.isEmpty)
        #expect(!token.contains(":"))
    }

    // MARK: - Multiple wikis

    @Test func multipleWikisAreIndependent() throws {
        let dir = tempDirectory()
        let daemon = makeDaemon(dir: dir)
        let aData = try #require(daemon.createWiki(name: "Wiki A"))
        let bData = try #require(daemon.createWiki(name: "Wiki B"))
        let a = try JSONDecoder().decode(WikiDescriptor.self, from: aData)
        let b = try JSONDecoder().decode(WikiDescriptor.self, from: bData)

        #expect(a.id != b.id)

        // Both stores can be open simultaneously
        #expect(daemon.openStore(wikiID: a.id))
        #expect(daemon.openStore(wikiID: b.id))

        // Change tokens are independent
        let tokenA = daemon.changeToken(wikiID: a.id)
        let tokenB = daemon.changeToken(wikiID: b.id)
        // They could technically be equal on fresh wikis, but both should be non-empty
        #expect(!tokenA.isEmpty)
        #expect(!tokenB.isEmpty)

        // Deleting A doesn't affect B
        _ = daemon.deleteWiki(id: a.id)
        #expect(daemon.openStore(wikiID: b.id))
    }
}
