import Foundation
import Testing
@testable import WikiFSCore
import WikiFSSearch

/// Store-level integration tests for the Swift-side cosine semantic-search
/// path (issue #628). Exercises `searchSimilar` / `searchSimilarSources` /
/// `searchSimilarChats` end-to-end with hand-crafted unit vectors seeded via
/// `storePageChunks` / `storeSourceChunks` / `storeChatChunks`.
///
/// **Test seam:** `EmbeddingService.installTestEmbedder` (a `#if DEBUG` hook)
/// installs a ``StubEmbedder`` so the cosine path can run under `swift test`
/// without the app-gated NLEmbedding/MiniLM. The stub maps known query strings
/// to deterministic unit vectors, and the test seeds matching chunk embeddings
/// so the ranking is fully predictable.
///
/// These complement `VectorCosineTests` (pure math, no store) by proving the
/// full store read path — SQL join → decode → dot product → best-chunk-per-doc
/// → sort → `RankFusion.rrf` — works with real GRDB rows.
@Suite(.serialized)
struct SemanticSearchSwiftCosineTests {

    // MARK: - Stub embedder

    /// A minimal `Embedder` that returns pre-registered unit vectors for known
    /// query strings. Unregistered strings map to a fixed "unrelated" vector
    /// orthogonal to all test vectors. All vectors are 2-dim and unit-norm.
    private struct StubEmbedder: Embedder {
        static let identifier = "stub-test-2"
        let dimension = 2

        /// Known query strings → their unit vectors. The test seeds chunk
        /// embeddings that match these so rankings are predictable.
        private let vectors: [String: [Float]] = [
            "alpha":   [1.0, 0.0],
            "beta":    [0.0, 1.0],
            "mixed":   [0.7071, 0.7071],
        ]

        /// The "unrelated" vector — orthogonal to all test vectors so it never
        /// ranks above a matching doc.
        private let unrelated: [Float] = [-0.6, -0.8]

        func vector(for text: String) -> [Float]? {
            vectors[text] ?? unrelated
        }
    }

    /// Encode `[Float]` → raw LE Float32 BLOB (same as `EmbeddingService`).
    private func blob(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    // MARK: - Setup / teardown

    private func installStub() {
        EmbeddingService.installTestEmbedder(StubEmbedder())
    }

    private func resetEmbedder() {
        EmbeddingService.resetTestEmbedder()
    }

    // MARK: - Pages: searchSimilar

    @Test func searchSimilarPagesReturnsClosestMatchFirst() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let pageAlpha = try store.createPage(title: "Alpha Page")
        try store.storePageChunks(id: pageAlpha.id, chunks: [blob([1.0, 0.0])])
        let pageBeta = try store.createPage(title: "Beta Page")
        try store.storePageChunks(id: pageBeta.id, chunks: [blob([0.0, 1.0])])

        let hits = try store.searchSimilar(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.count == 2)
        #expect(hits.first?.id == pageAlpha.id)
    }

    @Test func searchSimilarPagesBestChunkPerDoc() throws {
        // Doc "A" has two chunks: a near-miss (sim=0.7071) and an exact match
        // (sim=1.0). The exact chunk must win — best-chunk-per-doc.
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let pageA = try store.createPage(title: "A")
        try store.storePageChunks(id: pageA.id, chunks: [
            blob([0.7071, 0.7071]),   // sim with [1,0] ≈ 0.7071
            blob([1.0, 0.0]),          // sim = 1.0 (exact)
        ])
        let pageB = try store.createPage(title: "B")
        try store.storePageChunks(id: pageB.id, chunks: [blob([0.0, 1.0])])

        let hits = try store.searchSimilar(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.first?.id == pageA.id)
    }

