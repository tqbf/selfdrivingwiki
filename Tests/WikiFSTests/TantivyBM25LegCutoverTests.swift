import Foundation
import Testing
@testable import WikiFSCore

/// Phase 2 Tantivy cutover tests (plans/tantivy-search-sidecar.md §4.4).
///
/// Validates the `bm25Leg` injection seam on `WikiStore.searchSimilar*` (the
/// Option B design — see the doc comment on `WikiStore.searchSimilar`):
///
/// 1. When a non-empty `bm25Leg` is supplied, the store uses it INSTEAD of FTS5,
///    and the result reflects the leg's membership/order. With no chunk
///    embeddings seeded, the semantic cosine leg is empty, so the fused output
///    == the BM25 leg (deterministic — `RankFusion.rrf` of one non-empty + one
///    empty list returns the non-empty list's order).
/// 2. When `bm25Leg` is `nil`, the store falls back to FTS5 (legacy path).
/// 3. An empty `bm25Leg` (`[]`) is treated like `nil` (FTS5 fallback).
///
/// Store-level tests (no Tantivy index, no model, no event bus) → fast CI tier.
/// They exercise the default backend (`StoreBackend.current.makeStore`) directly.
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

    // MARK: - bm25Leg supplied → used instead of FTS5 (pages)

    @Test func bm25LegIsUsedWhenSuppliedForPages() throws {
        let store = try tempStore()
        // Seed two pages whose bodies would both match FTS5 for "budget".
        let a = try store.createPage(title: "Finance A")
        try store.updatePage(id: a.id, title: a.title, body: "budget forecast ten", lastEditedBy: nil)
        let b = try store.createPage(title: "Finance B")
        try store.updatePage(id: b.id, title: b.title, body: "budget forecast twenty", lastEditedBy: nil)

        // Legacy FTS5 path (nil leg) — both match.
        let fts = try store.searchSimilar(query: "budget", limit: 10, bm25Leg: nil)
        #expect(fts.count == 2)

        // Supply a bm25 leg containing ONLY `b`, in first position. With no
        // page_chunks seeded the semantic leg is empty, so the fused output must
        // equal exactly this leg (the store didn't query FTS5 at all — confirms
        // the leg REPLACED the FTS5 leg, not augmented it).
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

    // MARK: - nil / empty → FTS5 fallback (pages)

    @Test func nilLegFallsBackToFTS5() throws {
        let store = try tempStore()
        let p = try store.createPage(title: "Solitude")
        try store.updatePage(id: p.id, title: p.title, body: "kappa keyword common", lastEditedBy: nil)
        // nil bm25Leg → legacy path. Should find the page via FTS5.
        let hits = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: nil)
        #expect(hits.count == 1)
    }

    @Test func emptyLegFallsBackToFTS5() throws {
        let store = try tempStore()
        let p = try store.createPage(title: "Solitude")
        try store.updatePage(id: p.id, title: p.title, body: "kappa keyword common", lastEditedBy: nil)
        // An empty leg is treated as "no leg" (FTS5 fallback), NOT as "no BM25
        // results" — otherwise passing [] would silently zero out the BM25 leg
        // even when FTS5 has matches.
        let hits = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: [])
        #expect(hits.count == 1)
    }

    @Test func defaultArgBehaviorPreserved() throws {
        // #637: the 2-arg store overload is now deprecated — `bm25Leg: nil`
        // is the explicit form for "no Tantivy leg, run FTS5" (the legacy
        // Phase 2 behavior the model's sync wrapper still uses, and the
        // FTS5 fallback path #634 will retire). Tests pass `nil` explicitly
        // so the deprecation warning doesn't fire under `-warnings-as-errors`.
        let store = try tempStore()
        let p = try store.createPage(title: "Default Arg")
        try store.updatePage(id: p.id, title: p.title, body: "kappa keyword common", lastEditedBy: nil)
        let hits = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: nil)
        #expect(hits.count == 1)
    }

    // MARK: - Chats mirror (FTS sidecar populated by appendChatMessages)

    @Test func bm25LegUsedForChats() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Q1 Planning")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("budget discussion for Q1"),
        ])

        // FTS5 path finds the chat via the chat_search sidecar.
        let fts = try store.searchSimilarChats(query: "budget", limit: 10, bm25Leg: nil)
        #expect(fts.count == 1)

        // Fabricated leg (same id) — store uses it, not FTS5.
        let leg = [ChatSummary(
            id: chat.id, kind: chat.kind, title: chat.title,
            createdAt: chat.createdAt, updatedAt: chat.updatedAt,
            messageCount: chat.messageCount, summary: nil, summaryAt: nil)]
        let fused = try store.searchSimilarChats(query: "budget", limit: 10, bm25Leg: leg)
        #expect(fused.count == 1)
        #expect(fused.first?.id == chat.id)
    }
}
