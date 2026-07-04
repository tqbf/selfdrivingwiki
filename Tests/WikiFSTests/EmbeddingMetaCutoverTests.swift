import Foundation
import Testing
@testable import WikiFSCore

/// Verifies AC3: the embedding_meta-driven dimension-cutover wipe.
///
/// Uses `activeIdentifierOverride` so tests never touch the real
/// EmbeddingService (which is app-bundle-gated and does NLEmbedder in tests).
struct EmbeddingMetaCutoverTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-cutover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - Fresh DB seeds nlembedding-512

    @Test func freshDBSeedsNLEmbedderIdentifier() throws {
        let store = try tempStore()
        let stored = store.pragmaValue("user_version")
        #expect(stored == "18")
        // ensureEmbedderConsistency with the default identifier (nlembedding-512)
        // is a no-op: the seed matches, so nothing is wiped.
        store.ensureEmbedderConsistency(activeIdentifierOverride: NLEmbedder.identifier)
        // Source added after the no-op must still have no chunks (never embedded).
        let summary = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        let missing = store.missingSourceEmbeddingWork()
        #expect(missing.contains(where: { $0.id == summary.id }))
    }

    // MARK: - Cutover wipes chunks on identifier mismatch

    @Test func cutoverFromNLEmbedderToMiniLMWipesSourceChunks() throws {
        let store = try tempStore()

        // Store a dummy chunk for a real source (FK requires the source row to exist).
        let summary = try store.addSource(filename: "report.pdf", data: Data("%PDF".utf8))
        let fakeChunk = Data(repeating: 0, count: 512 * 4)   // 512-dim float blob
        try store.storeSourceChunks(id: summary.id, chunks: [fakeChunk])

        // Verify chunk is stored (source NOT in missing-work list).
        let beforeMissing = store.missingSourceEmbeddingWork()
        #expect(!beforeMissing.contains(where: { $0.id == summary.id }),
                "source should have chunks before cutover")

        // Simulate switching to MiniLM: embedding_meta stored nlembedding-512 (seed),
        // but we pass minilm-384 as the active identifier → mismatch → wipe.
        store.ensureEmbedderConsistency(activeIdentifierOverride: EmbeddingService.miniLMIdentifier)

        // After cutover, source_chunks is empty → source reappears in missing-work.
        let afterMissing = store.missingSourceEmbeddingWork()
        #expect(afterMissing.contains(where: { $0.id == summary.id }),
                "source should reappear in missing-work after cutover wipe")
    }
}
