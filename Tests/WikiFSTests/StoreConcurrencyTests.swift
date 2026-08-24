import Foundation
import Testing
@testable import WikiFSCore

/// Phase 0 of `plans/graph-model-and-versioning.md`: the store is
/// method-atomic (internal recursive lock), transactions nest via savepoints,
/// `renameSource` is atomic, and `WikiReadService` provides off-main read-only
/// snapshot access. These tests pin each of those properties.
@Suite("Store concurrency & transactions (graph-model Phase 0)")
struct StoreConcurrencyTests {

    private func makeStore() throws -> (store: GRDBWikiStore, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreConcurrencyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wiki.sqlite")
        return (try GRDBWikiStore(databaseURL: url), url)
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
        let titles: Set<String> = Set(try store.listPages(sortBy: .titleAZ).map(\.title))
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

    /// `renameSource` commits the source-row update in one transaction. Phase 5
    /// removed the body-rewrite loop (stored aliases self-heal at render), so
    /// this now verifies the rename is still atomic AND that no linking-page
    /// body is touched — the zero-body-writes guarantee (AC.9).
    @Test func renameSourceDoesNotRewriteLinkingPagesAtomically() throws {
        let (store, _) = try makeStore()
        let source = try store.addSource(
            filename: "paper.md", data: Data("hello".utf8),
            zoteroItemKey: nil, zoteroItemTitle: nil, mimeType: "text/markdown")

        var pageIDs: [PageID] = []
        var originalBodies: [PageID: String] = [:]
        for i in 0..<3 {
            let page = try store.createPage(title: "Linker \(i)")
            let body = "See [[source:paper.md#\"hello\"|the paper]] and [[source:paper.md]]."
            try store.updatePage(id: page.id, title: "Linker \(i)", body: body)
            try store.replaceLinks(from: page.id, parsedLinks: WikiLinkParser.parse(body))
            pageIDs.append(page.id)
            originalBodies[page.id] = body
        }

        try store.renameSource(id: source.id, to: "The Great Paper")

        // The source row is renamed (the atomic one-row update committed).
        #expect(try store.getSource(id: source.id).displayName == "The Great Paper")
        // No linking-page body changed (zero body writes — the AC.9 gate).
        for id in pageIDs {
            #expect(try store.getPage(id: id).bodyMarkdown == originalBodies[id])
        }
        // Link rows are intact.
        #expect(try store.sourceLinkingPages(to: source.id).count == 3)
    }

    // MARK: - WikiReadService

    @Test func readServiceSeesWriterCommits() async throws {
        let (store, url) = try makeStore()
        let service = WikiReadService(databaseURL: url)

        _ = try store.addSource(filename: "visible.txt", data: Data("one".utf8))
        let names = try await service.asyncRead { try $0.listSources().map(\.filename) }
        #expect(names == ["visible.txt"])

        _ = try store.addSource(filename: "also-visible.txt", data: Data("two".utf8))
        let namesAfterWrite = try await service.asyncRead { try $0.listSources().map(\.filename).sorted() }
        #expect(namesAfterWrite == ["also-visible.txt", "visible.txt"])
    }

    @Test func readServiceReusesIdleConnections() async throws {
        let (store, url) = try makeStore()
        _ = try store.addSource(filename: "seed.txt", data: Data("seed".utf8))
        let service = WikiReadService(databaseURL: url, maxIdle: 2)
        #expect(await service.idleConnectionCountForTesting() == 0)
        _ = try await service.asyncRead { try $0.listSources().count }
        #expect(await service.idleConnectionCountForTesting() == 1)
        _ = try await service.asyncRead { try $0.listSources().count }
        #expect(await service.idleConnectionCountForTesting() == 1)
    }

    @Test func readServiceRejectsReadsAfterShutdown() async throws {
        let (_, url) = try makeStore()
        let service = WikiReadService(databaseURL: url)
        await service.shutdown()
        await service.shutdown()

        #expect(await service.lifecycleStateForTesting() == .stopped)
        await #expect(throws: WikiReadServiceError.unavailable) {
            try await service.asyncRead { try $0.listSources().count }
        }
    }

    /// Concurrent service reads while the writer changes the WAL head.
    @Test func concurrentReadServiceReadsWithLiveWriter() async throws {
        let (store, url) = try makeStore()
        for i in 0..<10 {
            _ = try store.addSource(filename: "P\(i).txt", data: Data("P\(i)".utf8))
        }
        let service = WikiReadService(databaseURL: url)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    for _ in 0..<50 {
                        do {
                            _ = try await service.asyncRead { try $0.listSources().count }
                        } catch {
                            Issue.record(error)
                        }
                    }
                }
            }
            group.addTask {
                for i in 0..<50 {
                    do {
                        _ = try store.addSource(filename: "W\(i).txt", data: Data("W\(i)".utf8))
                    } catch {
                        Issue.record(error)
                    }
                }
            }
        }
        #expect(try store.listSources().count == 60)
    }
}
