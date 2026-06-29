# MLX MiniLM Implementation Plan — Phase 1: Swift Inference (Isolated)

**Goal:** Implement `MiniLMEmbedder` in `WikiFSCore` via `MLXEmbedders` and
validate it with tests — tokenize, forward, mean-pool, L2-normalize — before
wiring into `EmbeddingService`.

**Architecture:** `MiniLMEmbedder` lives in `WikiFSCore` but is not called from
`EmbeddingService` yet (Phase 2). Isolation is code-level: no EmbeddingService
dependency. Tests run via `swift test` using `#FilePath`-relative paths to locate
`Resources/`. Uses `MLXEmbedders` (from `ml-explore/mlx-swift-lm`), which bundles
its own tokenizer (`TokenizersLoader`) and pooling.

**Tech Stack:** Swift 6.0, macOS 15, `MLXEmbedders` + `mlx-swift-lm` (Metal/GPU)

**Scope:** Phase 1 of 4. Produces `MiniLMEmbedder.swift` + passing tests.
Prerequisites: Phase 0 model dir in `Resources/all-MiniLM-L6-v2/` + reference
embeddings JSON.

**Codebase verified:** 2026-06-29

---

## Acceptance Criteria Coverage

### AC1: MiniLMEmbedder cosine accuracy
- `MiniLMEmbedder` is **non-garbage** (min cosine ≥ 0.95 vs the Phase-0 HF
  reference) and **self-consistent** (paraphrase ≫ unrelated). NOTE: Swift
  `MLXEmbedders` is a *different* implementation from the Python `mlx-embeddings`
  proxy, so its absolute-vs-HF parity is unknown until measured — do NOT assert
  ≥0.999-vs-HF. If Swift-vs-HF lands below 0.95, investigate before proceeding
  (that would indicate a real Swift loading bug). The reference-embeddings JSON
  (Phase 0) is the HF reference, used here as the non-garbage bar.

### AC2: Per-chunk latency
- Per-chunk latency ≤ ~20 ms on the target machine (**Metal/GPU**).

---

## Task 1 (FIRST): Compile-check the MLXEmbedders API against the real signatures

**Why before anything else:** the Phase-0 research snippet
(`loadModelContainer` / `container.perform { model, tokenizer, pooler }` /
`pooler(output, normalize:)`) is source-cited but may differ in detail from the
installed `mlx-swift-lm` version. Confirm the real API before writing the real
embedder.

**Step 1: Add the dependency to Package.swift**

In the top-level `dependencies:` array (currently only `swift-markdown`), add:

```swift
.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "0.1.0"),
```

In the `WikiFSCore` target, add the product to its `dependencies:`:

```swift
.target(
    name: "WikiFSCore",
    dependencies: [
        "CSqliteVec",
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
    ],
    ...
),
```

> NOTE: `swift-transformers` and `CoreML` were never added to `Package.swift`
> (they were only ever proposed in the old CoreML design doc) — there is nothing
> to remove. `MLXEmbedders` brings its own tokenizer via `TokenizersLoader`.

**Step 2: Resolve + a throwaway compile probe**

```bash
swift package resolve
```

Then create a temporary `Sources/WikiFSCore/_MLXApiProbe.swift` that exercises the
research API against the Phase-0 model dir, e.g.:

```swift
import MLXEmbedders
import MLXLMCommon   // if ModelConfiguration/HubClient live here in the installed version

func _probe() async throws {
    let config = ModelConfiguration(id: "all-MiniLM-L6-v2", defaultPrompt: "")
    let container = try await loadModelContainer(configuration: config)
    let v: [Float] = try await container.perform { model, tokenizer, pooler in
        let tokens = tokenizer.encode(text: "hello world")
        let input = MLXArray(tokens).expandedDimensions(axis: 0)
        let output = model(input)
        let pooled = pooler(output, normalize: true)
        eval(pooled)
        return pooled.asType(.float32).toArray(Float.self)
    }
    print(v.count) // expect 384
}
```

