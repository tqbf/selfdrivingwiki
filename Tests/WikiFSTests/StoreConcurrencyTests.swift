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
            externalItemKey: nil, externalItemTitle: nil, mimeType: "text/markdown")

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

// MARK: - Chat attachments (plans/chat-attachment-persistence.md, AC.12)

/// Lock-protected event tallies, safe to update from `@MainActor` bus handlers.
private final class ConcurrentEventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _created = 0
    private var _updated = 0
    var created: Int { lock.withLock { _created } }
    var updated: Int { lock.withLock { _updated } }
    /// Attach to the bus; counts post-commit `.chat` events by change kind.
    func attach(to bus: WikiEventBus) {
        _ = bus.subscribe(.chat) { [weak self] event in
            guard let self else { return }
            self.lock.lock()
            switch event.change {
            case .created: self._created += 1
            case .updated: self._updated += 1
            default: break
            }
            self.lock.unlock()
        }
    }
    /// Bounded poll: waits (nonblocking sleeps) until BOTH counts hold, then
    /// reports the final match.
    func waitCounts(created expectedCreated: Int, updated expectedUpdated: Int) async -> Bool {
        for _ in 0..<40 {
            if created == expectedCreated && updated == expectedUpdated { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return created == expectedCreated && updated == expectedUpdated
    }
}

/// Lock-protected tallies for `@Sendable` task closures.
private final class ConcurrencyTallies: @unchecked Sendable {
    private let lock = NSLock()
    private var _setA = 0
    private var _setB = 0
    private var _partial = 0
    private var _reads = 0
    var setA: Int { lock.withLock { _setA } }
    var setB: Int { lock.withLock { _setB } }
    var partial: Int { lock.withLock { _partial } }
    var reads: Int { lock.withLock { _reads } }
    func tally(_ targets: [ChatAttachmentTarget], setA: [ChatAttachmentTarget], setB: [ChatAttachmentTarget]) {
        lock.lock()
        if targets == setA {
            _setA += 1
        } else if targets == setB {
            _setB += 1
        } else {
            _partial += 1
        }
        lock.unlock()
    }
    func countRead() {
        lock.withLock { _reads += 1 }
    }
}

extension StoreConcurrencyTests {

    /// AC.12(a): concurrent attachment READS vs `setChatAttachments`
    /// replacements. Each write is one savepoint (DELETE + ordered INSERT),
    /// so every read — however contended — must observe exactly one COMPLETE
    /// set (never a partial or interleaved one), and the final state must be
    /// one of the two written sets.
    @Test func concurrentAttachmentReadsVsReplacementsStayConsistent() async throws {
        let (store, _) = try makeStore()
        let chat = try store.createChat(kind: .edit, title: "")
        let setA: [ChatAttachmentTarget] = [
            .page(PageID(rawValue: "01HCONCA")),
            .page(PageID(rawValue: "01HCONCB")),
        ]
        let setB: [ChatAttachmentTarget] = [
            .source(SourceID(rawValue: "01HCONCS")),
            .chat(ChatID(rawValue: "01HCONCC")),
        ]
        try store.setChatAttachments(chatID: chat.id, targets: setA)

        let tallies = ConcurrencyTallies()
        await withTaskGroup(of: Void.self) { group in
            // 4 readers × 60 reads under replacement pressure.
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<60 {
                        let targets = (try? store.chatAttachments(chatID: chat.id)) ?? []
                        tallies.tally(targets, setA: setA, setB: setB)
                    }
                }
            }
            // 1 writer alternating between two COMPLETE sets.
            group.addTask {
                for i in 0..<60 {
                    try? store.setChatAttachments(
                        chatID: chat.id, targets: i % 2 == 0 ? setA : setB)
                }
            }
        }

        #expect(tallies.partial == 0, "no read may observe a partial or interleaved set")
        #expect(tallies.setA + tallies.setB > 0, "reads must observe complete sets")
        let final = try store.chatAttachments(chatID: chat.id)
        #expect(final == setA || final == setB, "final state is one complete written set")
    }

    /// AC.12(b): the new mutators nest inside `withTransaction` (savepoint —
    /// the outer rollback discards only the nested work), and a failed write
    /// under a contended store — an ABORT trigger on `chat_attachments`
    /// installed on a separate connection, the ChatAttachmentPersistenceTests
    /// pattern — rolls back with the old rows intact and ZERO events. The
    /// gate emits again after the trigger is dropped.
    @Test func attachmentMutatorsNestRollBackAndEmitUnderContention() async throws {
        let (store, url) = try makeStore()
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "test"))
        let counter = ConcurrentEventCounter()
        counter.attach(to: store.eventBus!)

        let chat = try store.createChat(kind: .edit, title: "")
        let setA: [ChatAttachmentTarget] = [.page(PageID(rawValue: "01HNESTA"))]
        try store.setChatAttachments(chatID: chat.id, targets: setA)
        #expect(await counter.waitCounts(created: 1, updated: 1),
                "seed writes land: one .created, one .updated")

        // Contended store: a detached reader hammers the same rows while the
        // writer nests mutators inside outer transactions.
        let reads = ConcurrencyTallies()
        let reader = Task.detached {
            for _ in 0..<80 {
                _ = try? store.chatAttachments(chatID: chat.id)
                reads.countRead()
            }
        }

        // Nesting + rollback: the inner replacement attaches in a savepoint;
        // the outer throw discards the ROWS. Per the composition guard's
        // nesting note (:484-496) the inner `mutate` already EMITTED its
        // `.updated` event when its savepoint returned — an outer rollback
        // cannot suppress an emitted event. Rows roll back; the event escapes
        // (documented hazard — exactly why the composed create uses one
        // top-level mutate with *Locked helpers instead).
        do {
            try store.withTransaction {
                try store.setChatAttachments(chatID: chat.id, targets: [
                    .source(SourceID(rawValue: "01HNEST")),
                ])
                throw WikiStoreError.unexpected("outer boom")
            }
        } catch { /* best-effort caller: inner work must be gone */ }
        #expect(try store.chatAttachments(chatID: chat.id) == setA,
                "the nested set rolled back with the outer transaction")
        #expect(await counter.waitCounts(created: 1, updated: 2),
                "the nested write's .updated escaped the outer rollback (:484-496)")

        // Nesting + commit: the nested replacement and a sibling write both
        // commit together.
        let sibling = try store.createPage(title: "Sibling")
        try store.withTransaction {
            try store.setChatAttachments(chatID: chat.id, targets: [
                .page(sibling.id),
            ])
            _ = try store.createPage(title: "Sibling Anchor")
        }
        #expect(try store.chatAttachments(chatID: chat.id) == [.page(sibling.id)])
        #expect(try store.listPages(sortBy: .titleAZ).contains { $0.title == "Sibling Anchor" })

        // Injected failure under contention: the ABORT trigger fails the
        // replacement mid-write; the body throws BEFORE the event is
        // computed, so the savepoint rolls back with the old rows intact and
        // ZERO events (unlike the nested-escape above, here the failure is
        // the mutator's own body, not an outer rollback).
        try MetadataSQLiteFixtureSupport.execute(
            """
            CREATE TRIGGER fail_chat_attachments_insert_conc
            BEFORE INSERT ON chat_attachments
            BEGIN SELECT RAISE(ABORT, 'injected'); END;
            """,
            at: url)
        do {
            try store.setChatAttachments(chatID: chat.id, targets: [
                .source(SourceID(rawValue: "01HNEVER")),
            ])
            Issue.record("the replacement must fail under the injected trigger")
        } catch { /* expected */ }
        #expect(try store.chatAttachments(chatID: chat.id) == [.page(sibling.id)],
                "old rows survive the rolled-back replacement")
        try MetadataSQLiteFixtureSupport.execute(
            "DROP TRIGGER IF EXISTS fail_chat_attachments_insert_conc;", at: url)

        _ = await reader.value
        #expect(reads.reads > 0, "the contended reader ran")

        // Event discipline: exactly one .updated per successful write (setA,
        // nested commit, post-drop), zero for the rollback and the failure.
        #expect(await counter.waitCounts(created: 1, updated: 3))
    }
}
