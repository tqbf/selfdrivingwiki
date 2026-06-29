# MLX MiniLM Implementation Plan — Phase 2: Wire into EmbeddingService

**Goal:** Introduce the `Embedder` protocol, conform `MiniLMEmbedder` to it, wrap
`NLEmbedding` behind `NLEmbedder`, wire `MiniLMEmbedder` as the active embedder
when the model dir is bundled, add the `embedding_meta` table (schema v15 via the
raw-C migration ladder), and implement dimension-cutover wipe logic.

**Architecture:** `EmbeddingService` (static enum) gains an `activeEmbedder`
property. At app launch, `configure()` async-loads `MiniLMEmbedder` if the model
dir exists in the bundle; otherwise falls back to `NLEmbedder`. On DB open,
`ensureSearchIndexesPopulated()` calls a new `ensureEmbedderConsistency()` helper
that uses `queryScalarText`/`exec`/`statement` (the store's raw C API) to check
`embedding_meta` against `EmbeddingService.selectedEmbedderIdentifier()` — if they
differ, it wipes `page_chunks` + `source_chunks` and updates the stored
identifier. The existing async backfill re-embeds everything. All search queries
(`vec_distance_cosine`) are unchanged.

**Important:** `SQLiteWikiStore` uses the **raw SQLite C API**
(`sqlite3_exec`, `sqlite3_prepare_v2`, private helpers `exec()`,
`queryScalarText()`, `statement()`/`bind()`). There is NO GRDB. Every DB operation
in this phase uses those helpers.

**Tech Stack:** Swift 6.0, macOS 15, raw SQLite3 C API (via `SQLiteWikiStore` helpers), MLX (via `MiniLMEmbedder`)

**Scope:** Phase 2 of 4. Produces `Embedder.swift`, `NLEmbedder.swift`,
`MiniLMEmbedder` conformance, refactored `EmbeddingService.swift`, schema v15,
cutover logic, and `build.sh` updates.

**Codebase verified:** 2026-06-29 (createFreshSchemaV14 at SQLiteWikiStore.swift:139;
`PRAGMA user_version=14` at :345 (fresh) and :738 (ladder); `if version < 14` at
:718; `ensureSearchIndexesPopulated()` at :1974; WikiFSCore target deps = `["CSqliteVec"]`)

---

## Acceptance Criteria Coverage

### AC3: Dimension cutover is automatic
- A DB opened with MiniLM active has only 384-dim chunks; switching embedders wipes + re-embeds automatically (`embedding_meta` driven).

---

## Task 1: Add Embedder protocol and NLEmbedder

**Files:**
- Create: `Sources/WikiFSCore/Embedder.swift`
- Create: `Sources/WikiFSCore/NLEmbedder.swift`

**`Sources/WikiFSCore/Embedder.swift`:**
```swift
public protocol Embedder: Sendable {
    /// Stable string identifying this embedder and its output dimension (e.g. "nlembedding-512").
    /// Stored in embedding_meta; a mismatch triggers the dimension-cutover wipe.
    static var identifier: String { get }

    /// Number of Float32 values in each output vector.
    var dimension: Int { get }

    /// Returns an L2-normalized embedding vector, or nil on model unavailability.
    func vector(for text: String) throws -> [Float]?
}
```

**`Sources/WikiFSCore/NLEmbedder.swift`:**
```swift
@preconcurrency import NaturalLanguage

public struct NLEmbedder: Embedder {
    public static let identifier = "nlembedding-512"
    public let dimension = 512

    nonisolated(unsafe) private static var _model: NLEmbedding?
    private static let lock = NSLock()

    private static func model() -> NLEmbedding? {
        lock.withLock {
            if _model == nil {
                guard #available(macOS 15, *) else { return nil }
                _model = NLEmbedding.sentenceEmbedding(for: .english)
            }
            return _model
        }
    }

    public init() {}

    public func vector(for text: String) throws -> [Float]? {
        guard let m = NLEmbedder.model() else { return nil }
        guard let doubles = m.vector(for: text) else { return nil }
        return doubles.map(Float.init)
    }
}
```

**Step 1: Write both files. Step 2: `swift build --target WikiFSCore 2>&1 | grep "error:"`. Step 3: Commit.**
```bash
git add Sources/WikiFSCore/Embedder.swift Sources/WikiFSCore/NLEmbedder.swift
git commit -m "feat: add Embedder protocol and NLEmbedder wrapper"
```

---

## Task 2: Conform MiniLMEmbedder to Embedder

**Files:**
- Modify: `Sources/WikiFSCore/MiniLMEmbedder.swift`

Phase 1 created `MiniLMEmbedder` as a standalone type. Make it conform:
- `: Embedder, @unchecked Sendable` (already `@unchecked Sendable`).
- Add `public static let identifier = "minilm-384"` (required by `Embedder`).
- The instance `dimension` and `vector(for:)` already match the protocol.

```bash
git add Sources/WikiFSCore/MiniLMEmbedder.swift
git commit -m "feat: conform MiniLMEmbedder to Embedder protocol"
```

---

## Task 3: Refactor EmbeddingService to use Embedder

**Files:**
- Modify: `Sources/WikiFSCore/EmbeddingService.swift`

Refactor to hold `any Embedder`; select at launch; keep the "don't fall back to
NLEmbedder on MiniLM load failure" invariant (see comment below):

```swift
import Foundation

public enum EmbeddingService {
    nonisolated(unsafe) private static var _embedder: (any Embedder)?
    private static let embedderLock = NSLock()

    /// Returns the identifier of the embedder selected for the current bundle,
    /// without loading the model. Safe to call synchronously from any context.
    public static func selectedEmbedderIdentifier() -> String {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return NLEmbedder.identifier  // test / CLI context: no model loads
        }
        if Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil) != nil {
            return MiniLMEmbedder.identifier
        }
        return NLEmbedder.identifier
    }

    /// Async: loads the selected embedder model. Call once from WikiStoreModel
    /// startup before backfill begins. Idempotent (no-op after first call).
    public static func configure() async {
        guard embedderLock.withLock({ _embedder == nil }) else { return }
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }

        if let modelDir = Bundle.main.url(forResource: "all-MiniLM-L6-v2", withExtension: nil) {
            do {
                let embedder = try await MiniLMEmbedder(modelDirectoryURL: modelDir)
                embedderLock.withLock { _embedder = embedder }
            } catch {
                // MiniLM bundled but failed to load — leave _embedder = nil.
                // Do NOT fall back to NLEmbedder here: selectedEmbedderIdentifier()
                // returns "minilm-384" (bundle present), so embedding_meta would be
                // written "minilm-384" while NLEmbedder produced 512-dim vectors → a
                // dimension mismatch on next launch. Leaving nil means backfill
                // no-ops; embedding_meta retains "minilm-384" so the next launch
                // retries the load automatically.
                DebugLog.store("EmbeddingService.configure: MiniLM load failed — \(error). Backfill disabled until model loads.")
            }
        } else {
            embedderLock.withLock { _embedder = NLEmbedder() }
        }
    }

    public static var isAvailable: Bool { embedderLock.withLock { _embedder } != nil }

    public static func embeddingBlob(for text: String) -> Data? {
        guard let embedder = embedderLock.withLock({ _embedder }) else { return nil }
        guard let floats = try? embedder.vector(for: text) else { return nil }
        return floats.withUnsafeBytes { Data($0) }
    }

    public static func chunkedEmbeddings(for text: String, maxChunks: Int = 64) -> [Data] {
        guard embedderLock.withLock({ _embedder }) != nil else { return [] }
        return evenlySample(TextChunker.chunk(text), max: maxChunks).compactMap { embeddingBlob(for: $0) }
    }

    public static func chunks(for text: String, maxChunks: Int = 64) -> [String] {
        evenlySample(TextChunker.chunk(text), max: maxChunks)
    }

    private static func evenlySample<T>(_ items: [T], max n: Int) -> [T] {
        guard items.count > n else { return items }
        let stride = Double(items.count - 1) / Double(n - 1)
        return (0..<n).map { items[Int((Double($0) * stride).rounded())] }
    }
}
```

```bash
git add Sources/WikiFSCore/EmbeddingService.swift
git commit -m "refactor: EmbeddingService delegates to Embedder protocol"
```

---

## Task 4: Schema v15 — add embedding_meta using the raw C migration ladder

**Files:**
- Modify: `Sources/WikiFSCore/SQLiteWikiStore.swift`
- Modify: `Tests/WikiFSTests/FreshSchemaParityTests.swift`

**Step 1: Add embedding_meta to createFreshSchemaV14() and bump to V15**

In `createFreshSchemaV14()` (SQLiteWikiStore.swift:139), find
`try exec("PRAGMA user_version=14;")` (line ~345). Insert before it, then change
the version:

```swift
try exec("""
CREATE TABLE embedding_meta (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    embedder TEXT NOT NULL
);
""")
// Seed with nlembedding-512 in both fresh and ladder paths (same constant →
// parity test passes). ensureEmbedderConsistency() updates this on first open.
try exec("INSERT INTO embedding_meta(id, embedder) VALUES (1, 'nlembedding-512');")

// CHANGE: PRAGMA user_version=14 -> 15
try exec("PRAGMA user_version=15;")
```

Rename `createFreshSchemaV14()` → `createFreshSchemaV15()` and update its call
site (line ~126).

**Step 2: Add v14→v15 step to the migration ladder**

After the `if version < 14 { ... }` block (line ~718, with its
`PRAGMA user_version=14` at ~738), add:

```swift
if version < 15 {
    try exec("""
    CREATE TABLE embedding_meta (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        embedder TEXT NOT NULL
    );
    """)
    try exec("INSERT INTO embedding_meta(id, embedder) VALUES (1, 'nlembedding-512');")
    try exec("PRAGMA user_version=15;")
    version = 15
}
```

**Step 3: Update FreshSchemaParityTests.swift**

Find the `pragmaValue("user_version")` assertions comparing to `"14"` and change
each to `"15"`. Add `"embedding_meta"` to the expected-tables list in
`freshFastPathHasExpectedObjects`.

```bash
swift test --filter FreshSchemaParityTests
git add Sources/WikiFSCore/SQLiteWikiStore.swift Tests/WikiFSTests/FreshSchemaParityTests.swift
git commit -m "feat: schema v15 — add embedding_meta table for embedder dimension tracking"
```

---

## Task 5: Add cutover logic + wire configure() in WikiStoreModel

**Verifies:** AC3

**Files:**
- Modify: `Sources/WikiFSCore/SQLiteWikiStore.swift` (`ensureEmbedderConsistency()` + call)
- Modify: `Sources/WikiFSCore/WikiStoreModel.swift` (add `configure()` before backfill)

**Step 1: ensureEmbedderConsistency() in SQLiteWikiStore** (near
`ensureSearchIndexesPopulated()` at :1974). Internal so tests can inject an override:

```swift
func ensureEmbedderConsistency(activeIdentifierOverride: String? = nil) {
    let activeIdentifier = activeIdentifierOverride ?? EmbeddingService.selectedEmbedderIdentifier()
    do {
        let stored = (try? queryScalarText("SELECT embedder FROM embedding_meta WHERE id = 1;")) ?? ""
        guard stored != activeIdentifier else { return }
        try exec("DELETE FROM page_chunks;")
        try exec("DELETE FROM source_chunks;")
        let stmt = try statement("INSERT OR REPLACE INTO embedding_meta(id, embedder) VALUES (1, ?1);")
        defer { stmt.reset() }
        try stmt.bind(activeIdentifier, at: 1)
        _ = try stmt.step()
        DebugLog.store("ensureEmbedderConsistency: \(stored.isEmpty ? "(empty)" : stored) -> \(activeIdentifier), chunks wiped")
    } catch {
        DebugLog.store("ensureEmbedderConsistency: failed — \(error)")
    }
}
```

**Step 2: Call it from ensureSearchIndexesPopulated() as step 0** (before FTS/source checks).

**Step 3: Add `await EmbeddingService.configure()` as the first line inside the
`backfillMissingEmbeddings()` Task block** (WikiStoreModel.swift:1296).

**Step 4: EmbeddingMetaCutoverTests** — mirror the temp-store helper from
`SourceEmbeddingSearchTests.swift` (FK: `source_chunks.page_id REFERENCES sources(id)`
with `PRAGMA foreign_keys=ON` — call `store.addSource(...)` before
`store.storeSourceChunks`, never a bare `PageID` literal). Two tests: fresh DB seeds
v15 with `nlembedding-512` (no-op cutover); cutover from `nlembedding-512` →
`minilm-384` wipes source chunks (the source reappears in `missingSourceEmbeddingWork()`).

```bash
swift test --filter EmbeddingMetaCutoverTests
git add Sources/WikiFSCore/SQLiteWikiStore.swift Sources/WikiFSCore/WikiStoreModel.swift Tests/WikiFSTests/EmbeddingMetaCutoverTests.swift
git commit -m "feat: embedding_meta cutover — wipe chunks on embedder mismatch"
```

---

## Task 6: Update build.sh to bundle the MLX model dir

**Files:**
- Modify: `build.sh`

Find the resource-copy section (`grep -n "mermaid\|RESOURCES_DIR\|cp " build.sh`),
then add a conditional copy after the JS bundle copies:

```bash
# MLX MiniLM model dir — optional; generated by tools/minilm-prepare/download.py
if [ -d "Resources/all-MiniLM-L6-v2" ]; then
  echo "  Bundling all-MiniLM-L6-v2 ..."
  cp -r "Resources/all-MiniLM-L6-v2" "${RESOURCES_DIR}/all-MiniLM-L6-v2"
fi
```

```bash
git add build.sh
git commit -m "feat: bundle all-MiniLM-L6-v2 MLX model dir in build.sh (conditional)"
```

---

## Task 7: Full test suite

```bash
swift test
```

Expected: all tests pass, including `FreshSchemaParityTests` (v15) and `EmbeddingMetaCutoverTests`.
