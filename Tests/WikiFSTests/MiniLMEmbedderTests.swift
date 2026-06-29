import Testing
import Foundation
import Accelerate
@testable import WikiFSCore

// Repo-root-relative resource loader (swift test runs from project root; resources
// are NOT declared in Package.swift). Requires the Phase 0 prepare step to have
// downloaded the model + exported the reference JSON.
private func resourcesURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MiniLMEmbedderTests.swift
        .deletingLastPathComponent()  // WikiFSTests/
        .deletingLastPathComponent()  // Tests/  → repo root
        .appendingPathComponent("Resources")
}

struct ReferenceEmbedding: Decodable {
    let text: String
    let embedding: [Float]
}

@Suite("MiniLMEmbedder")
struct MiniLMEmbedderTests {
    let embedder: MiniLMEmbedder
    let references: [ReferenceEmbedding]

    init() async throws {
        let res = resourcesURL()
        embedder = try await MiniLMEmbedder(
            modelDirectoryURL: res.appendingPathComponent("all-MiniLM-L6-v2"))
        let data = try Data(contentsOf: res.appendingPathComponent("all-MiniLM-L6-v2-reference-embeddings.json"))
        references = try JSONDecoder().decode([ReferenceEmbedding].self, from: data)
    }

    @Test("Output dimension is 384")
    func outputDimension() throws {
        let v = try #require(embedder.vector(for: "hello world"))
        #expect(v.count == 384)
    }

    @Test("Output is L2-normalized")
    func isL2Normalized() throws {
        let v = try #require(embedder.vector(for: "self-driving wiki embeddings"))
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        #expect(abs(sqrt(sumSq) - 1.0) < 0.001, "‖v‖₂ = \(sqrt(sumSq)), expected ≈ 1.0")
    }

    // AC1 — non-garbage (NOT a parity bar). Swift MLXEmbedders is a different
    // implementation from the Python mlx-embeddings proxy, so ≥0.999-vs-HF is not
    // expected; 0.95 rules out a real loading bug (garbage is ~0.17).
    @Test("Non-garbage: cosine >= 0.95 vs HF reference on all probes")
    func nonGarbageVsReference() throws {
        #expect(!references.isEmpty, "reference JSON missing — run tools/minilm-prepare/validate.py")
        for ref in references {
            let v = try #require(embedder.vector(for: ref.text),
                                 "vector(for:) returned nil for: \(ref.text)")
            let sim = cosineSimilarity(v, ref.embedding)
            #expect(sim >= 0.95,
                    "cosine \(String(format: "%.4f", sim)) < 0.95 for: \(ref.text.prefix(50)) — investigate Swift MLX loading")
        }
    }

    // AC1 — self-consistent (the property search depends on).
    @Test("Self-consistent: paraphrase pairs more similar than unrelated")
    func selfConsistent() throws {
        let paraphrase: [(String, String)] = [
            ("A self-driving car navigates roads autonomously.",
             "Autonomous vehicles drive themselves on public roads."),
            ("Semantic search finds documents by their meaning.",
             "Meaning-based retrieval returns relevant results without keyword matches."),
        ]
        let unrelated: [(String, String)] = [
            ("A self-driving car navigates roads autonomously.",
             "The recipe needs two cups of flour and a pinch of salt."),
            ("Semantic search finds documents by their meaning.",
             "The compiler failed to link the shared library."),
        ]
        let paraSims = try paraphrase.map { pair -> Float in
            let a = try #require(embedder.vector(for: pair.0))
            let b = try #require(embedder.vector(for: pair.1))
            return cosineSimilarity(a, b)
        }
        let unrlSims = try unrelated.map { pair -> Float in
            let a = try #require(embedder.vector(for: pair.0))
            let b = try #require(embedder.vector(for: pair.1))
            return cosineSimilarity(a, b)
        }
        let paraMin = paraSims.min()!, unrlMax = unrlSims.max()!
        #expect(paraMin > unrlMax, "paraphrase \(paraMin) should exceed unrelated \(unrlMax)")
    }

    @Test("Per-chunk latency <= 20 ms on Metal/GPU (warm)")
    func latency() throws {
        let probe = "Natural language processing enables semantic search over document collections."
        _ = embedder.vector(for: probe)  // warm-up (first inference compiles/loads)
        _ = embedder.vector(for: probe)
        var times = [Double]()
        for _ in 0..<10 {
            let start = Date()
            _ = embedder.vector(for: probe)
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let median = times.sorted()[times.count / 2]
        print("MiniLM latency: median=\(String(format: "%.1f", median))ms max=\(String(format: "%.1f", times.max()!))ms")
        #expect(median <= 20.0, "median latency \(String(format: "%.1f", median))ms exceeds 20ms")
    }
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count)
    var dot: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    return min(max(dot, -1.0), 1.0)
}
