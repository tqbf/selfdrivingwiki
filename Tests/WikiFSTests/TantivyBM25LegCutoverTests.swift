import Foundation
import Testing
@testable import WikiFSCore

/// Tantivy BM25 leg cutover tests (plans/tantivy-search-sidecar.md §4.4).
///
/// Validates the `bm25Leg` injection seam on `WikiStore.searchSimilar*` (the
/// Option B design — see the doc comment on `WikiStore.searchSimilar`):
///
/// 1. When a non-empty `bm25Leg` is supplied, the store uses it as the sole
///    BM25 leg, and the result reflects the leg's membership/order. With no
///    chunk embeddings seeded, the semantic cosine leg is empty, so the fused
///    output == the BM25 leg (deterministic — `RankFusion.rrf` of one
///    non-empty + one empty list returns the non-empty list's order).
/// 2. A `nil`/empty leg means "no BM25 leg" (#634 dropped FTS5). With no
///    chunk embeddings under `swift test`, the result is empty.
///
/// Store-level tests (no Tantivy index, no model, no event bus) → fast CI tier.
/// They exercise the default backend (`StoreBackend.current.makeStore` directly).
@Suite struct TantivyBM25LegCutoverTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tantivy-leg-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> any WikiStore {
        try StoreBackend.current.makeStore(databaseURL: tempDatabaseURL())
    }

    // MARK: - bm25Leg supplied → used as the BM25 leg (pages)

    @Test func bm25LegIsUsedWhenSuppliedForPages() throws {
        let store = try tempStore()
        // Seed two pages whose bodies would both contain "budget".
        let a = try store.createPage(title: "Finance A")
        try store.updatePage(id: a.id, title: a.title, body: "budget forecast ten", lastEditedBy: nil)
        let b = try store.createPage(title: "Finance B")
        try store.updatePage(id: b.id, title: b.title, body: "budget forecast twenty", lastEditedBy: nil)

        // No BM25 leg, no vec under swift test → empty.
        let noLeg = try store.searchSimilar(query: "budget", limit: 10, bm25Leg: nil)
        #expect(noLeg.isEmpty)

        // Supply a bm25 leg containing ONLY `b`, in first position. With no
        // page_chunks seeded the semantic leg is empty, so the fused output must
        // equal exactly this leg (the store didn't run any other BM25 path).
        let leg = [WikiPageSummary(
            id: b.id, title: b.title,
            updatedAt: b.updatedAt, createdAt: b.createdAt)]
        let fused = try store.searchSimilar(query: "budget", limit: 10, bm25Leg: leg)
        #expect(fused.count == 1)
        #expect(fused.first?.id == b.id)
    }

    @Test func bm25LegPreservesRankOrder() throws {
        let store = try tempStore()
        let a = try store.createPage(title: "P Alpha")
        try store.updatePage(id: a.id, title: a.title, body: "kappa keyword common", lastEditedBy: nil)
        let b = try store.createPage(title: "P Beta")
        try store.updatePage(id: b.id, title: b.title, body: "kappa keyword common", lastEditedBy: nil)
        let c = try store.createPage(title: "P Gamma")
        try store.updatePage(id: c.id, title: c.title, body: "kappa keyword common", lastEditedBy: nil)

        // Fabricate a best-first order [c, a, b] (Tantivy would produce a real
        // score-based order; here we assert the store preserves whatever order
        // the leg declares). Empty semantic leg → fused == leg.
        let leg = [c, a, b].map {
            WikiPageSummary(id: $0.id, title: $0.title,
                            updatedAt: $0.updatedAt, createdAt: $0.createdAt)
        }
        let fused = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: leg)
        #expect(fused.map(\.id) == [c.id, a.id, b.id])
    }

    // MARK: - nil / empty → no BM25 leg (cosine-only / empty under swift test)

    @Test func nilLegHasNoBm25Leg() throws {
        let store = try tempStore()
        let p = try store.createPage(title: "Solitude")
        try store.updatePage(id: p.id, title: p.title, body: "kappa keyword common", lastEditedBy: nil)
        // nil bm25Leg → no BM25 leg. Under swift test vec is unavailable too,
        // so the result is empty (no FTS5 fallback as of #634).
        let hits = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: nil)
        #expect(hits.isEmpty)
    }

    @Test func emptyLegHasNoBm25Leg() throws {
        let store = try tempStore()
        let p = try store.createPage(title: "Solitude")
        try store.updatePage(id: p.id, title: p.title, body: "kappa keyword common", lastEditedBy: nil)
        // An empty leg is treated the same as `nil` (no BM25 leg, not "no BM25
        // results" — important so passing [] doesn't ambiguously mean either).
        let hits = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: [])
        #expect(hits.isEmpty)
    }

    // MARK: - Chats mirror (leg-supplied)

    @Test func bm25LegUsedForChats() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Q1 Planning")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("budget discussion for Q1"),
        ])

        // No BM25 leg → no lexical signal under swift test.
        let noLeg = try store.searchSimilarChats(query: "budget", limit: 10, bm25Leg: nil)
        #expect(noLeg.isEmpty)

        // Fabricated leg (same id) — store uses it as the BM25 leg.
        let leg = [ChatSummary(
            id: chat.id, kind: chat.kind, title: chat.title,
            createdAt: chat.createdAt, updatedAt: chat.updatedAt,
            messageCount: chat.messageCount, summary: nil, summaryAt: nil)]
        let fused = try store.searchSimilarChats(query: "budget", limit: 10, bm25Leg: leg)
        #expect(fused.count == 1)
        #expect(fused.first?.id == chat.id)
    }
}
