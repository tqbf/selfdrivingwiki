import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// Pure-Swift cosine similarity over the L2-normalized Float32 embeddings stored
/// in `page_chunks`/`source_chunks`/`chat_chunks`. This is the MIT-clean
/// replacement for the prior vendored C scalar (issue #628 — the entire C
/// target is retired; this is the Swift replacement).
///
/// Because every stored vector is **L2-normalized at write time** (see the
/// `Embedder` protocol contract — `MiniLMEmbedder` re-normalizes via `vDSP_svesq`
/// after pooling, and `NLEmbedder` returns unit-length vectors from
/// `NLEmbedding.vector(for:)`), cosine similarity == dot product:
///
///     cosine_distance = 1 − cos(a, b) = 1 − (a·b)/(|a||b|)
///                  ⟶  1 − (a·b)        (unit vectors)
///
/// so "min distance per doc, ascending" ⟺ max dot per doc, descending. The
/// fused output fed to `RankFusion.rrf` is rank-order-identical to the prior
/// SQL path for the same embeddings — `RankFusion.rrf` consumes rank order only,
/// so the input shape is unchanged.
///
/// **Scale scope (issue #630 rejected a SIMD C replacement):** pulling all chunk
/// rows into Swift memory is fine at the current scale (~few thousand chunks ×
/// 512 × 4 B ≈ a few MB; the embedding-model call dominates latency well below
/// ~100k vectors). If/when a single wiki exceeds ~50–100k chunks, revisit with a
/// pre-filter (Tantivy/BM25 candidate set) or an indexed vector store.
public enum VectorCosine {

    /// Decode a stored `embedding` BLOB (little-endian Float32, contiguously
    /// packed) to `[Float]`. Mirrors the encode side
    /// (`EmbeddingService.embeddingBlob(for:)`: `floats.withUnsafeBytes { Data($0) }`).
    ///
    /// Returns `nil` if the byte count is not a positive multiple of 4 (a
    /// corrupt/truncated blob shouldn't crash the search path — the caller logs
    /// the skip via `DebugLog`).
    public static func decode(_ data: Data) -> [Float]? {
        let bytes = data.count
        guard bytes > 0, bytes % MemoryLayout<Float>.size == 0 else { return nil }
        let count = bytes / MemoryLayout<Float>.size
        return data.withUnsafeBytes { ptr -> [Float]? in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }

    /// Dot product of two equal-length vectors (== cosine similarity for unit
    /// vectors). Uses vDSP for SIMD throughput. Returns 0 on length mismatch
    /// (defensive — should not happen given the `Embedder` invariant; the caller
    /// logs dimension mismatches via `DebugLog`).
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count > 0, a.count == b.count else { return 0 }
        var sum: Float = 0
        #if canImport(Accelerate)
        vDSP_dotpr(a, 1, b, 1, &sum, vDSP_Length(a.count))
        #else
        // Pure-Swift fallback — identical result, slower without SIMD. Acceptable on
        // Linux where embeddings are unavailable anyway (isAvailable == false → dot
        // is dormant). See VectorCosine.swift:22-26 re: SIMD only mattering >~50-100k.
        for i in 0..<a.count { sum += a[i] * b[i] }
        #endif
        return sum
    }

    /// Best-chunk-per-doc ranker — the Swift equivalent of the SQL shape:
    ///
    ///     SELECT doc_id, MIN(<cosine distance>(embedding, ?)) AS best
    ///     FROM <doc>_chunks GROUP BY doc_id
    ///     ORDER BY best ASC LIMIT ?;
    ///
    /// For unit-norm vectors, MIN(1 − dot) per doc ⟺ MAX(dot) per doc, and
    /// ascending-distance order ⟺ descending-similarity order. So this computes
    /// `dot(query, chunk)` per chunk, keeps the max per doc, sorts
    /// most-similar-first, and truncates to `pool`.
    ///
    /// - Parameters:
    ///   - candidates: `(docID, embedding)` for every chunk row in the table
    ///     (read off-main via the existing `dbWriter.read` pool reader).
    ///   - query: the L2-normalized query vector (decoded from the same blob the
    ///     SQL path bound as `?`).
    ///   - pool: how many top docs to keep (matches the SQL `LIMIT ?`, i.e.
    ///     `max(limit * 2, limit)`).
    /// - Returns: `(docID, similarity)` pairs ranked most-similar-first,
    ///   truncated to `pool`. Docs whose blob fails to decode or whose dimension
    ///   doesn't match `query` are skipped (the caller logs skips via
    ///   `DebugLog`).
    public static func rankBestChunkPerDoc(
        candidates: [(docID: String, embedding: Data)],
        query: [Float],
        pool: Int
    ) -> [(docID: String, similarity: Float)] {
        var best: [String: Float] = [:]
        best.reserveCapacity(candidates.count)
        for c in candidates {
            guard let v = decode(c.embedding), v.count == query.count else { continue }
            let sim = dot(query, v)            // higher == more similar
            // Keep the MAX similarity per doc (== MIN distance in the SQL path).
            if sim > (best[c.docID] ?? -.infinity) { best[c.docID] = sim }
        }
        return best
            .sorted { $0.value > $1.value }    // most-similar-first (== best ASC)
            .prefix(pool)
            .map { (docID: $0.key, similarity: $0.value) }
    }
}
