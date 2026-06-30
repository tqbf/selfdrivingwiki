import Testing
import Foundation
import Accelerate
@testable import WikiFSMLX

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

/// The MiniLM model dir + reference-embeddings JSON are **gitignored** (fetched
/// on demand by `tools/minilm-prepare/download.py`) and so are absent in CI.
/// These tests require both to be present locally (run the prepare step first).
/// The suite is skipped — not failed — when they're missing.
private func miniLMResourcesAvailable() -> Bool {
    let res = resourcesURL()
    let config = res.appendingPathComponent("all-MiniLM-L6-v2/config.json")
    let refJSON = res.appendingPathComponent("all-MiniLM-L6-v2-reference-embeddings.json")
    return FileManager.default.fileExists(atPath: config.path)
        && FileManager.default.fileExists(atPath: refJSON.path)
}

struct ReferenceEmbedding: Decodable {
    let text: String
    let embedding: [Float]
}

@Suite("MiniLMEmbedder", .enabled(if: miniLMResourcesAvailable()))
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

    /// Regression: distinct **long** (~4k-char, realistic chunk-length) passages
    /// must NOT collapse to a common vector. The first shipped run had 264/400
    /// stored chunks at one identical embedding while short probes tested fine —
    /// the Phase-1 tests only ever fed short strings, so the long-input path was
    /// never exercised. This catches a degenerate-constant failure on long input
    /// (the chunk size `TextChunker` produces in production).
    @Test("Distinct long passages yield distinguishable embeddings (no degenerate constant)")
    func distinctLongPassagesAreDistinguishable() throws {
        let passages = distinctLongPassages()
        #expect(passages.count >= 3)
        let vecs = try passages.map { (text) -> [Float] in
            try #require(embedder.vector(for: text), "vector(for:) returned nil for a long passage")
        }
        for i in 0..<vecs.count {
            for j in (i + 1)..<vecs.count {
                #expect(vecs[i] != vecs[j],
                        "passages \(i) and \(j) collapsed to the SAME vector (degenerate)")
                let sim = cosineSimilarity(vecs[i], vecs[j])
                #expect(sim < 0.999,
                        "passages \(i) and \(j) are near-identical (cosine \(String(format: "%.4f", sim))) — degenerate")
            }
        }
    }
}

/// Three genuinely-distinct ~2k-char prose passages on unrelated topics (the
/// chunk length `TextChunker` produces in production). Real prose, not repeated
/// sentences — a stronger guard than the short Phase-1 probes. If the embedder
/// degenerates on long input, these collapse to one vector and the test fails.
private func distinctLongPassages() -> [String] {
    [
        """
        Autonomic dysregulation in autism spectrum disorder is a leading explanatory \
        framework for the sensorimotor and emotional differences observed in autistic \
        individuals. The polyvagal theory, advanced by Stephen Porges, frames the \
        autonomic nervous system as a layered substrate of social engagement, \
        mobilization, and shutdown. Heart rate variability serves as a non-invasive \
        window onto vagal tone, and biofeedback interventions that train slow paced \
        breathing have shown measurable effects on autonomic balance. Hypnosis and \
        suggestion modulate autonomic output as well, which is why clinicians pair \
        them with biofeedback for anxiety and pain regulation. The repeated finding \
        across studies is that autistic participants exhibit reduced respiratory \
        sinus arrhythmia at rest and blunted reactivity to social stressors. \
        Interventions that restore vagal flexibility tend to improve both \
        physiological regulation and subjective well-being. This converges with \
        the broader autonomic dysregulation account: the nervous system's baseline \
        set point, not any single symptom, is the therapeutic target.
        """,
        """
        Scala implicits are a mechanism for implicit resolution by the compiler: \
        given a type error or a missing method, the compiler searches implicit \
        scope for a conversion or value that satisfies the expected type. The \
        rules governing implicit search are notoriously subtle, because the \
        eligible scope includes the companion objects of types involved in the \
        expression, inherited members, and explicitly imported givens. Type \
        classes are expressed as traits with given instances, and extension \
        methods are derived from them. The danger is that implicit conversions \
        fire unexpectedly, turning compile errors into surprising runtime \
        behavior, which is why Scala 3 prefers the more explicit `given` and \
        `using` syntax. A common performance pitfall is that implicit resolution \
        happens entirely at compile time and can produce large synthesized code, \
        so carefully shaping implicit scope matters for both clarity and binary \
        size. The lesson, repeatedly learned, is to keep implicit scope narrow \
        and to prefer parameterization where the relationship is not genuinely \
        contextual.
        """,
        """
        Sourdough fermentation depends on a symbiotic culture of wild yeast and \
        lactic acid bacteria maintained in a flour and water starter. Over a long \
        bulk fermentation at cool room temperature, the lactobacilli produce \
        lactic and acetic acid, which lower the pH, condition the gluten, and \
        contribute the characteristic tang. The yeast, slower than commercial \
        baker's yeast, generates carbon dioxide that the developed gluten traps, \
        producing an open, irregular crumb. Hydration, temperature, and time are \
        the three levers: higher hydration slackens the dough for a more open \
        crumb; warmer temperatures accelerate both acid and gas production; and \
        longer fermentation deepens flavor at the risk of over-acidification. \
        The baker develops intuition for the culture's rhythm through repeated \
        observation rather than strict timing. A mature starter, fed regularly, \
        is resilient and predictable, and the bread it leavens reflects the \
        environment in which the culture was raised.
        """
    ]
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count)
    var dot: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    return min(max(dot, -1.0), 1.0)
}