Adjust to the actual installed signatures (parameter labels, where
`ModelConfiguration`/`HubClient` live, whether loading is from a local dir URL vs
an id). Resolve any mismatches and record the corrected call shape in the
`MiniLMEmbedder` task below.

**Step 3: `swift build --target WikiFSCore`; then delete the probe file**

```bash
swift build --target WikiFSCore 2>&1 | grep "error:" || echo "no errors"
rm Sources/WikiFSCore/_MLXApiProbe.swift
```

Do NOT commit the probe. Commit only the `Package.swift` change once it resolves:

```bash
git add Package.swift Package.resolved
git commit -m "feat: add mlx-swift-lm MLXEmbedders to WikiFSCore"
```

---

## Task 2: Re-export reference embeddings from Phase 0

The Swift cosine test needs reference vectors in a format it can read.

**Files:**
- Modify: `tools/minilm-prepare/validate.py` (add a JSON export after the gate passes)

Append to `validate.py` (after the success print): write the reference embeddings
to `Resources/all-MiniLM-L6-v2-reference-embeddings.json` as
`[{"text": ..., "embedding": [...]}]` (the sentence-transformers reference, 384-dim).

```bash
cd tools/minilm-prepare
uv run python validate.py   # re-runs the gate + writes the JSON
```

```bash
git add tools/minilm-prepare/validate.py Resources/all-MiniLM-L6-v2-reference-embeddings.json
git commit -m "feat: export reference embeddings JSON for Swift cosine tests"
```

---

## Task 3: Create Sources/WikiFSCore/MiniLMEmbedder.swift

**Verifies:** AC1, AC2

**Files:**
- Create: `Sources/WikiFSCore/MiniLMEmbedder.swift`

Use the API shape confirmed in Task 1. Target shape (adjust to real signatures):

```swift
import Foundation
import MLXEmbedders
import MLXLMCommon

/// On-device MiniLM embeddings via MLX (Metal/GPU). Thread-safe:
/// `ModelContainer.perform` serializes access. `@unchecked Sendable` because
/// ModelContainer is not formally Sendable but is safe to share.
public final class MiniLMEmbedder: @unchecked Sendable {
    public static let identifier = "minilm-384"
    public let dimension = 384

    private let container: /* ModelContainer type from Task 1 */ Any

    /// Loads the model from a bundled model directory URL.
    public init(modelDirectoryURL: URL) async throws {
        // Build ModelConfiguration from a local path (NOT a Hub id) so it works
        // offline from the bundled Resources dir. Adjust to the confirmed API.
        let config = ModelConfiguration(/* path: modelDirectoryURL.path ... */)
        self.container = try await loadModelContainer(configuration: config)
    }

    /// Returns a 384-dim L2-normalized embedding, or nil on failure.
    public func vector(for text: String) -> [Float]? {
        // container.perform serializes model access (thread-safe).
        guard let floats: [Float] = try? container.perform(
            { model, tokenizer, pooler in
                let tokens = tokenizer.encode(text: text)
                let input = MLXArray(tokens).expandedDimensions(axis: 0)
                let output = model(input)
                let pooled = pooler(output, normalize: true)  // mean pool + L2
                eval(pooled)
                return pooled.asType(.float32).toArray(Float.self)
            }
        ) else { return nil }
        return floats
    }
}
```

Notes:
- The `Embedder` protocol conformance (identifier/dimension/vector) is added in
  Phase 2. Here it's a standalone type with matching members.
- Truncation at 512 tokens is handled by the tokenizer/model; no special code.
- Adjust the closure's `perform` return-type marshalling to the real signature
  (it may need a concrete return type or `@discardableResult` handling).

**Step 1: Write the file. Step 2: `swift build --target WikiFSCore`. Step 3: Commit.**

```bash
git add Sources/WikiFSCore/MiniLMEmbedder.swift
git commit -m "feat: add MiniLMEmbedder (MLX inference + mean pool + L2 norm)"
```

---

