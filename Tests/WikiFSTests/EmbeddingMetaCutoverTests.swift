import Foundation
import Testing
@testable import WikiFSCore

/// Verifies AC3: the embedding_meta-driven dimension-cutover wipe.
///
/// Uses `activeIdentifierOverride` so tests never touch the real
/// EmbeddingService, which does not load a model in tests.
struct EmbeddingMetaCutoverTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-cutover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - Fresh DB seeds nlembedding-512

    @Test func freshDBSeedsLegacyEmbedderIdentifier() throws {
        let store = try tempStore()
        let stored = store.pragmaValue("user_version")
        #expect(stored == "\(GRDBWikiStore.schemaVersion)")
        // The historical identifier stays in fresh DBs so old 512-dimensional
        // chunks are replaced when MiniLM first loads.
        store.ensureEmbedderConsistency(activeIdentifierOverride: "nlembedding-512")
        // Source added after the no-op must still have no chunks (never embedded).
        let summary = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        let missing = store.missingSourceEmbeddingWork()
        #expect(missing.contains(where: { $0.id == summary.id }))
    }

    // MARK: - Cutover wipes chunks on identifier mismatch

    @Test func cutoverFromLegacyEmbeddingsToMiniLMWipesSourceChunks() throws {
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

    // MARK: - Non-app open must not wipe (issue #165)

    /// A non-app process (`wikictl`, the File Provider extension, tests) opening
    /// the store writable must NOT wipe chunks or rewrite `embedding_meta`, even
    /// when the stored identifier differs from the active model. A non-app
    /// process without a model must keep the persisted chunk index.
    @Test func nonAppOpenDoesNotWipeChunksOnIdentifierMismatch() throws {
        let store = try tempStore()

        // Fresh seed is nlembedding-512. Switch meta to minilm-384 via the
        // override path while there are no chunks to wipe (simulates the app
        // having embedded with MiniLM on a prior launch).
        store.ensureEmbedderConsistency(activeIdentifierOverride: EmbeddingService.miniLMIdentifier)

        // "App" embeds a source's chunks.
        let summary = try store.addSource(filename: "report.pdf", data: Data("%PDF".utf8))
        try store.storeSourceChunks(id: summary.id, chunks: [Data(repeating: 0, count: 384 * 4)])
        #expect(!store.missingSourceEmbeddingWork().contains(where: { $0.id == summary.id }),
                "source should have chunks after the app embeds")

        // wikictl (CLI) opens the same DB writable. Tests run outside an .app
        // bundle, so this no-override call is exactly the CLI path:
        // A CLI open has no loaded model and must keep the stored chunks.
        store.ensureEmbedderConsistency()

        #expect(!store.missingSourceEmbeddingWork().contains(where: { $0.id == summary.id }),
                "non-app open must not wipe chunks the app embedded")
    }
}
