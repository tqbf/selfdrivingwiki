import Foundation
import Testing
@testable import WikiFSCore

/// Phase 2 Tantivy cutover tests (plans/tantivy-search-sidecar.md §4.4).
///
/// Validates the `bm25Leg` injection seam on `WikiStore.searchSimilar*` (the
/// Option B design — see the doc comment on `WikiStore.searchSimilar`).
///
/// Post-#634 (FTS5 dropped): `bm25Leg` is the SOLE BM25 leg. A non-empty leg is
/// fused with the semantic cosine leg via `RankFusion.rrf`. With no chunk
/// embeddings seeded (the case below), the semantic leg is empty, so the fused
/// output == the BM25 leg's membership/order. A nil/empty leg yields no lexical
/// results; with the embedder unavailable under `swift test` (NLEmbedding is
/// app-gated), the output is empty too — the FTS5 fallback that previously made
/// nil-bm25Leg return matches is gone.
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

    // MARK: - bm25Leg supplied → fused output equals the leg (pages)

    @Test func bm25LegIsUsedWhenSuppliedForPages() throws {
        let store = try tempStore()
        // Seed two pages whose bodies would both match a "budget" query.
        let a = try store.createPage(title: "Finance A")
        try store.updatePage(id: a.id, title: a.title, body: "budget forecast ten", lastEditedBy: nil)
        let b = try store.createPage(title: "Finance B")
        try store.updatePage(id: b.id, title: b.title, body: "budget forecast twenty", lastEditedBy: nil)

        // Post-#634: a `nil` leg returns NO pages (FTS5 fallback removed; no
        // cosine query blob under `swift test` either). This is the #634
        // contract — `searchSimilar` is empty without an explicit BM25 leg.
        let noLeg = try store.searchSimilar(query: "budget", limit: 10, bm25Leg: nil)
        #expect(noLeg.isEmpty)

        // Supply a bm25 leg containing ONLY `b`, in first position. With no
        // page_chunks seeded the semantic leg is empty, so the fused output
        // must equal exactly this leg (the store didn't augment it — the
        // caller-supplied leg IS the lexical result).
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

    // MARK: - nil / empty leg → no BM25 leg (the #634 contract)

    @Test func nilLegYieldsNoLexicalResults() throws {
        // Post-#634 (#634): a `nil` bm25Leg means no BM25 leg at all. The store
        // no longer queries FTS5 (it's gone). Combined with no cosine leg under
        // `swift test`, the result is empty — the documented #634 behavior.
        let store = try tempStore()
        let p = try store.createPage(title: "Solitude")
        try store.updatePage(id: p.id, title: p.title, body: "kappa keyword common", lastEditedBy: nil)
        let hits = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: nil)
        #expect(hits.isEmpty)
    }

    @Test func emptyLegTreatedAsNoLeg() throws {
        // Post-#634: an empty leg is treated identically to `nil` — no BM25 leg.
        // (Pre-#634 this differed: `[]` meant "Tantivy ran and found nothing"
        // while `nil` meant "fall back to FTS5"; without FTS5 the distinction
        // collapses and both mean "no lexical results".)
        let store = try tempStore()
        let p = try store.createPage(title: "Solitude")
        try store.updatePage(id: p.id, title: p.title, body: "kappa keyword common", lastEditedBy: nil)
        let hits = try store.searchSimilar(query: "kappa", limit: 10, bm25Leg: [])
        #expect(hits.isEmpty)
    }

    // MARK: - Chats mirror (leg pass-through)

    @Test func bm25LegUsedForChats() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Q1 Planning")
        _ = try store.appendChatMessages(chatID: chat.id, events: [
            .assistantText("budget discussion for Q1"),
        ])

        // Post-#634: no leg → no lexical results (FTS5 fallback gone).
        let noLeg = try store.searchSimilarChats(query: "budget", limit: 10, bm25Leg: nil)
        #expect(noLeg.isEmpty)

        // Fabricated leg (same id) — store uses it, fuses with the (empty
        // under swift test) cosine leg, returns the leg unchanged.
        let leg = [ChatSummary(
            id: chat.id, kind: chat.kind, title: chat.title,
            createdAt: chat.createdAt, updatedAt: chat.updatedAt,
            messageCount: chat.messageCount, summary: nil, summaryAt: nil)]
        let fused = try store.searchSimilarChats(query: "budget", limit: 10, bm25Leg: leg)
        #expect(fused.count == 1)
        #expect(fused.first?.id == chat.id)
    }
}