## Task 4: Create Tests/WikiFSTests/MiniLMEmbedderTests.swift

**Verifies:** AC1, AC2

**Files:**
- Create: `Tests/WikiFSTests/MiniLMEmbedderTests.swift`

Resources discovered via `#filePath`-relative path to repo root (no
`Bundle.module`). Reference embeddings loaded from
`Resources/all-MiniLM-L6-v2-reference-embeddings.json` (Phase 0 Task 2).

```swift
import Testing
import Foundation
import Accelerate
@testable import WikiFSCore

private func resourcesURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MiniLMEmbedderTests.swift
        .deletingLastPathComponent()  // WikiFSTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Resources")
}

private struct ReferenceEmbedding: Decodable {
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
            modelDirectoryURL: res.appendingPathComponent("all-MiniLM-L6-v2")
        )
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
        #expect(abs(sqrt(sumSq) - 1.0) < 0.001)
    }

    // AC1 — non-garbage (not a parity bar). Swift MLXEmbedders is a different
    // implementation from the Python mlx-embeddings proxy, so ≥0.999-vs-HF is NOT
    // expected; 0.95 rules out a real loading bug (garbage is ~0.17).
    @Test("Non-garbage: cosine >= 0.95 vs HF reference on all probes")
    func nonGarbageVsReference() throws {
        for ref in references {
            let v = try #require(embedder.vector(for: ref.text),
                                 "vector(for:) returned nil for: \(ref.text)")
            #expect(cosineSimilarity(v, ref.embedding) >= 0.95,
                    "cosine < 0.95 for: \(ref.text.prefix(50)) — investigate Swift MLX loading")
        }
    }

    // AC1 — self-consistent (the property search depends on).
    @Test("Self-consistent: paraphrase pairs more similar than unrelated")
    func selfConsistent() throws {
        let paraphrase: [(String, String)] = [
            ("A self-driving car navigates roads autonomously.",
             "Autonomous vehicles drive themselves on public roads."),
        ]
        let unrelated: [(String, String)] = [
            ("A self-driving car navigates roads autonomously.",
             "The recipe needs two cups of flour and a pinch of salt."),
        ]
        let paraMin = paraphrase.map { cosineSimilarity(try #require(embedder.vector(for: $0.0)), try #require(embedder.vector(for: $0.1))) }.min()!
        let unrlMax = unrelated.map { cosineSimilarity(try #require(embedder.vector(for: $0.0)), try #require(embedder.vector(for: $0.1))) }.max()!
        #expect(paraMin > unrlMax, "paraphrase \(paraMin) should exceed unrelated \(unrlMax)")
    }

    @Test("Per-chunk latency <= 20 ms on Metal/GPU (warm)")
    func latency() throws {
        let probe = "Natural language processing enables semantic search over document collections."
        _ = embedder.vector(for: probe)  // warm-up
        _ = embedder.vector(for: probe)
        var times = [Double]()
        for _ in 0..<10 {
            let start = Date()
            _ = embedder.vector(for: probe)
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let median = times.sorted()[times.count / 2]
        print("MiniLM latency: median=\(String(format: "%.1f", median))ms")
        #expect(median <= 20.0)
    }
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count)
    var dot: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    return min(max(dot, -1.0), 1.0)
}
```

```bash
# Prerequisite: the model + version-matched metallib must be present (gitignored).
# tools/minilm-prepare/download.py fetches both; swift test finds the metallib via
# the repo-root default.metallib (CWD fallback). Without it: "Failed to load the
# default metallib".
( cd tools/minilm-prepare && uv run python download.py )
swift test --filter MiniLMEmbedderTests
```

Expected: dimension = 384, L2-norm ≈ 1, non-garbage (cosine ≥ 0.95 vs HF ref) +
self-consistent (paraphrase > unrelated), median latency ≤ 20 ms.

```bash
git add Tests/WikiFSTests/MiniLMEmbedderTests.swift
git commit -m "test: MiniLMEmbedder cosine accuracy and Metal/GPU latency tests"
```
