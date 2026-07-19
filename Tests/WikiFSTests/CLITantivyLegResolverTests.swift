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
@Suite(.timeLimit(.minutes(5)))
struct CLITantivyLegResolverTests {

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

    private func tempStore(in container: URL, wikiID: String) throws -> GRDBWikiStore {
        let dbURL = container.appendingPathComponent("\(wikiID).sqlite", isDirectory: false)
        return try GRDBWikiStore(databaseURL: dbURL)
    }

    // MARK: - resolvePageLeg

    @Test func resolvePageLegReturnsNilWhenIndexEmpty() throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = "01TEST0001"
        let store = try tempStore(in: container, wikiID: wikiID)
        // No Tantivy index exists yet — `rebuildIfNeeded` was never called
        // (the app would normally kick it off in `TantivyShadowSync.start()`).
        // The resolver must return nil so the store falls back to FTS5
        // (the #637 contract — empty leg = no BM25 signal).
        let leg = CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "anything", limit: 10)
        #expect(leg == nil)
    }

    @Test func resolvePageLegReturnsIndexedPagesInBestFirstOrder() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = "01TEST0002"
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
        let leg = CLITantivyLegResolver.resolvePageLeg(
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
        let wikiID = "01TEST0003"
        let store = try tempStore(in: container, wikiID: wikiID)
        let page = try store.createPage(title: "Milton H. Erickson")
        try store.updatePage(id: page.id, title: "Milton H. Erickson",
                             body: "Milton H. Erickson was an American psychiatrist specializing in clinical hypnosis.")

        // Query with a one-character typo ("erikson" vs "erickson"). Fuzzy
        // matching (edit-distance 1) should still surface the page. The
        // resolver's internal `rebuildIfNeeded()` populates the index from
        // the store on first call.
        let leg = CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "erikson", limit: 10)
        #expect(leg != nil, "fuzzy match should find Erickson despite the typo")
        #expect(leg?.contains { $0.id == page.id } ?? false)
    }

    // MARK: - resolveSourceLeg

    @Test func resolveSourceLegReturnsIndexedSources() async throws {
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = "01TEST0004"
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

        let leg = CLITantivyLegResolver.resolveSourceLeg(
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
        let wikiID = "01TEST0005"
        let store = try tempStore(in: container, wikiID: wikiID)
        let chat = try store.createChat(kind: .edit, title: "Mars Colony")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("We discussed terraforming the Martian surface."),
        ])

        let leg = CLITantivyLegResolver.resolveChatLeg(
            wikiID: wikiID, containerDirectory: container,
            store: store, query: "terraforming", limit: 10)
        #expect(leg != nil)
        #expect(leg?.count == 1)
        #expect(leg?.first?.id == chat.id)
    }

    // MARK: - FTS5 fallback when no Tantivy service can be built

    @Test func resolvePageLegReturnsNilWhenServiceConstructionFails() throws {
        // Point the resolver at a container path that doesn't exist and can't
        // be created (a file in place of the container dir). `makeService`
        // catches the throw and returns nil — the store then falls back to
        // FTS5 (the #637 contract — Tantivy unavailable = no BM25 leg, not an
        // error).
        let fileAsContainer = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-tantivy-leg-blocker-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: fileAsContainer)
        defer { try? FileManager.default.removeItem(at: fileAsContainer) }

        // A real store the resolver can list pages from (won't be reached —
        // makeService throws first).
        let (container, fm) = try makeTempContainer()
        defer { try? fm.removeItem(at: container) }
        let wikiID = "01TEST0006"
        let store = try tempStore(in: container, wikiID: wikiID)

        let leg = CLITantivyLegResolver.resolvePageLeg(
            wikiID: wikiID, containerDirectory: fileAsContainer,
            store: store, query: "anything", limit: 10)
        #expect(leg == nil)
    }
}
