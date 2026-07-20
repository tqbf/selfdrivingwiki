# Plan — Issue #628: Swift-side cosine similarity, retire `CSqliteVec`

**Status:** Draft for implementation · **App:** Self Driving Wiki (macOS 15 / Swift 6.0) · **Tracking:** GitHub issue #628 · **Related:** #630 (rejected sqlite-vector evaluation), #625 (bundle SQLite amalgamation — do this AFTER #628).

> Operator decision (per task brief): do **#628** (Path B). sqlite-vector (#630) is **rejected** — SSW's lack of a LICENSE file makes sqlite-vector's Elastic-2.0 OSI-grant inapplicable, and its SIMD gains only pay off at 100K+ vectors where the embedding-model call no longer dominates.

All line numbers below are confirmed against the **current** `main` (they have drifted ~200–270 lines from the figures quoted in issues #628/#630). The implementer MUST re-confirm each with `rg` before editing — code drifts.

---

## 1. Goal

Replace the SQL-side `vec_distance_cosine(embedding, ?)` scalar (from the vendored, statically-linked sqlite-vec extension) with **cosine similarity computed in Swift** via an Accelerate/vDSP dot product over the existing L2-normalized chunk-embedding BLOBs. Then **delete the entire `CSqliteVec` C target** — making the repo MIT-clean with zero C/extension dependency on the SQLite vector path. The semantic-search result set (best-chunk-per-doc ranking fused into `RankFusion.rrf`) is **bit-for-bit identical** to the current sqlite-vec baseline for the same embeddings.

---

## 2. Current-state map (confirmed against current `main`)

### 2.1 The three semantic-search queries (the only ranking call sites)

All three live in `Sources/WikiFSCore/Store/GRDBWikiStore.swift`. Each is `MIN(vec_distance_cosine(embedding, ?)) ... GROUP BY <doc>_id` → best-chunk-per-doc → `ORDER BY best ASC` (lowest distance = most similar) → `.prefix(pool)` → fused into `RankFusion.rrf`.

| Kind | Method | Line | Table | Doc-id col |
|------|--------|------|-------|-----------|
| Pages | `searchSimilar(query:limit:bm25Leg:)` | **`:5334`** | `page_chunks` | `page_id` |
| Sources | `searchSimilarSources(query:limit:bm25Leg:)` | **`:5419`** | `source_chunks` | `source_id` |
| Chats | `searchSimilarChats(query:limit:bm25Leg:)` | **`:5973`** | `chat_chunks` | `chat_id` |

Representative full SQL (pages, `GRDBWikiStore.swift:5331-5341`):
```sql
SELECT p.id, p.title, p.updated_at, p.created_at
FROM (
    SELECT page_id, MIN(vec_distance_cosine(embedding, ?)) AS best
    FROM page_chunks GROUP BY page_id
) r
JOIN pages p ON p.id = r.page_id
ORDER BY r.best ASC
LIMIT ?;
-- arguments: [queryBlob, pool]
```

Each is gated `if Self.isVecAvailable(db), let queryBlob = EmbeddingService.embeddingBlob(for: query)`. The output list feeds `RankFusion.rrf([semRows, ftsRows], id: \.id).prefix(limit)`. **`RankFusion.rrf` consumes rank ORDER only** (it scores by `1/(k+rank)`), not raw distance — so the Swift path must hand it an already most-similar-first array (`Sources/WikiFSSearch/RankFusion.swift`).

### 2.2 The `isVecAvailable` probe + dependent gates

- **Definition + probe** — `GRDBWikiStore.swift:6190-6192`:
  ```swift
  private static func isVecAvailable(_ db: Database) -> Bool {
      (try? Row.fetchOne(db, sql: "SELECT vec_distance_cosine(x'00000000', x'00000000');")) != nil
  }
  ```
- **Call sites of `isVecAvailable`**: the three search queries above (`:5326`, `:5410`, `:5964`) and `reembedSource` (`GRDBWikiStore.swift:6449`). `reembedSource` uses it as a "can we store+rank embeddings?" gate.
- **`vecRegisteredForTesting` test hook** — `GRDBWikiStore.swift:7517-7519` (`#if DEBUG`), wraps `isVecAvailable`.
- **Comment-only references** (cosmetic, update wording): `WikiStore.swift:557`, `:580`; `Embedder.swift:7`; `EmbeddingService.swift:9`; `GRDBWikiStore.swift:829`, `:6432`, `:7512-7516`.

> ⚠️ `isVecAvailable` currently conflates two things: "the vec scalar is registered" AND "embeddings are rankable". Post-#628 the **real** gate is whether embeddings exist at all — i.e. `EmbeddingService.isAvailable` (the model loaded) AND the chunk table is non-empty. The semantic leg should gate on those, not on a C-extension probe.

### 2.3 `wikifs_vec_register` — THREE call sites (issue #628 said two; the third exists)

`GRDBWikiStore.swift` registers the extension on every connection-opening path:

| Init | Line | Context |
|------|------|---------|
| `init(databaseURL:)` (file-backed pool, RW) | **`:147-155`** | main store — logs success/failure via `DebugLog.store` |
| `init(readOnlyURL:)` (File Provider, RO) | **`:224-227`** | read-only pool — comment "pooled readers need it for `vec_distance_cosine`" |
| `init()` (in-memory `DatabaseQueue`, `#if DEBUG`) | **`:269-272`** | tests — "Register the statically-linked sqlite-vec on this single connection" |

All three must be removed. The `import CSqliteVec` at the top of the file (`GRDBWikiStore.swift:4`) goes too.

### 2.4 The `CSqliteVec` Package target + dependency

- **Target definition** — `Package.swift:64-73` (`.target(name: "CSqliteVec", path: "Sources/CSqliteVec", publicHeadersPath: "include", cSettings: [.define("SQLITE_CORE"), .define("SQLITE_VEC_STATIC"), .headerSearchPath(".")])`).
- **Dependent** — `Package.swift:137`, the `WikiFSCore` target's `dependencies: ["CSqliteVec", ...]`. Remove the `"CSqliteVec"` entry.
- **Source dir** — `Sources/CSqliteVec/` (`CSqliteVec.c`, `sqlite-vec.c`, `include/CSqliteVec.h`, `README.md`) — delete entirely.

### 2.5 How embeddings are STORED — **L2-normalized at write time (CONFIRMED)** ✅

This is the linchpin. Swift-side cosine reduces to a plain **dot product** iff stored vectors are unit-norm. They are:

- **`Embedder` protocol contract** (`Sources/WikiFSSearch/Embedder.swift:18-20`): *"An L2-normalized embedding, or `nil` ..."*. The protocol is the abstraction the store depends on.
- **`MiniLMEmbedder`** (the app's primary embedder, `Sources/WikiFSMLX/MiniLMEmbedder.swift:59-73`): mean-pools with `normalize: true` then **re-normalizes exactly** via `vDSP_svesq` (lines 63-73): *"the pooler's `normalize` drifts slightly with bf16 weights (~1.003)... so re-normalize exactly."* Unit-norm is guaranteed by construction.
- **`NLEmbedder`** (fallback, `Sources/WikiFSSearch/NLEmbedder.swift:34-37`): returns `NLEmbeping.sentenceEmbedding(for:).vector(for:)` mapped to `[Float]`. Apple's `NLEmbedding` returns unit-length vectors (documented behavior of `vector(for:)`). The protocol contract asserts L2-normalized.

**BLOB format** (both paths, `EmbeddingService.embeddingBlob`, `EmbeddingService.swift:110`): `floats.withUnsafeBytes { Data($0) }` — raw little-endian Float32, contiguously packed, count = `embedder.dimension`. Dimension today is **512 (NLEmbedder)** or **384 (MiniLM)** — but it's stored in `embedding_meta` and a cutover wipes `*_chunks` on mismatch (`GRDBWikiStore.swift:7315-7341`), so **every stored vector in a given DB shares one dimension**. The dot product is dimension-agnostic.

**Write path** (unchanged by this work): `storePageChunks`/`storeSourceChunks`/`storeChatChunks` (`GRDBWikiStore.swift:5278`, `:5358`, `:5907`) DELETE-then-INSERT the `chunks: [Data]` blobs from `EmbeddingService.chunkedEmbeddings(for:)`.

### 2.6 Chunk table schema

Plain tables (NOT `vec0` vtabs) — no schema migration is needed to read them in Swift. `GRDBWikiStore.swift:831-853` (pages/sources, created at schema v14), `:1418`/`:2451` (chats, v23/v28):

```sql
CREATE TABLE page_chunks (
    page_id   TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    chunk_idx INTEGER NOT NULL,
    embedding BLOB NOT NULL,
    PRIMARY KEY (page_id, chunk_idx)
) WITHOUT ROWID;
-- source_chunks / chat_chunks identical shape (source_id / chat_id).
```

`WITHOUT ROWID` (clustered on the composite PK). There is no `embedding IS NULL` possibility — the column is `NOT NULL` — so a `WHERE embedding IS NOT NULL` guard is harmless but unnecessary.

### 2.7 Architecture / where the helper belongs

`WikiFSCore` (module containing `GRDBWikiStore`) **depends on `WikiFSSearch`** (`Package.swift:141`). So the pure-Swift cosine helper belongs in **`WikiFSSearch`** (already home to `Embedder`, `EmbeddingService`, `RankFusion`, `TextChunker`) and `GRDBWikiStore` calls it. This keeps DB I/O in Core and math in Search. Accelerate/vDSP is already imported in `WikiFSMLX` (`MiniLMEmbedder.swift:1`) — it's a system framework, no package change; the `WikiFSSearch` target will need `linkerSettings: [.linkedFramework("Accelerate")]` (or just `import Accelerate`, which auto-links on macOS).

---

## 3. Swift-side cosine design

### 3.1 The math (why dot product is exactly correct)

`vec_distance_cosine(a, b)` in sqlite-vec = **1 − cos_sim(a, b)** = 1 − (a·b)/(|a||b|). For unit vectors, |a|=|b|=1, so:

```
distance = 1 − (a·b)      ⟹      similarity = a·b = 1 − distance
```

- `MIN(vec_distance_cosine(...)) GROUP BY doc` ⇒ the **max** dot product (most similar chunk) per doc.
- `ORDER BY best ASC` (ascending distance) ⇒ **descending similarity** ⇒ most-similar-first.

So Swift computes `dot(query, chunk)` per chunk, groups by doc keeping the **max**, sorts descending, truncates to `pool`. The ordering fed to `RankFusion.rrf` is identical to the SQL path's for the same vectors. (Ties: the SQL path's tie-break is unspecified/rowid-ish; `RankFusion.rrf` is robust to tie-order because equal ranks get equal RRF scores. Not a correctness concern at the fused-output level.)

### 3.2 New helper — `VectorCosine` (in `Sources/WikiFSSearch/`)

A small, dependency-free, fully unit-testable enum. Pure `[Float]` math + the best-chunk-per-doc ranker. **No DB, no GRDB import** — it takes decoded vectors, so it's testable without a store.

```swift
// Sources/WikiFSSearch/VectorCosine.swift
import Foundation
import Accelerate

/// Pure-Swift cosine similarity over the L2-normalized Float32 embeddings
/// stored in `page_chunks`/`source_chunks`/`chat_chunks`. Replaces sqlite-vec's
/// `vec_distance_cosine` scalar (issue #628). Because every stored vector is
/// unit-norm (see `Embedder`), cosine similarity == dot product.
public enum VectorCosine {

    /// Decode a stored `embedding` BLOB (little-endian Float32, contiguous) to
    /// `[Float]`. Returns `nil` if the byte count is not a multiple of 4 or the
    /// dimension is 0. Mirrors `EmbeddingService.embeddingBlob(for:)`'s encode
    /// (`floats.withUnsafeBytes { Data($0) }`).
    public static func decode(_ data: Data) -> [Float]? {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0, data.count % MemoryLayout<Float>.size == 0 else { return nil }
        return data.withUnsafeBytes { ptr -> [Float] in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return nil }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }

    /// Dot product of two equal-length unit vectors == cosine similarity.
    /// Uses vDSP for SIMD throughput. Returns 0 on length mismatch (defensive).
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count > 0, a.count == b.count else { return 0 }
        var sum: Float = 0
        vDSP_dotpr(a, 1, b, 1, &sum, vDSP_Length(a.count))
        return sum
    }

    /// Best-chunk-per-doc ranker — the Swift equivalent of
    /// `SELECT doc_id, MIN(vec_distance_cosine(embedding, ?)) ... GROUP BY doc_id
    ///  ORDER BY best ASC LIMIT ?`.
    ///
    /// - Parameters:
    ///   - candidates: `(docID: String, embedding: Data)` for every chunk row in
    ///     the table (read via the normal off-main path).
    ///   - query: the L2-normalized query vector.
    ///   - pool: how many top docs to keep (matches the SQL `LIMIT ?`, i.e.
    ///     `max(limit * 2, limit)`).
    /// - Returns: doc IDs ranked most-similar-first, truncated to `pool`. Docs
    ///   whose blob fails to decode are skipped (logged by the caller, not here).
    public static func rankBestChunkPerDoc(
        candidates: [(docID: String, embedding: Data)],
        query: [Float],
        pool: Int
    ) -> [String] {
        var best: [String: Float] = [:]
        best.reserveCapacity(candidates.count)
        for c in candidates {
            guard let v = decode(c.embedding) else { continue }
            let sim = dot(query, v)            // higher == more similar
            // Keep the MAX similarity per doc (== MIN distance in the SQL path).
            if sim > (best[c.docID] ?? -.infinity) { best[c.docID] = sim }
        }
        return best
            .sorted { $0.value > $1.value }    // most-similar-first (== best ASC)
            .prefix(pool)
            .map(\.key)
    }
}
```

**Design notes:**
- `rankBestChunkPerDoc` returns `[String]` (doc IDs) rather than the full summary objects, keeping it DB-agnostic. `GRDBWikiStore` re-joins those IDs to the `pages`/`sources`/`chats` row to build `WikiPageSummary`/`SourceSummary`/`ChatSummary` (same columns as today). **Alternatively** (see §3.4, recommended) return a generic and let the caller carry its own row lookup.
- `vDSP_dotpr` is the right primitive (single SIMD dot). For the current scale this is plenty; no need for matrix multiply (`vDSP_mmul`) unless batching many queries.
- `decode` defensively checks the length is a multiple of 4 (a corrupt/truncated blob shouldn't crash). The caller logs skips via `DebugLog`.

### 3.3 The read-query change (in `GRDBWikiStore`)

Drop `vec_distance_cosine` entirely. The semantic leg becomes two steps:

**Step A — read all candidate chunk rows** (off-main via the existing `dbWriter.read` that already wraps each search method; these reads are already on a pool reader):

```swift
// pages example
let candidates = try Row.fetchAll(db, sql: """
    SELECT page_id, embedding FROM page_chunks;
    """)
    .map { (docID: String(row["page_id"]), embedding: Data(row["embedding"])) }
