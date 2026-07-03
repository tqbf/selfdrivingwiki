import Foundation
import Testing
@testable import WikiFSCore

/// Phase 0 of `plans/graph-model-and-versioning.md`: the store is
/// method-atomic (internal recursive lock), transactions nest via savepoints,
/// `renameSource` is atomic, and `WikiReadPool` provides off-main read-only
/// snapshot connections. These tests pin each of those properties.
@Suite("Store concurrency & transactions (graph-model Phase 0)")
struct StoreConcurrencyTests {

    private func makeStore() throws -> (store: SQLiteWikiStore, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreConcurrencyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wiki.sqlite")
        return (try SQLiteWikiStore(databaseURL: url), url)
    }

    // MARK: - Method atomicity

    /// Pre-lock, this pattern was the launch crash: concurrent callers of
    /// byte-identical SQL shared one cached `sqlite3_stmt*`, interleaved
    /// step/column reads, and trapped in `String(cString:)`. With the
    /// method-atomic lock this must run clean: many detached readers hammering
    /// the SAME statements while a writer mutates the same rows.
    @Test func concurrentReadersAndWriterDoNotCorrupt() async throws {
        let (store, _) = try makeStore()
        var created: [PageID] = []
        for i in 0..<20 {
            let page = try store.createPage(title: "Page \(i)")
            try store.updatePage(id: page.id, title: "Page \(i)", body: "body \(i) [[Page 0]]")
            created.append(page.id)
        }
        let ids = created   // immutable snapshot for the @Sendable task closures

        await withTaskGroup(of: Void.self) { group in
            // 8 readers × 100 iterations over the same cached statements.
            for _ in 0..<8 {
                group.addTask {
                    for i in 0..<100 {
                        _ = try? store.listPages(sortBy: .lastUpdated)
                        _ = try? store.getPage(id: ids[i % ids.count])
                        _ = try? store.resolveTitleToID("Page \(i % 20)")
                        _ = try? store.changeToken()
                    }
                }
            }
            // 1 writer updating rows the readers are decoding.
            group.addTask {
                for i in 0..<100 {
                    let id = ids[i % ids.count]
                    try? store.updatePage(
                        id: id, title: "Page \(i % ids.count)",
                        body: String(repeating: "wiki content \(i) ", count: 50))
                }
            }
        }

        // Survived without a trap; state is consistent.
        let pages = try store.listPages(sortBy: .titleAZ)
        #expect(pages.count == 20)
    }

    // MARK: - Nested transactions (savepoints)

    @Test func nestedTransactionRollsBackOnlyItself() throws {
        let (store, _) = try makeStore()
        try store.withTransaction {
            _ = try store.createPage(title: "A")
            do {
                try store.withTransaction {
                    _ = try store.createPage(title: "B")
                    throw WikiStoreError.unexpected("inner boom")
                }
            } catch { /* best-effort caller: inner work must be gone */ }
            _ = try store.createPage(title: "C")
        }
        let titles = Set(try store.listPages(sortBy: .titleAZ).map(\.title))
        #expect(titles == ["A", "C"])
    }

    @Test func outermostRollbackDiscardsEverything() throws {
        let (store, _) = try makeStore()
        do {
            try store.withTransaction {
                _ = try store.createPage(title: "X")
                try store.withTransaction { _ = try store.createPage(title: "Y") }
                throw WikiStoreError.unexpected("outer boom")
            }
        } catch { /* expected */ }
        #expect(try store.listPages(sortBy: .titleAZ).isEmpty)
    }

