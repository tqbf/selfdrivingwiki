#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
@testable import WikiFSCore
@testable import wikid

/// Regression tests for the daemon-owned search backend (`DaemonSearchRuntime`
/// + `WikiDaemon.searchData`): cold-start dedup onto one runtime per wiki,
/// page/source/chat kind coverage through the wire, catch-up when an external
/// writer commits to the SQLite file behind the daemon's back, and lifecycle
/// release on close.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct DaemonSearchTests {

    // MARK: - Fixture

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Best-effort fixture teardown: removing the temp dir is cleanup, not a
    /// load-bearing step, so a silent failure here is acceptable.
    private func removeTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDaemon(
        directory: URL,
        wikiID: WikiID
    ) async throws -> WikiDaemon {
        var registry = WikiRegistry()
        registry.add(WikiDescriptor(
            id: wikiID,
            displayName: "search-test",
            createdAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: Date(timeIntervalSince1970: 1)))
        try registry.save(to: directory)
        let daemon = WikiDaemon(containerDirectory: directory)
        try await daemon.prepareWiki(wikiID)
        return daemon
    }

    /// The fixture store is the daemon's admitted store (bus wired); the
    /// external-writer test opens a SECOND store on the same file, whose
    /// writes are invisible to the daemon's bus — exactly the app's
    /// out-of-process write shape.
    private func fixtureStoreURL(directory: URL, wikiID: WikiID) -> URL {
        directory.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
    }

    @discardableResult
    private func seedPage(
        _ store: GRDBWikiStore,
        title: String,
        body: String
    ) throws -> WikiPage {
        try store.createPage(title: title, body: body)
    }

    private func seedAllKinds(_ store: GRDBWikiStore) throws {
        _ = try store.createPage(
            title: "ZebraQuantum Notes",
            body: "Project notes about the ZebraQuantum fusion program.")
        _ = try store.addSource(filename: "zebraquantum-report.pdf", data: Data("<pdf/>".utf8))
        let chat = try store.createChat(kind: .edit, title: "ZebraQuantum chat")
        _ = try store.appendChatMessages(
            chatID: chat.id,
            events: [.userText("Summarize the ZebraQuantum fusion program.")])
    }

    private func runSearch(
        _ daemon: WikiDaemon,
        wikiID: WikiID,
        operation: SearchRPCOperation
    ) async throws -> SearchRPCReply {
        let request = SearchRPCRequest(wikiID: wikiID.rawValue, operation: operation)
        let replyData = await daemon.searchData(request: try SearchRPCWire.encode(request))
        return try JSONDecoder().decode(SearchRPCReply.self, from: replyData)
    }

    // MARK: - Wire contract

    @Test func wireRoundTripPreservesOperations() async throws {
        let search = SearchRPCRequest(wikiID: "wiki-1", operation: .search(
            query: "hello", kinds: ["page"], limit: 20))
        let autocomplete = SearchRPCRequest(wikiID: "wiki-2", operation: .autocomplete(
            partial: "hel", kinds: nil, distance: 2, limit: 8))
        for request in [search, autocomplete] {
            let decoded = try SearchRPCWire.decode(try SearchRPCWire.encode(request))
            #expect(decoded == request)
            #expect(decoded.version == SearchRPCVersion.current)
        }
    }

    @Test func wireRejectsUnknownVersionAndGarbage() {
        #expect(throws: SearchRPCError.self) {
            let data = try SearchRPCWire.encode(SearchRPCRequest(
                version: SearchRPCVersion.current + 1,
                wikiID: "wiki-1",
                operation: .search(query: "x", kinds: nil, limit: 5)))
            _ = try SearchRPCWire.decode(data)
        }
        #expect(throws: SearchRPCError.self) {
            _ = try SearchRPCWire.decode(Data("not json".utf8))
        }
    }

    // MARK: - Single owner under concurrent cold requests

    @Test func concurrentColdRequestsShareOneRuntime() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let wikiID = WikiID(rawValue: "cold-dedup-wiki")
        let daemon = try await makeDaemon(directory: dir, wikiID: wikiID)
        let store = try daemon.resolvePreparedStore(wikiID: wikiID)
        _ = try seedPage(store, title: "HarborLantern", body: "A page about HarborLantern lights.")

        // All callers race the SAME cold wiki; the singleflight slot means
        // one construction task (one writer acquisition) serves every
        // caller — losers of the install fence yield, none may fail. The
        // calls are issued from separate tasks so they truly overlap on the
        // cached startup task rather than serializing after it.
        let replies = try await withThrowingTaskGroup(
            of: SearchRPCReply.self
        ) { group -> [SearchRPCReply] in
            for _ in 0..<6 {
                group.addTask {
                    try await self.runSearch(
                        daemon,
                        wikiID: wikiID,
                        operation: .search(query: "HarborLantern", kinds: nil, limit: 10))
                }
            }
            var collected: [SearchRPCReply] = []
            for try await reply in group { collected.append(reply) }
            return collected
        }

        #expect(replies.count == 6)
        for reply in replies {
            #expect(reply.error == nil)
            #expect(reply.hits?.isEmpty == false)
        }
        let runtime = daemon.activeSearchRuntimeForTesting(wikiID: wikiID)
        #expect(runtime != nil)
        #expect(await runtime?.isStopped == false)
    }

    // MARK: - Kind coverage

    @Test func searchAndAutocompleteCoverAllKinds() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let wikiID = WikiID(rawValue: "all-kinds-wiki")
        let daemon = try await makeDaemon(directory: dir, wikiID: wikiID)
        let store = try daemon.resolvePreparedStore(wikiID: wikiID)
        try seedAllKinds(store)

        let reply = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "ZebraQuantum", kinds: nil, limit: 20))
        #expect(reply.error == nil)
        let kinds = Set((reply.hits ?? []).map(\.kind))
        #expect(kinds == ["page", "source", "chat"])

        // The kind filter decodes raw wire strings into typed kinds at the
        // daemon boundary; a page-only request excludes the other kinds.
        let pagesOnly = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "ZebraQuantum", kinds: ["page"], limit: 20))
        #expect(pagesOnly.error == nil)
        #expect(Set((pagesOnly.hits ?? []).map(\.kind)) == ["page"])

        // Autocomplete goes through the same endpoint and runtime.
        let completions = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .autocomplete(partial: "Zebra", kinds: nil, distance: 2, limit: 10))
        #expect(completions.error == nil)
        #expect((completions.hits ?? []).isEmpty == false)
        #expect(Set((completions.hits ?? []).map(\.kind)) == ["page", "source", "chat"])

        // Composite document ids stay "<kind>:<ULID>" shaped.
        for hit in reply.hits ?? [] {
            #expect(hit.documentID.hasPrefix("\(hit.kind):"))
        }
    }

    // MARK: - External writer catch-up

    @Test func externalWriterCatchUpOnNextQuery() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let wikiID = WikiID(rawValue: "external-writer-wiki")
        let daemon = try await makeDaemon(directory: dir, wikiID: wikiID)
        let store = try daemon.resolvePreparedStore(wikiID: wikiID)
        _ = try seedPage(store, title: "SeasideOtters", body: "Otters of the seaside harbor.")

        // Baseline: the new page is not there yet, and the index is warm.
        let before = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "GlacierFox", kinds: nil, limit: 10))
        #expect(before.error == nil)
        #expect(before.hits?.isEmpty == true)

        // An external writer (a second store instance on the same SQLite
        // file — no daemon bus events) commits a new page.
        let external = try GRDBWikiStore(databaseURL: fixtureStoreURL(directory: dir, wikiID: wikiID))
        _ = try external.createPage(
            title: "GlacierFox Field Notes",
            body: "Observations of the GlacierFox pack.")

        // The NEXT query must catch up via the change-token check — no stale
        // silence allowed.
        let after = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "GlacierFox", kinds: nil, limit: 10))
        #expect(after.error == nil)
        #expect((after.hits ?? []).contains { $0.kind == "page" && $0.title.contains("GlacierFox") })

        // A warm, unchanged query afterwards does not lose the data.
        let warm = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "GlacierFox", kinds: nil, limit: 10))
        #expect((warm.hits ?? []).isEmpty == false)
    }

    // MARK: - Lifecycle release

    @Test func closeStoreReleasesRuntimeAndNextQueryRebuilds() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let wikiID = WikiID(rawValue: "release-wiki")
        let daemon = try await makeDaemon(directory: dir, wikiID: wikiID)
        let store = try daemon.resolvePreparedStore(wikiID: wikiID)
        _ = try seedPage(store, title: "MeadowBridge", body: "Bridges across the meadow.")

        let first = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "MeadowBridge", kinds: nil, limit: 10))
        #expect(first.hits?.isEmpty == false)
        let original = try #require(daemon.activeSearchRuntimeForTesting(wikiID: wikiID))

        // Close retires ATOMICALLY: the runtime stays resolvable while it
        // shuts down, and the awaited close returns only after the writer is
        // fully released and the map entry is dropped.
        await daemon.closeStore(wikiID: wikiID)
        #expect(daemon.activeSearchRuntimeForTesting(wikiID: wikiID) == nil)
        #expect(await original.isStopped)

        // Reopen: the fixture path needs an explicit prepare (production
        // re-admits services inside the construction itself).
        try await daemon.prepareWiki(wikiID)

        // The next query gets a fresh runtime (same on-disk index, token
        // baseline re-established from the store).
        let second = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "MeadowBridge", kinds: nil, limit: 10))
        #expect(second.hits?.isEmpty == false)
        let rebuilt = try #require(daemon.activeSearchRuntimeForTesting(wikiID: wikiID))
        #expect(ObjectIdentifier(rebuilt) != ObjectIdentifier(original))
    }

    // MARK: - Request errors

    @Test func unknownKindAndUnknownWikiAreRejected() async throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let wikiID = WikiID(rawValue: "error-wiki")
        let daemon = try await makeDaemon(directory: dir, wikiID: wikiID)
        let store = try daemon.resolvePreparedStore(wikiID: wikiID)
        _ = try seedPage(store, title: "CopperKettle", body: "Kettles of copper.")

        let badKind = try await runSearch(
            daemon, wikiID: wikiID,
            operation: .search(query: "CopperKettle", kinds: ["not-a-kind"], limit: 10))
        #expect(badKind.hits == nil)
        #expect(badKind.error?.code == .invalidRequest)

        let unknownWiki = try await runSearch(
            daemon, wikiID: WikiID(rawValue: "never-registered-wiki"),
            operation: .search(query: "CopperKettle", kinds: nil, limit: 10))
        #expect(unknownWiki.hits == nil)
        #expect(unknownWiki.error?.code == .unavailable)
    }
}
#endif