```

(For sources/chats: `SELECT source_id, embedding FROM source_chunks;` / `SELECT chat_id, embedding FROM chat_chunks;`.)

At current scale (a wiki's worth of chunks — typically low thousands of rows × 512 floats × 4 B ≈ a few MB) reading all rows into Swift is cheap and correct. See §8 gotchas for the threshold where it'd matter.

**Step B — rank in Swift, then build the ordered summary list:**

```swift
let rankedIDs = VectorCosine.rankBestChunkPerDoc(
    candidates: candidates, query: queryVec, pool: pool
)
// Re-fetch the doc rows in ranked order to build WikiPageSummary.
let placeholders = rankedIDs.map { _ in "?" }.joined(separator: ",")
let semRows = rankedIDs.isEmpty ? [] : try Row.fetchAll(db, sql: """
    SELECT p.id, p.title, p.updated_at, p.created_at
    FROM pages p
    WHERE p.id IN (\(placeholders))
    """, arguments: StatementArguments(rankedIDs))
    .map { row in WikiPageSummary(...) }   // same initializer as today
// Re-sort to match rankedIDs order (IN (...) does not preserve order):
let byID = Dictionary(uniqueKeysWithValues: semRows.map { ($0.id.rawValue, $0) })
let ordered = rankedIDs.compactMap { byID[$0] }
return Array(RankFusion.rrf([ordered, ftsRows], id: \.id).prefix(limit))
```

**Alternatively (simpler, fewer round-trips — RECOMMENDED):** do Step A and the join in ONE query so each candidate row already carries the summary columns, decode + dot-product in Swift, sort, and skip the second lookup:

```swift
let rows = try Row.fetchAll(db, sql: """
    SELECT p.id, p.title, p.updated_at, p.created_at, sc.embedding
    FROM page_chunks sc JOIN pages p ON p.id = sc.page_id;
    """)
