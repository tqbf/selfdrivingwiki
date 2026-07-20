import Foundation
import Testing
import WikiFSSearch

/// Pure-math unit tests for ``VectorCosine`` — the Swift-side replacement for
/// the prior vendored C cosine scalar (issue #628). No DB, no model, no
/// GRDB — just `[Float]` / `Data` math.
///
/// The correctness anchor is ``goldenOrderingMatchesPriorSqlPath``: for unit
/// vectors, `cosine_distance(a, b) = 1 − cos(a, b) = 1 − dot(a, b)`. The doc
/// ordering from `rankBestChunkPerDoc` MUST equal the prior SQL path's
/// "min cosine-distance per doc, ascending" shape. Provable in pure Swift with
/// no C dependency.
@Suite
struct VectorCosineTests {

    // MARK: - decode

    @Test func decodeRoundTripsEmbeddingServiceBlob() throws {
        // The encode side is `floats.withUnsafeBytes { Data($0) }` (raw LE Float32).
        let original: [Float] = [0.1, -0.2, 0.3, 1.5, -0.0001]
        let blob = original.withUnsafeBytes { Data($0) }
        let decoded = try #require(VectorCosine.decode(blob))
        #expect(decoded.count == original.count)
        for (i, v) in original.enumerated() {
            #expect(abs(decoded[i] - v) < 1e-6, "decoded[\(i)] mismatch")
        }
    }

    @Test func decodeReturnsNilForEmptyBlob() {
        #expect(VectorCosine.decode(Data()) == nil)
    }

    @Test func decodeReturnsNilForNonMultipleOfFour() {
        // 5 bytes is not a multiple of 4 — defensive guard.
        #expect(VectorCosine.decode(Data([0x01, 0x02, 0x03, 0x04, 0x05])) == nil)
    }

    @Test func decodeHandlesSingleFloat() throws {
        let blob = Data([0x00, 0x00, 0x80, 0x3F])  // 1.0 in LE Float32
        let decoded = try #require(VectorCosine.decode(blob))
        #expect(decoded == [1.0])
    }

    // MARK: - dot

    @Test func dotOfOrthogonalVectorsIsZero() {
        // e1 = (1, 0), e2 = (0, 1) — orthogonal unit vectors.
        #expect(abs(VectorCosine.dot([1, 0], [0, 1])) < 1e-6)
    }

    @Test func dotOfIdenticalUnitVectorsIsOne() {
        let v: [Float] = [0.6, 0.8]  // already unit-norm: 0.36 + 0.64 = 1.0
        #expect(abs(VectorCosine.dot(v, v) - 1.0) < 1e-6)
    }

    @Test func dotOfOppositeVectorsIsMinusOne() {
        let v: [Float] = [0.6, 0.8]
        #expect(abs(VectorCosine.dot(v, [-0.6, -0.8]) - (-1.0)) < 1e-6)
    }

    @Test func dotReturnsZeroOnLengthMismatch() {
        // Defensive — different lengths shouldn't crash.
        #expect(VectorCosine.dot([1, 2, 3], [1, 2]) == 0)
    }

    @Test func dotReturnsZeroOnEmptyInput() {
        #expect(VectorCosine.dot([], []) == 0)
    }

    @Test func dotMatchesNaiveSum() {
        // Cross-check vDSP_dotpr against a textbook `zip(*).reduce(+)`.
        let a: [Float] = [0.12, -0.34, 0.56, 0.78, -0.91, 0.23, -0.45]
        let b: [Float] = [0.98, 0.76, -0.54, 0.32, 0.10, -0.88, 0.66]
        let expected = zip(a, b).map(*).reduce(Float(0), +)
        let actual = VectorCosine.dot(a, b)
        #expect(abs(actual - expected) < 1e-5)
    }