    /// Regression guard for the nested-BEGIN failure mode: methods that own
    /// transactions (`storePageChunks` → `replaceChunks`, `replaceLinks`) must
    /// compose inside an outer transaction as savepoints instead of throwing
    /// "cannot start a transaction within a transaction".
    @Test func transactionOwningMethodsNestInsideOuterTransaction() throws {
        let (store, _) = try makeStore()
        let page = try store.createPage(title: "Chunked")
        try store.withTransaction {
            try store.storePageChunks(id: page.id, chunks: [Data([1, 2, 3])])
            try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse("[[Chunked]]"))
        }
        #expect(try store.getPage(id: page.id).title == "Chunked")
    }

    // MARK: - Atomic renameSource

    /// `renameSource` used to be documented "eventually consistent" because raw
    /// `BEGIN IMMEDIATE` couldn't nest around `updatePage`/`replaceLinks`. It
    /// now commits the source row + every page rewrite in one transaction —
    /// this exercises the savepoint path end-to-end.
    @Test func renameSourceRewritesAllLinkingPagesAtomically() throws {
        let (store, _) = try makeStore()
        let source = try store.addSource(
            filename: "paper.md", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: "text/markdown")

        var pageIDs: [PageID] = []
        for i in 0..<3 {
            let page = try store.createPage(title: "Linker \(i)")
            let body = "See [[source:paper.md#\"hello\"|the paper]] and [[source:paper.md]]."
            try store.updatePage(id: page.id, title: "Linker \(i)", body: body)
            try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(body))
            pageIDs.append(page.id)
        }

        try store.renameSource(id: source.id, to: "The Great Paper")

        for id in pageIDs {
            let body = try store.getPage(id: id).bodyMarkdown
            #expect(body.contains("[[source:The Great Paper#\"hello\"|the paper]]"))
            #expect(body.contains("[[source:The Great Paper]]"))
            #expect(!body.contains("paper.md#"))
        }
        #expect(try store.sourceLinkingPages(to: source.id).count == 3)
    }

    // MARK: - WikiReadPool

    @Test func poolReadSeesWriterCommits() throws {
        let (store, url) = try makeStore()
        let pool = WikiReadPool(databaseURL: url)

        _ = try store.createPage(title: "Visible")
        let titles = try pool.read { reader in
            try reader.listPages(sortBy: .titleAZ).map(\.title)
        }
        #expect(titles == ["Visible"])

        // A later write is visible on a REUSED pooled connection (fresh read
        // transaction per query — no stale long-lived snapshot).
        _ = try store.createPage(title: "Also visible")
        let titles2 = try pool.read { reader in
            try reader.listPages(sortBy: .titleAZ).map(\.title)
        }
        #expect(titles2 == ["Also visible", "Visible"])
    }

    @Test func poolConnectionsAreReadOnly() throws {
        let (store, url) = try makeStore()
        _ = try store.createPage(title: "Seed")
        let pool = WikiReadPool(databaseURL: url)
        #expect(throws: (any Error).self) {
            try pool.read { reader in
                _ = try reader.createPage(title: "Forbidden")
            }
        }
        // The write never landed.
        #expect(try store.listPages(sortBy: .titleAZ).count == 1)
    }

    @Test func poolReusesIdleConnections() throws {
        let (store, url) = try makeStore()
        _ = try store.createPage(title: "Seed")
        let pool = WikiReadPool(databaseURL: url, maxIdle: 2)
        #expect(pool.idleCountForTesting == 0)
        _ = try pool.read { try $0.changeToken() }
        #expect(pool.idleCountForTesting == 1)
        _ = try pool.read { try $0.changeToken() }
        #expect(pool.idleCountForTesting == 1)   // reused, not grown
    }

    @Test func poolAsyncReadRunsOffCaller() async throws {
        let (store, url) = try makeStore()
        _ = try store.createPage(title: "Async")
        let pool = WikiReadPool(databaseURL: url)
        let count = try await pool.asyncRead { reader in
            try reader.listPages(sortBy: .titleAZ).count
        }
        #expect(count == 1)
    }

    /// Concurrent pool reads while the writer churns — the cross-connection
    /// analogue of the hammer test above (WAL: N readers + 1 writer).
    @Test func concurrentPoolReadsWithLiveWriter() async throws {
        let (store, url) = try makeStore()
        for i in 0..<10 { _ = try store.createPage(title: "P\(i)") }
        let pool = WikiReadPool(databaseURL: url)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    for _ in 0..<50 {
                        _ = try? pool.read { try $0.listPages(sortBy: .lastUpdated).count }
                    }
                }
            }
            group.addTask {
                for i in 0..<50 {
                    _ = try? store.createPage(title: "W\(i)")
                }
            }
        }
        #expect(try store.listPages(sortBy: .titleAZ).count == 60)
    }
}