// decode each sc.embedding, dot with queryVec, group by id keeping max sim,
// sort desc, prefix(pool), build WikiPageSummary — all in Swift.
```

This mirrors the original query's single-pass shape and avoids a second round-trip. The grouping/sort is a small loop over the rows. The implementer should pick whichever reads cleaner; the single-query form is preferred (fewer moving parts, one `IN`-free path).

> **`queryVec`** comes from `EmbeddingService.embeddingBlob(for: query)` decoded via `VectorCosine.decode(_:)` — same blob the SQL path bound as `?`. The gate remains `EmbeddingService.isAvailable` (replaces `isVecAvailable`).

### 3.4 Why `WikiFSSearch`, not `GRDBWikiStore`

`VectorCosine` is pure `[Float]`/`Data` math with zero DB coupling → testable in isolation, reusable by `wikictl` or any future caller, and it keeps the `GRDBWikiStore` file from growing more math. `WikiFSCore → WikiFSSearch` is the existing dependency direction.

---

## 4. Retire `CSqliteVec` (the deletion)

| # | File | Change |
|---|------|--------|
| 1 | `Sources/CSqliteVec/` (whole dir: `CSqliteVec.c`, `sqlite-vec.c`, `include/CSqliteVec.h`, `README.md`) | **Delete.** |
| 2 | `Package.swift:64-73` | Remove the `.target(name: "CSqliteVec", ...)` block. |
| 3 | `Package.swift:137` | Remove `"CSqliteVec"` from the `WikiFSCore` target's `dependencies:`. |
| 4 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:4` | Remove `import CSqliteVec`. |
| 5 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:147-155` | Remove the RW-pool `config.prepareDatabase { wikifs_vec_register(...) }` block (incl. the `DebugLog.store` success/fail logs). |
| 6 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:224-227` | Remove the read-only (File Provider) `wikifs_vec_register` block + its comment. |
| 7 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:269-272` | Remove the in-memory (`#if DEBUG`) `wikifs_vec_register` block + comment. |
| 8 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:6190-6192` | Remove `isVecAvailable(_:)`. |
| 9 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:5326`, `:5410`, `:5964` | Replace the `if Self.isVecAvailable(db), ...` gate with `if EmbeddingService.isAvailable, let queryBlob = ...` (semantic search is "always available" now — pure Swift — but still gated on the embedder being loaded, else there's no query vector). |
| 10 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:6449-6450` | In `reembedSource`, drop the `vecOK`/`isVecAvailable` gate; gate on `EmbeddingService.isAvailable` instead (the model must be loaded to embed). |
| 11 | `Sources/WikiFSCore/Store/GRDBWikiStore.swift:7517-7519` | Remove `vecRegisteredForTesting` (`#if DEBUG`) — OR repurpose it to assert `EmbeddingService.isAvailable` if a test still wants a registration-style hook. See §5 for the test rewrite. |
| 12 | Comment-only wording: `GRDBWikiStore.swift:829`, `:6432`, `:6188`, `:7512-7516`; `WikiStore.swift:557`, `:580`; `Embedder.swift:7`; `EmbeddingService.swift:9`; `WikiCtlCore/PageCommand.swift:43`; `WikiFSSearch/TantivySearchDocument.swift:102`; `Tests/WikiFSTests/TantivyShadowIndexTests.swift:13` | Update/strip references to `vec_distance_cosine` / "sqlite-vec" / "statically-linked" / "FTS5 + sqlite-vec + RRF". All verified doc-comment-only (no functional consumer). Cosmetic but REQUIRED to keep the acceptance grep clean. |

After deletion, `rg "vec_distance_cosine|wikifs_vec_register|CSqliteVec|isVecAvailable|sqlite-vec" Sources Tests` must return **zero** hits.

> **Order matters:** make the Swift-side cosine path work + green FIRST (§3), then delete the C target. Deleting the target before rewiring the queries breaks the build. Suggested commit sequence (on a feature branch, never `main`): (a) add `VectorCosine` + tests; (b) switch the three queries + gates; (c) remove `CSqliteVec` + `wikifs_vec_register` + `isVecAvailable` + comments. Each step builds.

---

## 5. Normalization — decision

**Embeddings ARE pre-L2-normalized at write time (§2.5).** Therefore Swift-side cosine is a **plain dot product** — no query-time normalization needed for correctness OR performance. This is the happy path the task brief anticipated.

**Belt-and-suspenders (optional, recommended for robustness):** because the store has shipped through embedder cutovers and re-embedding is async/best-effort, a defensive *renormalize-in-Swift* path guards against a pathological stored vector (e.g. an old blob that somehow wasn't normalized). Two options:

- **(v1, preferred — ship this):** assume unit-norm, dot product only. Document the invariant in `VectorCosine` (the `Embedder` contract enforces it; `embedding_meta` cutover wipes on embedder change). Cheapest, fastest, matches the SQL path's assumption exactly.
- **(defensive fallback, only if a test reveals non-unit stored vectors):** add `vDSP_normalize` on decode inside `VectorCosine.rankBestChunkPerDoc`. Correct regardless of stored norm, ~one extra `vDSP_svesq`+scale per vector. **Out of scope for v1** — but if §6's golden-set test shows divergence from the sqlite-vec baseline, enable it and investigate WHY a stored vector wasn't unit (that'd be an embedder bug, not a #628 bug).

To **confirm** pre-normalization holds before shipping: run the golden-set test (§6) against a real DB. If Swift dot-product ordering == sqlite-vec ordering, the assumption holds. No separate probe needed.

---

## 6. Testing plan (Swift Testing — `Tests/WikiFSTests/`)

> Existing tests to update: `SourceEmbeddingSearchTests.vecScalarIsRegisteredAfterStaticLink` (`:72-79`) asserts `store.vecRegisteredForTesting`. With `vecRegisteredForTesting` gone, **rewrite** this test to assert the Swift-side path instead (e.g. that seeding chunk embeddings + querying returns ranked docs). `InMemoryStoreTests` (`:58-79`) checks the empty/embedder-unavailable fallback — keep, adjusting the gate comment.

### 6.1 New: `VectorCosineTests.swift` (pure math, no store, no model)
- **`decode` round-trips** `EmbeddingService`'s encode: build `[Float]`, encode via `withUnsafeBytes`, decode back, assert equality; assert `nil` on non-multiple-of-4 / empty.
- **`dot` correctness**: orthogonal vectors → 0; identical unit vectors → ~1.0 (within Float epsilon); opposite → ~−1.0; dimension mismatch → 0.
- **`dot` == manual sum**: cross-check a random vector pair against a naive `zip(...).map(*).reduce(0,+)`.
- **L2-normalized equivalence**: take a few non-unit vectors, normalize, dot — equals the textbook cosine of the originals (proves "dot == cosine for unit vectors").
- **`rankBestChunkPerDoc`**: seed `(docID, embedding)` candidates where one doc has multiple chunks — assert the doc's best (max-sim) chunk wins; assert output is most-similar-first; assert `pool` truncation; assert decode-failures are skipped (feed a malformed blob for one chunk, confirm that doc still ranks via its good chunk or is dropped if all bad).
- **Golden ordering vs sqlite-vec math**: this is the correctness anchor. Since `vec_distance_cosine` is just `1 − dot`, build the SAME candidate set, compute both orderings in-test (Swift dot vs `1 − dot` sorted asc), assert the doc-ID sequence is **identical**. (No live sqlite-vec needed — the math equivalence is provable in pure Swift.) This is the closest thing to the sqlite-vec baseline without the C dependency.

### 6.2 New: `SemanticSearchSwiftCosineTests.swift` (store-level, in-memory, deterministic embeddings)
- Use `TestStoreFactory.inMemory()` and seed `*_chunks` with **hand-crafted unit vectors** (bypass `EmbeddingService`, which is app-gated under `swift test`) via the public `storePageChunks`/`storeSourceChunks`/`storeChatChunks`. Construct a query vector with a known nearest neighbor.
- **Pages**: assert `searchSimilar` returns the expected doc first; assert best-chunk-per-doc (a doc with a near-miss chunk + an exact chunk ranks by the exact one); assert `.prefix(limit)` respected; assert RRF still fuses with a synthetic `bm25Leg` (a doc high in BM25 but low in cosine fuses correctly — preserves existing `RankFusion` behavior).
- **Sources** & **Chats**: mirror the above (the three queries are structurally identical; cover all three).
- **Gate behavior**: with no chunks seeded and `EmbeddingService` unavailable, `searchSimilar(... bm25Leg: nil)` returns `[]` (matches `InMemoryStoreTests:72`).
- **Determinism / no-`SELECT *`**: carry over `SourceEmbeddingSearchTests.searchSimilarSourcesNeverSelectsStar` (`:152`) — assert the rewritten query selects explicit columns.

### 6.3 Regression: full suite
- `make test` (== `swift test`, ~1.5 min, in-memory fixtures). Must be green. Particularly: `EmbeddingMetaCutoverTests`, `TantivyBM25LegCutoverTests`, `SourceEmbeddingSearchTests`, `InMemoryStoreTests`.
- `StoreConcurrencyTests` — confirm the off-main read still goes through a pool reader (no statement/state leaks, #332 discipline). The new read query is a plain `Row.fetchAll` on the same `db` the search method already holds — no new concurrency surface.

### 6.4 Manual / app-gated (not in `swift test`, document for the implementer)
- NLEmbedding/MiniLM are app-gated, so the *real* ranking can't run under `swift test`. The implementer should sanity-check in the running app (or via `wikictl` if it adopts the ranker) that semantic search for a known page returns sensible neighbors. This is a smoke check, not automated.

---

## 7. Acceptance criteria

- [ ] `searchSimilar` / `searchSimilarSources` / `searchSimilarChats` rank the semantic leg via Swift-side dot product over L2-normalized vectors read from `*_chunks`, fused into `RankFusion.rrf` exactly as today (same input shape: a most-similar-first `[WikiPageSummary]`/`[SourceSummary]`/`[ChatSummary]`).
- [ ] **Golden equivalence:** `VectorCosine` ordering == sqlite-vec `MIN(vec_distance_cosine) GROUP BY doc` ordering for identical embeddings (proven in §6.1, golden-set).
- [ ] `rg "vec_distance_cosine|wikifs_vec_register|CSqliteVec|sqlite-vec|isVecAvailable|vecRegisteredForTesting" Sources Tests` returns **zero** hits.
- [ ] `CSqliteVec` Package target + `Sources/CSqliteVec/` directory deleted; `Package.swift` has no `CSqliteVec` target or dependency.
- [ ] No C extension registered on any connection path (RW pool, File Provider RO pool, in-memory test queue).
- [ ] Existing wiki DBs with populated `*_chunks` open and search cleanly — **no schema migration** (plain tables, unaffected by removing the scalar function).
- [ ] `make build` + `make test` green; no new `print` (use `DebugLog`); no bare `try?` swallowing errors.
- [ ] MIT-clean: no sqlite-vec (or any C vector extension) source remains in the tree.

---

## 8. Gotchas & risks

1. **Off-main reads via WikiReadPool / pool readers.** The search methods already run inside `dbWriter.read { db in ... }` — a GRDB pool reader. The new read query (`SELECT ... FROM *_chunks`) runs on that same `db`; **no new concurrency surface**, no new connection. Do NOT open a separate read connection or run embedding/`vDSP` math inside a transaction. Statement handles must not cross the closure boundary (`defer { reset }` is GRDB-managed via `Row.fetchAll`, so fine). (SQLite-concurrency skill / #332.)

2. **Pulling all chunk rows into Swift memory is fine NOW, but note the threshold.** A wiki with N chunks × 512 floats × 4 B = N×2 KB. 5k chunks ≈ 10 MB, 50k ≈ 100 MB — trivially in-process. The threshold where a full table scan + Swift-side sort (O(N log N)) loses to an indexed SQL approach is roughly **100K+ vectors** (this is exactly why sqlite-vector's SIMD was rejected as premature — the embedding-model call dominates latency at current scale). If/when a single wiki exceeds ~50–100k chunks, revisit (options: pre-filter by Tantivy/BM25 candidate set, or revisit an indexed vector store). **Document this threshold in `VectorCosine`/a code comment.** This plan is explicitly scoped to "current scale."

3. **L2-normalization correctness is load-bearing.** Swift dot product == cosine **iff** stored vectors are unit-norm. This is guaranteed by the `Embedder` contract + `MiniLMEmbedder`'s explicit re-normalize (§2.5). The §6 golden test is the safety net. If it ever fails, the bug is in an embedder, not in #628 — fix the embedder, don't paper over it with query-time normalize (though that's available as a defensive option, §5).

4. **`RankFusion.rrf` input shape MUST be unchanged.** It takes `[[T]]` where each inner list is already best-first, dedupes by `\.id`, scores `1/(k+rank)`. The Swift path must hand it a most-similar-first list of the SAME summary type. Do not change `rrf`'s signature or the `k=60` constant.

5. **The File Provider read-only connections no longer register the extension** (deletion #6). This is correct and intended — the RO pool never wrote vec vtabs (these are plain tables); it only needed the scalar for reads, which are now Swift-side. Confirm the File Provider search path (if it calls `searchSimilar*`) still works — it will, since it now only needs a plain `SELECT`.

6. **`WITHOUT ROWID` tables.** `*_chunks` are clustered on `(doc_id, chunk_idx)`. A full-table `SELECT doc_id, embedding` is a sequential scan of the clustered index — fine at scale (see #2). No index needed for the Swift path (it reads everything).

7. **Decode alignment.** `Data.withUnsafeBytes` + `assumingMemoryBound(to: Float.self)` is safe because `Data`'s storage is suitably aligned for `Float`; the encode side (`floats.withUnsafeBytes { Data($0) }`) guarantees the byte layout. Guard the `% 4 == 0` check (defensive).

8. **Tie-breaking.** The SQL path's `ORDER BY best ASC` has an unspecified tie-break (no secondary key). `VectorCosine` sorts by similarity desc with a Swift-stable-ish order; `RankFusion.rrf` is robust to equal-rank ties (they get equal RRF contribution). Fused output is equivalent; exact per-doc order among equal-distance docs is not guaranteed identical to sqlite-vec, but that's noise below the RRF threshold — acceptable and not a quality regression.

9. **`wikictl`.** Today `wikictl` uses the FTS5/Tantivy fallback path and is app-gated on embeddings. No `wikictl` change required for #628 (per issue #628 "Out of scope"). Optionally, `wikictl` could adopt `VectorCosine` later — out of scope here.

10. **Sequencing vs #625 (bundle SQLite amalgamation).** Land **#628 FIRST** (issue #628's recommendation). Removing `CSqliteVec` before #625 starts means #625's bundled-amalgamation work doesn't have to preserve the `-DSQLITE_CORE` static-link vec pattern or resolve the `sqlite3.h` header dance against the new `CSQLite` target. Cleaner architectural order; no throwaway integration. The two are independent in *correctness* but coupled in *build config*.

---

## 9. Files to modify (exact, consolidated)

**Add:**
- `Sources/WikiFSSearch/VectorCosine.swift` (new — §3.2)
- `Tests/WikiFSTests/VectorCosineTests.swift` (new — §6.1)
- `Tests/WikiFSTests/SemanticSearchSwiftCosineTests.swift` (new — §6.2)

**Modify:**
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift` — drop `import CSqliteVec` (`:4`); rewrite the 3 queries (`:5331-5341`, `:5415-5425`, `:5969-5979`) to the Swift-cosine read path (§3.3); swap the `isVecAvailable` gates (`:5326`, `:5410`, `:5964`) → `EmbeddingService.isAvailable`; remove the 3 `wikifs_vec_register` blocks (`:147-155`, `:224-227`, `:269-272`); remove `isVecAvailable` (`:6190-6192`); fix `reembedSource` gate (`:6449-6450`); remove/repurpose `vecRegisteredForTesting` (`:7517-7519`); update comment wording (`:829`, `:6432`, `:7512-7516`).
- `Sources/WikiFSCore/Store/WikiStore.swift` — comment wording (`:557`, `:580`).
- `Sources/WikiFSSearch/Embedder.swift` — comment wording (`:7`).
- `Sources/WikiFSSearch/EmbeddingService.swift` — comment wording (`:9`).
- `Sources/WikiFSSearch/Package.swift` target (`:118-129`) — add `linkerSettings: [.linkedFramework("Accelerate")]` if `import Accelerate` doesn't auto-link (verify at build; macOS usually auto-links it).
- `Package.swift` — remove `CSqliteVec` target (`:64-73`) + the `WikiFSCore` dependency entry (`:137`).

**Delete:**
- `Sources/CSqliteVec/` (entire directory: `CSqliteVec.c`, `sqlite-vec.c`, `include/CSqliteVec.h`, `README.md`)

**Update tests:**
- `Tests/WikiFSTests/SourceEmbeddingSearchTests.swift` — rewrite `vecScalarIsRegisteredAfterStaticLink` (`:72-79`) to the Swift-side assertion; keep `searchSimilarSourcesNeverSelectsStar` (`:152`).
- `Tests/WikiFSTests/InMemoryStoreTests.swift` — adjust gate-related comments (`:58-79`); behavior unchanged.

---

## 10. Open questions / things to confirm at build time

- **Does `import Accelerate` auto-link in the `WikiFSSearch` target, or is `linkerSettings: [.linkedFramework("Accelerate")]` required?** `WikiFSMLX` already imports Accelerate successfully — mirror its Package config. Confirm with `make build`.
- **NLEmbedding unit-norm guarantee** — asserted by the `Embedder` contract and standard for `NLEmbedding.vector(for:)`, but not unit-tested (model is app-gated). The §6.1 golden-equivalence test proves the *math*; a real-DB smoke test (§6.4) proves the *data*. If a real DB ever shows a non-unit stored vector, that's an embedder bug to fix separately (§5 defensive option is the fallback).
- **`vecRegisteredForTesting` removal impact** — grep confirms only `SourceEmbeddingSearchTests.swift:78` reads it. Rewriting that one test (§6) is the complete fix.

---
