#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
@testable import WikiFSCore

/// #637: integration tests for `CLITantivyLegResolver`, the bridge that routes
/// `wikictl page/source/chat search` through the same on-disk Tantivy BM25 leg
/// the app's sidebar uses.
///
/// These tests construct a real `GRDBWikiStore`, build a Tantivy index against
/// it via the same `StoreBackedTantivyContentSource` the app uses, then verify
/// the resolver returns the indexed pages as a best-first BM25 leg (which the
/// store's 3-arg `searchSimilar(query:limit:bm25Leg:)` then fuses with the
/// cosine leg via RRF). The fuzzy-typo AC for `wikictl page search "erikson"`
/// (finds "Erickson") is covered by `resolvePageLegSurfacesFuzzyTypoMatches`.
///
/// These are fast: they open a temp SQLite DB, build a small Tantivy index
/// (3-5 docs), and call one resolver method per test. They live in the fast
/// CI tier (not skip-listed).
///
@Suite
struct CLITantivyLegResolverTests {
    actor ConcurrentSearchGate {
        private let expectedCount: Int
        private var arrivals = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(expectedCount: Int) {
            self.expectedCount = expectedCount
        }

        func arriveAndWait() async {
            arrivals += 1
            if arrivals == expectedCount {
                let continuations = waiters
                waiters.removeAll()
                continuations.forEach { $0.resume() }
                return
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    // MARK: - Helpers

    /// Fresh temp directory per test (UUID) holding both the `<ulid>.sqlite`
    /// and the `search-index/<wikiID>/` Tantivy index. Removed in `defer` so
    /// nothing leaks between runs.
    private func makeTempContainer() throws -> (URL, FileManager) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cli-tantivy-leg-\(UUID().uuidString)")
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, fm)
    }

    private func tempStore(in container: URL, wikiID: WikiID) throws -> GRDBWikiStore {
        let dbURL = container.appendingPathComponent("\(wikiID.rawValue).sqlite", isDirectory: false)
        return try GRDBWikiStore(databaseURL: dbURL)
    }

    // MARK: - resolvePageLeg

    @Test func resolvePageLegReturnsNilWhenIndexEmpty() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0001")
        let store = try tempStore(in: container, wikiID: wikiID)
        // No Tantivy index exists yet — `rebuildIfNeeded` was never called
        // (the app would normally kick it off in `TantivyShadowSync.start()`).
        // The resolver must return nil so the store runs without a BM25 leg
        // (the #637 contract — empty leg = no lexical signal).
        let leg = await CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "anything", limit: 10)
        #expect(leg == nil)
    }

    @Test func resolvePageLegReturnsIndexedPagesInBestFirstOrder() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0002")
        let store = try tempStore(in: container, wikiID: wikiID)
        // Seed a page whose body repeats "rust" (high BM25 signal) and another
        // with a single mention.
        let a = try store.createPage(title: "Rust Ownership")
        try store.updatePage(id: a.id, title: "Rust Ownership",
                             body: "rust rust rust rust borrowing and lifetimes")
        let b = try store.createPage(title: "Other")
        try store.updatePage(id: b.id, title: "Other", body: "a brief mention of rust")

        // The CLI resolver rebuilds the Tantivy index from the store when
        // empty (mirrors `TantivyShadowSync.start()` in the app) — no need to
        // pre-build it in the test. The first call pays the rebuild cost;
        // subsequent calls see a populated index and short-circuit on
        // `count()`.
        let leg = await CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "rust", limit: 10)
        // The leg is non-nil (the index returned hits) and contains BOTH pages.
        #expect(leg != nil)
        #expect(leg?.count == 2)
        // Tantivy ranks the higher-term-frequency page first (BM25 signal) —
        // the resolver preserves that order.
        #expect(leg?.first?.id == a.id)
    }

    @Test func resolvePageLegSurfacesFuzzyTypoMatches() async throws {
        // AC #637: `wikictl page search "erikson"` (one-character typo) returns
        // "Erickson"-style pages. Tantivy's `fuzzyFields` are configured with
        // edit-distance 1 on title + body (`TantivyIndexer.swift:108-111`),
        // so the resolver's leg should include the correctly-spelled page
        // even though the query is misspelled.
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0003")
        let store = try tempStore(in: container, wikiID: wikiID)
        let page = try store.createPage(title: "Milton H. Erickson")
        try store.updatePage(id: page.id, title: "Milton H. Erickson",
                             body: "Milton H. Erickson was an American psychiatrist specializing in clinical hypnosis.")

        // Query with a one-character typo ("erikson" vs "erickson"). Fuzzy
        // matching (edit-distance 1) should still surface the page. The
        // resolver's internal `rebuildIfNeeded()` populates the index from
        // the store on first call.
        let leg = await CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "erikson", limit: 10)
        #expect(leg != nil, "fuzzy match should find Erickson despite the typo")
        #expect(leg?.contains { $0.id == page.id } ?? false)
    }

    // MARK: - resolveSourceLeg

    @Test func resolveSourceLegReturnsIndexedSources() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0004")
        let store = try tempStore(in: container, wikiID: wikiID)
        _ = try store.addSource(
            filename: "self-driving-cars.pdf", data: Data("%PDF".utf8))
        // Give the source a body via processed-markdown so Tantivy has text to
        // index beyond the filename (mirrors the production content source).
        let sources = try store.listSources()
        _ = try store.appendProcessedMarkdown(
            sourceID: sources[0].id,
            content: "A longitudinal study of autonomous vehicle safety.",
            origin: .extraction, note: nil, technique: nil)

        let leg = await CLITantivyLegResolver.resolveSourceLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "autonomous", limit: 10)
        #expect(leg != nil)
        #expect(leg?.count == 1)
        #expect(leg?.first?.id == sources[0].id)
    }

    // MARK: - resolveChatLeg

    @Test func resolveChatLegReturnsIndexedChats() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0005")
        let store = try tempStore(in: container, wikiID: wikiID)
        let chat = try store.createChat(kind: .edit, title: "Mars Colony")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("We discussed terraforming the Martian surface."),
        ])

        let leg = await CLITantivyLegResolver.resolveChatLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "terraforming", limit: 10)
        #expect(leg != nil)
        #expect(leg?.count == 1)
        #expect(leg?.first?.id == chat.id)
    }

    @Test func concurrentResolversReturnExpectedResults() async throws {
        enum SearchKind: Sendable {
            case page
            case source
            case chat
        }

        struct SearchOutcome: Sendable {
            let kind: SearchKind
            let id: PageID?
        }

        let (pageContainer, pageFM) = try makeTempContainer()
        defer { try? pageFM.removeItem(at: pageContainer) }
        let pageWikiID = WikiID(rawValue: "01TEST0007")
        let pageStore = try tempStore(in: pageContainer, wikiID: pageWikiID)
        let page = try pageStore.createPage(title: "Rust Ownership")
        try pageStore.updatePage(
            id: page.id,
            title: "Rust Ownership",
            body: "ownership borrowing lifetimes ownership")

        let (sourceContainer, sourceFM) = try makeTempContainer()
        defer { try? sourceFM.removeItem(at: sourceContainer) }
        let sourceWikiID = WikiID(rawValue: "01TEST0008")
        let sourceStore = try tempStore(in: sourceContainer, wikiID: sourceWikiID)
        _ = try sourceStore.addSource(filename: "async-search.pdf", data: Data("%PDF".utf8))
        let source = try #require(sourceStore.listSources().first)
        _ = try sourceStore.appendProcessedMarkdown(
            sourceID: source.id,
            content: "Concurrent search regression coverage for wikictl tantivy.",
            origin: .extraction,
            note: nil,
            technique: nil)

        let (chatContainer, chatFM) = try makeTempContainer()
        defer { try? chatFM.removeItem(at: chatContainer) }
        let chatWikiID = WikiID(rawValue: "01TEST0009")
        let chatStore = try tempStore(in: chatContainer, wikiID: chatWikiID)
        let chat = try chatStore.createChat(kind: .edit, title: "Async Search")
        _ = try chatStore.appendChatMessages(chatID: chat.id, events: [
            .assistantText("Async search should not block concurrent resolver calls."),
        ])

        let initialPageLeg = await CLITantivyLegResolver.resolvePageLeg(
            wikiID: pageWikiID,
            containerDirectory: pageContainer,
            store: pageStore,
            query: "ownership",
            limit: 5)
        let initialSourceLeg = await CLITantivyLegResolver.resolveSourceLeg(
            wikiID: sourceWikiID,
            containerDirectory: sourceContainer,
            store: sourceStore,
            query: "Concurrent",
            limit: 5)
        let initialChatLeg = await CLITantivyLegResolver.resolveChatLeg(
            wikiID: chatWikiID,
            containerDirectory: chatContainer,
            store: chatStore,
            query: "concurrent",
            limit: 5)
        #expect(initialPageLeg?.first?.id == page.id)
        #expect(initialSourceLeg?.first?.id == source.id)
        #expect(initialChatLeg?.first?.id == chat.id)

        let outcomes = await withTaskGroup(of: SearchOutcome.self, returning: [SearchOutcome].self) { group in
            for _ in 0..<3 {
                group.addTask {
                    _ = await CLITantivyLegResolver.resolvePageLeg(
                        wikiID: pageWikiID,
                        containerDirectory: pageContainer,
                        store: pageStore,
                        query: "ownership",
                        limit: 5)
                    let leg = await CLITantivyLegResolver.resolvePageLeg(
                        wikiID: pageWikiID,
                        containerDirectory: pageContainer,
                        store: pageStore,
                        query: "ownership",
                        limit: 5)
                    return SearchOutcome(kind: .page, id: leg?.first?.id)
                }
                group.addTask {
                    _ = await CLITantivyLegResolver.resolveSourceLeg(
                        wikiID: sourceWikiID,
                        containerDirectory: sourceContainer,
                        store: sourceStore,
                        query: "Concurrent",
                        limit: 5)
                    let leg = await CLITantivyLegResolver.resolveSourceLeg(
                        wikiID: sourceWikiID,
                        containerDirectory: sourceContainer,
                        store: sourceStore,
                        query: "Concurrent",
                        limit: 5)
                    return SearchOutcome(kind: .source, id: leg?.first?.id)
                }
                group.addTask {
                    _ = await CLITantivyLegResolver.resolveChatLeg(
                        wikiID: chatWikiID,
                        containerDirectory: chatContainer,
                        store: chatStore,
                        query: "concurrent",
                        limit: 5)
                    let leg = await CLITantivyLegResolver.resolveChatLeg(
                        wikiID: chatWikiID,
                        containerDirectory: chatContainer,
                        store: chatStore,
                        query: "concurrent",
                        limit: 5)
                    return SearchOutcome(kind: .chat, id: leg?.first?.id)
                }
            }

            var collected: [SearchOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        #expect(outcomes.count == 9)
        let pageHits = outcomes.filter { $0.kind == .page }
        let sourceHits = outcomes.filter { $0.kind == .source }
        let chatHits = outcomes.filter { $0.kind == .chat }
        #expect(pageHits.count == 3)
        #expect(sourceHits.count == 3)
        #expect(chatHits.count == 3)
        #expect(pageHits.allSatisfy { $0.id == page.id }, "pageHits: \(pageHits)")
        #expect(sourceHits.allSatisfy { $0.id == source.id }, "sourceHits: \(sourceHits)")
        #expect(chatHits.allSatisfy { $0.id == chat.id }, "chatHits: \(chatHits)")
    }

    @Test func sameWikiConcurrentDistinctRequestsDoNotShareWrongTask() async throws {
        struct SearchOutcome: Sendable {
            let label: String
            let ids: [PageID]?
        }

        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0010")
        let store = try tempStore(in: container, wikiID: wikiID)

        let pageRust = try store.createPage(title: "Rust Ownership")
        try store.updatePage(
            id: pageRust.id,
            title: "Rust Ownership",
            body: "cobalt cobalt cobalt borrowingkey lifetimes")
        let pageOwnership = try store.createPage(title: "Ownership Guide")
        try store.updatePage(
            id: pageOwnership.id,
            title: "Ownership Guide",
            body: "amber amber borrowing")
        let pageAsync = try store.createPage(title: "Async Rust")
        try store.updatePage(
            id: pageAsync.id,
            title: "Async Rust",
            body: "cobalt asyncsignal await")

        _ = try store.addSource(filename: "zircon-rust.pdf", data: Data("%PDF-rust".utf8))
        _ = try store.addSource(filename: "amber-ownership.pdf", data: Data("%PDF-ownership".utf8))
        let sources = try store.listSources()
        let rustSource = try #require(sources.first { $0.filename == "zircon-rust.pdf" })
        let ownershipSource = try #require(sources.first { $0.filename == "amber-ownership.pdf" })
        _ = try store.appendProcessedMarkdown(
            sourceID: rustSource.id,
            content: "zircon indexing coverage for Tantivy.",
            origin: .extraction,
            note: nil,
            technique: nil)
        _ = try store.appendProcessedMarkdown(
            sourceID: ownershipSource.id,
            content: "amber notes for borrow checking.",
            origin: .extraction,
            note: nil,
            technique: nil)

        let rustChat = try store.createChat(kind: .edit, title: "Rust Search")
        _ = try store.appendChatMessages(chatID: rustChat.id, events: [
            .assistantText("Rust search discussed cobaltchat async indexing and ranking."),
        ])
        let terraformChat = try store.createChat(kind: .edit, title: "Terraforming")
        _ = try store.appendChatMessages(chatID: terraformChat.id, events: [
            .assistantText("Terraforming needs terraformalpha greenhouse heat and atmosphere retention."),
        ])

        let warmPageLeg = await CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID,
            containerDirectory: container,
            store: store,
            query: "cobalt borrowingkey",
            limit: 3)
        let warmSourceLeg = await CLITantivyLegResolver.resolveSourceLeg(
            wikiID: wikiID,
            containerDirectory: container,
            store: store,
            query: "zircon",
            limit: 1)
        let warmChatLeg = await CLITantivyLegResolver.resolveChatLeg(
            wikiID: wikiID,
            containerDirectory: container,
            store: store,
            query: "terraformalpha",
            limit: 1)
        #expect(warmPageLeg?.first?.id == pageRust.id)
        #expect(warmSourceLeg?.first?.id == rustSource.id)
        #expect(warmChatLeg?.first?.id == terraformChat.id)

        let gate = ConcurrentSearchGate(expectedCount: 6)
        let containerPath = container.standardizedFileURL.path
        await CLITantivyLegResolver.installTestSearchHook { key in
            guard key.wikiID == wikiID, key.containerPath == containerPath else { return }
            await gate.arriveAndWait()
        }

        let outcomes = await withTaskGroup(of: SearchOutcome.self, returning: [SearchOutcome].self) { group in
            group.addTask {
                let leg = await CLITantivyLegResolver.resolvePageLeg(
                    wikiID: wikiID,
                    containerDirectory: container,
                    store: store,
                    query: "cobalt borrowingkey",
                    limit: 2)
                return SearchOutcome(label: "page-rust-2", ids: leg?.map(\.id))
            }
            group.addTask {
                let leg = await CLITantivyLegResolver.resolvePageLeg(
                    wikiID: wikiID,
                    containerDirectory: container,
                    store: store,
                    query: "cobalt borrowingkey",
                    limit: 1)
                return SearchOutcome(label: "page-rust-1", ids: leg?.map(\.id))
            }
            group.addTask {
                let leg = await CLITantivyLegResolver.resolvePageLeg(
                    wikiID: wikiID,
                    containerDirectory: container,
                    store: store,
                    query: "amber",
                    limit: 1)
                return SearchOutcome(label: "page-ownership-1", ids: leg?.map(\.id))
            }
            group.addTask {
                let leg = await CLITantivyLegResolver.resolveSourceLeg(
                    wikiID: wikiID,
                    containerDirectory: container,
                    store: store,
                    query: "zircon",
                    limit: 1)
                return SearchOutcome(label: "source-rust-1", ids: leg?.map(\.id))
            }
            group.addTask {
                let leg = await CLITantivyLegResolver.resolveSourceLeg(
                    wikiID: wikiID,
                    containerDirectory: container,
                    store: store,
                    query: "amber",
                    limit: 1)
                return SearchOutcome(label: "source-ownership-1", ids: leg?.map(\.id))
            }
            group.addTask {
                let leg = await CLITantivyLegResolver.resolveChatLeg(
                    wikiID: wikiID,
                    containerDirectory: container,
                    store: store,
                    query: "terraformalpha",
                    limit: 1)
                return SearchOutcome(label: "chat-terraforming-1", ids: leg?.map(\.id))
            }

            var collected: [SearchOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }
        await CLITantivyLegResolver.resetTestSearchHook()

        func outcome(named label: String) -> SearchOutcome? {
            outcomes.first { $0.label == label }
        }
        #expect(outcomes.count == 6)
        #expect(outcome(named: "page-rust-2")?.ids == [pageRust.id, pageAsync.id], "page-rust-2: \(String(describing: outcome(named: "page-rust-2")?.ids))")
        #expect(outcome(named: "page-rust-1")?.ids == [pageRust.id], "page-rust-1: \(String(describing: outcome(named: "page-rust-1")?.ids))")
        #expect(outcome(named: "page-ownership-1")?.ids == [pageOwnership.id], "page-ownership-1: \(String(describing: outcome(named: "page-ownership-1")?.ids))")
        #expect(outcome(named: "source-rust-1")?.ids == [rustSource.id], "source-rust-1: \(String(describing: outcome(named: "source-rust-1")?.ids))")
        #expect(outcome(named: "source-ownership-1")?.ids == [ownershipSource.id], "source-ownership-1: \(String(describing: outcome(named: "source-ownership-1")?.ids))")
        #expect(outcome(named: "chat-terraforming-1")?.ids == [terraformChat.id], "chat-terraforming-1: \(String(describing: outcome(named: "chat-terraforming-1")?.ids))")
    }

    // MARK: - No-BM25-leg behavior when no Tantivy service can be built

    @Test func resolvePageLegReturnsNilWhenServiceConstructionFails() async throws {
        // Point the resolver at a container path that doesn't exist and can't
        // be created (a file in place of the container dir). `makeService`
        // catches the throw and returns nil — the store then runs without a
        // BM25 leg (the #637 contract — Tantivy unavailable = no lexical leg,
        // not an error).
        let fileAsContainer = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-tantivy-leg-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: fileAsContainer)
        defer { try? FileManager.default.removeItem(at: fileAsContainer) }

        // A real store the resolver can list pages from (won't be reached —
        // makeService throws first).
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = WikiID(rawValue: "01TEST0006")
        let store = try tempStore(in: container, wikiID: wikiID)

        let leg = await CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID, containerDirectory: fileAsContainer,
            store: store, query: "anything", limit: 10)
        #expect(leg == nil)
    }
}
#endif