    @Test func dotOnL2NormalizedVectorsEqualsCosine() {
        // For unit vectors, dot == cosine. Take a few non-unit vectors, L2-normalize
        // them in-test, then dot — equals the textbook cosine of the originals.
        let a: [Float] = [3.0, 4.0]                // |a| = 5
        let b: [Float] = [4.0, -3.0]               // |b| = 5, cos(a,b) = (12−12)/25 = 0
        let na = Self.normalize(a)
        let nb = Self.normalize(b)
        #expect(abs(VectorCosine.dot(na, nb) - 0.0) < 1e-6)

        let c: [Float] = [1.0, 2.0, 3.0]
        let d: [Float] = [2.0, 2.0, 2.0]
        // cos(c,d) = (2+4+6)/(sqrt(14)*sqrt(12)) = 12/sqrt(168) ≈ 0.9258
        let expectedCosine: Float = Float(12.0 / (14.0.squareRoot() * 12.0.squareRoot()))
        let nc = Self.normalize(c)
        let nd = Self.normalize(d)
        #expect(abs(VectorCosine.dot(nc, nd) - expectedCosine) < 1e-5)
    }

    // MARK: - rankBestChunkPerDoc

    /// Helper: encode `[Float]` → the same LE Float32 BLOB the store writes.
    private func blob(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    @Test func rankPicksBestChunkPerDoc() {
        // doc "A" has two chunks: one near-miss (sim 0.3) and one exact (sim 1.0).
        // The exact chunk must win — best-chunk-per-doc.
        let query: [Float] = [1.0, 0.0]
        let aExact = blob([1.0, 0.0])              // sim 1.0
        let aNear = blob([0.3, 0.95])              // sim ≈ 0.3
        let b = blob([0.0, 1.0])                   // sim 0.0 (orthogonal)
        let candidates: [(docID: String, embedding: Data)] = [
            ("A", aNear), ("A", aExact), ("B", b),
        ]
        let ranked = VectorCosine.rankBestChunkPerDoc(candidates: candidates, query: query, pool: 10)
        #expect(ranked.map(\.docID) == ["A", "B"])
        #expect(abs(ranked[0].similarity - 1.0) < 1e-6)
    }

    @Test func rankOrdersMostSimilarFirst() {
        let query: [Float] = [1.0, 0.0]
        let candidates: [(docID: String, embedding: Data)] = [
            ("low",   blob([0.0, 1.0])),           // sim 0.0
            ("high",  blob([1.0, 0.0])),           // sim 1.0
            ("mid",   blob([0.7071, 0.7071])),     // sim ≈ 0.7071
        ]
        let ranked = VectorCosine.rankBestChunkPerDoc(candidates: candidates, query: query, pool: 10)
        #expect(ranked.map(\.docID) == ["high", "mid", "low"])
    }

    @Test func rankTruncatesToPool() {
        let query: [Float] = [1.0]
        // 5 docs with descending sims; pool=2 truncates to top 2.
        let candidates: [(docID: String, embedding: Data)] = [
            ("d5", blob([0.1])), ("d4", blob([0.2])), ("d3", blob([0.3])),
            ("d2", blob([0.4])), ("d1", blob([0.5])),
        ]
        let ranked = VectorCosine.rankBestChunkPerDoc(candidates: candidates, query: query, pool: 2)
        #expect(ranked.count == 2)
        #expect(ranked.map(\.docID) == ["d1", "d2"])
    }

    @Test func rankSkipsUndecodableBlobButKeepsDocViaGoodChunk() {
        // doc "A" has a malformed blob (1 byte) AND a good chunk — the good chunk
        // must still rank the doc (decode-failure is per-chunk, not per-doc).
        let query: [Float] = [1.0, 0.0]
        let candidates: [(docID: String, embedding: Data)] = [
            ("A", Data([0xFF])),                    // malformed: not a multiple of 4
            ("A", blob([1.0, 0.0])),                // good — sim 1.0
        ]
        let ranked = VectorCosine.rankBestChunkPerDoc(candidates: candidates, query: query, pool: 10)
        #expect(ranked.map(\.docID) == ["A"])
        #expect(abs(ranked[0].similarity - 1.0) < 1e-6)
    }

    @Test func rankDropsDocWhenAllBlobsUndecodable() {
        let query: [Float] = [1.0, 0.0]
        let candidates: [(docID: String, embedding: Data)] = [
            ("A", Data([0xFF])),                    // malformed
            ("B", blob([1.0, 0.0])),                // good
        ]
        let ranked = VectorCosine.rankBestChunkPerDoc(candidates: candidates, query: query, pool: 10)
        #expect(ranked.map(\.docID) == ["B"])
    }

    @Test func rankSkipsDimensionMismatch() {
        // A stored blob whose dimension doesn't match the query (shouldn't happen
        // given the embedding_meta cutover — but the helper is defensive).
        let query: [Float] = [1.0, 0.0]
        let candidates: [(docID: String, embedding: Data)] = [
            ("A", blob([1.0, 0.0, 0.0])),           // 3-dim vs 2-dim query
            ("B", blob([1.0, 0.0])),                // 2-dim, matches
        ]
        let ranked = VectorCosine.rankBestChunkPerDoc(candidates: candidates, query: query, pool: 10)
        #expect(ranked.map(\.docID) == ["B"])
    }

    @Test func rankEmptyCandidatesReturnsEmpty() {
        let ranked = VectorCosine.rankBestChunkPerDoc(
            candidates: [], query: [1.0, 0.0], pool: 10)
        #expect(ranked.isEmpty)
    }

    // MARK: - Golden equivalence: Swift-dot ordering == prior SQL-path ordering

    @Test func goldenOrderingMatchesPriorSqlPath() {
        // The correctness anchor. The prior SQL path computed
        // `MIN(cosine_distance(embedding, ?)) GROUP BY doc ORDER BY best ASC`
        // — i.e. the doc with the SMALLEST (1 − dot) per doc, then
        // most-similar-first. Swift computes MAX dot per doc, sorts
        // similarity-desc. The doc ID sequence MUST be identical.
        //
        // We construct the same candidate set both paths would see and assert
        // they produce the same ordering — no live C extension needed (the math
        // equivalence is provable in pure Swift).
        let query: [Float] = [0.8, 0.6]  // unit-norm: 0.64 + 0.36 = 1.0

        // 4 docs, some with multiple chunks, all unit-norm.
        let docs: [(id: String, chunks: [[Float]])] = [
            ("alpha", [[0.8, 0.6], [0.1, 0.995]]),         // chunk0 sim=1.0
            ("beta",  [[0.6, 0.8], [-0.6, 0.8]]),          // best sim=0.96
            ("gamma", [[0.0, 1.0]]),                       // sim=0.6
            ("delta", [[-0.8, -0.6]]),                     // sim=-1.0
        ]
        let candidates: [(docID: String, embedding: Data)] = docs.flatMap { d in
            d.chunks.map { (d.id, blob($0)) }
        }

        // Swift side.
        let swiftRanking = VectorCosine.rankBestChunkPerDoc(
            candidates: candidates, query: query, pool: 10).map(\.docID)

        // Prior-SQL-equivalent side: for each doc, MIN(1 − dot) over chunks
        // (== MAX dot), then sort ascending by (1 − best dot) — i.e. descending
        // by dot.
        var bestDotByDoc: [String: Float] = [:]
        for d in docs {
            var best: Float = -.infinity
            for chunk in d.chunks {
                let dot = zip(query, chunk).map(*).reduce(Float(0), +)
                if dot > best { best = dot }
            }
            bestDotByDoc[d.id] = best
        }
        let priorSqlRanking = bestDotByDoc.sorted { $0.value > $1.value }.map(\.key)

        // The two orderings MUST agree.
        #expect(swiftRanking == priorSqlRanking, "Swift dot ordering must match the prior SQL-path ordering")
        // Sanity: the actual order should be alpha > beta > gamma > delta.
        #expect(swiftRanking == ["alpha", "beta", "gamma", "delta"])
    }

    // MARK: - Helpers

    /// L2-normalize a vector in-test (mirrors `MiniLMEmbedder`'s `vDSP_svesq` step).
    private static func normalize(_ v: [Float]) -> [Float] {
        let sumSq = v.map { $0 * $0 }.reduce(Float(0), +)
        let nrm = sumSq.squareRoot()
        return nrm > 0 ? v.map { $0 / nrm } : v
    }
}