    @Test func searchSimilarPagesRespectsLimit() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        for i in 0..<5 {
            let p = try store.createPage(title: "Page \(i)")
            try store.storePageChunks(id: p.id, chunks: [blob([1.0, 0.0])])
        }
        let hits = try store.searchSimilar(query: "alpha", limit: 2, bm25Leg: nil)
        #expect(hits.count == 2)
    }

    @Test func searchSimilarPagesFusesWithBM25Leg() throws {
        // RRF fuses the semantic leg with a fabricated BM25 leg. A doc that
        // appears in both legs should rank higher than one in only one leg.
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let pageA = try store.createPage(title: "Alpha")
        try store.storePageChunks(id: pageA.id, chunks: [blob([1.0, 0.0])])
        let pageB = try store.createPage(title: "Beta")
        try store.storePageChunks(id: pageB.id, chunks: [blob([0.0, 1.0])])

        // pageB appears in BOTH legs (cosine + fabricated BM25), so it should
        // rank above pageA which appears only in cosine (even though pageA is
        // the cosine winner — RRF rewards dual-leg presence).
        let bm25Leg = [WikiPageSummary(
            id: pageB.id, title: pageB.title,
            updatedAt: pageB.updatedAt, createdAt: pageB.createdAt)]
        let hits = try store.searchSimilar(query: "alpha", limit: 10, bm25Leg: bm25Leg)
        // Both should be present.
        #expect(hits.count == 2)
        // pageB (dual-leg) ranks first due to RRF boosting.
        #expect(hits.first?.id == pageB.id)
    }

    @Test func searchSimilarPagesNoChunksReturnsBM25Only() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Empty")
        // No chunks seeded → cosine leg is empty → output equals BM25 leg.
        let bm25Leg = [WikiPageSummary(
            id: page.id, title: page.title,
            updatedAt: page.updatedAt, createdAt: page.createdAt)]
        let hits = try store.searchSimilar(query: "alpha", limit: 10, bm25Leg: bm25Leg)
        #expect(hits.count == 1)
        #expect(hits.first?.id == page.id)
    }

    @Test func searchSimilarPagesEmptyWhenNoChunksAndNoBM25() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        _ = try store.createPage(title: "Page")
        let hits = try store.searchSimilar(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.isEmpty)
    }

    @Test func searchSimilarPagesEmptyWhenEmbedderNotLoaded() throws {
        // Do NOT install the stub — embedder stays nil → cosine leg gated off.
        // No BM25 leg → empty result.
        let store = try TestStoreFactory.inMemory()
        let page = try store.createPage(title: "Alpha")
        try store.storePageChunks(id: page.id, chunks: [blob([1.0, 0.0])])
        let hits = try store.searchSimilar(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.isEmpty)
    }

    // MARK: - Sources: searchSimilarSources

    @Test func searchSimilarSourcesReturnsClosestMatchFirst() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let srcAlpha = try store.addSource(filename: "alpha.pdf", data: Data("%PDF alpha".utf8))
        try store.storeSourceChunks(id: srcAlpha.id, chunks: [blob([1.0, 0.0])])
        let srcBeta = try store.addSource(filename: "beta.pdf", data: Data("%PDF beta".utf8))
        try store.storeSourceChunks(id: srcBeta.id, chunks: [blob([0.0, 1.0])])

        let hits = try store.searchSimilarSources(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.count == 2)
        #expect(hits.first?.id == srcAlpha.id)
    }

    @Test func searchSimilarSourcesBestChunkPerDoc() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let srcA = try store.addSource(filename: "a.pdf", data: Data("%PDF aaa".utf8))
        try store.storeSourceChunks(id: srcA.id, chunks: [
            blob([0.7071, 0.7071]),
            blob([1.0, 0.0]),
        ])
        let srcB = try store.addSource(filename: "b.pdf", data: Data("%PDF bbb".utf8))
        try store.storeSourceChunks(id: srcB.id, chunks: [blob([0.0, 1.0])])

        let hits = try store.searchSimilarSources(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.first?.id == srcA.id)
    }

    @Test func searchSimilarSourcesEmptyWhenNoChunksAndNoBM25() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        _ = try store.addSource(filename: "x.pdf", data: Data("%PDF".utf8))
        let hits = try store.searchSimilarSources(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.isEmpty)
    }

    // MARK: - Chats: searchSimilarChats

    @Test func searchSimilarChatsReturnsClosestMatchFirst() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let chatA = try store.createChat(kind: .edit, title: "Chat Alpha")
        try store.storeChatChunks(id: chatA.id, chunks: [blob([1.0, 0.0])])
        let chatB = try store.createChat(kind: .edit, title: "Chat Beta")
        try store.storeChatChunks(id: chatB.id, chunks: [blob([0.0, 1.0])])

        let hits = try store.searchSimilarChats(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.count == 2)
        #expect(hits.first?.id == chatA.id)
    }

    @Test func searchSimilarChatsBestChunkPerDoc() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let chatA = try store.createChat(kind: .edit, title: "A")
        try store.storeChatChunks(id: chatA.id, chunks: [
            blob([0.7071, 0.7071]),
            blob([1.0, 0.0]),
        ])
        let chatB = try store.createChat(kind: .edit, title: "B")
        try store.storeChatChunks(id: chatB.id, chunks: [blob([0.0, 1.0])])

        let hits = try store.searchSimilarChats(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.first?.id == chatA.id)
    }

    @Test func searchSimilarChatsEmptyWhenNoChunksAndNoBM25() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        _ = try store.createChat(kind: .edit, title: "Chat")
        let hits = try store.searchSimilarChats(query: "alpha", limit: 10, bm25Leg: nil)
        #expect(hits.isEmpty)
    }

    @Test func searchSimilarChatsFusesWithBM25Leg() throws {
        installStub()
        defer { resetEmbedder() }

        let store = try TestStoreFactory.inMemory()
        let chatA = try store.createChat(kind: .edit, title: "Alpha")
        try store.storeChatChunks(id: chatA.id, chunks: [blob([1.0, 0.0])])
        let chatB = try store.createChat(kind: .edit, title: "Beta")
        try store.storeChatChunks(id: chatB.id, chunks: [blob([0.0, 1.0])])

        let bm25Leg = [ChatSummary(
            id: chatB.id, kind: chatB.kind, title: chatB.title,
            createdAt: chatB.createdAt, updatedAt: chatB.updatedAt,
            messageCount: 0, summary: nil, summaryAt: nil)]
        let hits = try store.searchSimilarChats(query: "alpha", limit: 10, bm25Leg: bm25Leg)
        #expect(hits.count == 2)
        // chatB (dual-leg) ranks first due to RRF boosting.
        #expect(hits.first?.id == chatB.id)
    }
}
