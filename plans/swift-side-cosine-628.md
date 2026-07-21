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

- **Definition + probe** — `GRDBWikiStore.swift:6190-6192`
- **Call sites of `isVecAvailable`**: the three search queries above (`:5326`, `:5410`, `:5964`) and `reembedSource` (`GRDBWikiStore.swift:6449`). `reembedSource` uses it as a "can we store+rank embeddings?" gate.
- **`vecRegisteredForTesting` test hook** — `GRDBWikiStore.swift:7517-7519` (`#if DEBUG`), wraps `isVecAvailable`.

### 2.3 `wikifs_vec_register` — THREE call sites

| Init | Line | Context |
|------|------|---------|
| `init(databaseURL:)` (file-backed pool, RW) | **`:147-155`** | main store |
| `init(readOnlyURL:)` (File Provider, RO) | **`:224-227`** | read-only pool |
| `init()` (in-memory `DatabaseQueue`, `#if DEBUG`) | **`:269-272`** | tests |

### 2.4 The `CSqliteVec` Package target + dependency

- **Target definition** — `Package.swift:64-73`
- **Dependent** — `Package.swift:137`, the `WikiFSCore` target's `dependencies: ["CSqliteVec", ...]`.
- **Source dir** — `Sources/CSqliteVec/` — delete entirely.

### 2.5 How embeddings are STORED — **L2-normalized at write time (CONFIRMED)** ✅

- **`Embedder` protocol contract** (`Sources/WikiFSSearch/Embedder.swift:18-20`)
- **`MiniLMEmbedder`** (`Sources/WikiFSMLX/MiniLMEmbedder.swift:59-73`): mean-pools with `normalize: true` then **re-normalizes exactly** via `vDSP_svesq`
- **`NLEmbedder`** (`Sources/WikiFSSearch/NLEmbedder.swift:34-37`): returns unit-length vectors

**BLOB format** (`EmbeddingService.embeddingBlob`, `EmbeddingService.swift:110`): `floats.withUnsafeBytes { Data($0) }` — raw little-endian Float32, contiguously packed.

### 2.6 Chunk table schema

Plain `WITHOUT ROWID` tables (NOT `vec0` vtabs) — no schema migration needed:
```sql
CREATE TABLE page_chunks (
    page_id   TEXT NOT NULL REFERENCES pages(id) ON DELETE CASCADE,
    chunk_idx INTEGER NOT NULL,
    embedding BLOB NOT NULL,
    PRIMARY KEY (page_id, chunk_idx)
) WITHOUT ROWID;
-- source_chunks / chat_chunks identical shape (source_id / chat_id).
```

---

## 3. Swift-side cosine design

### 3.1 The math

`vec_distance_cosine(a, b)` = **1 − cos_sim(a, b)** = 1 − (a·b)/(|a||b|). For unit vectors, |a|=|b|=1, so distance = 1 − (a·b) ⟹ similarity = a·b = 1 − distance.

- `MIN(vec_distance_cosine(...)) GROUP BY doc` ⇒ the **max** dot product per doc.
- `ORDER BY best ASC` (ascending distance) ⇒ **descending similarity** ⇒ most-similar-first.

### 3.2 New helper — `VectorCosine` (in `Sources/WikiFSSearch/`)

A small, dependency-free, fully unit-testable enum. Pure `[Float]` math + the best-chunk-per-doc ranker. No DB, no GRDB import.

### 3.3 The read-query change (in `GRDBWikiStore`)

Drop `vec_distance_cosine` entirely. The semantic leg reads all candidate chunk rows + summary columns in one query, decodes + dot-products in Swift, groups by doc keeping max sim, sorts desc, truncates to `pool`.

### 3.4 Why `WikiFSSearch`, not `GRDBWikiStore`

`VectorCosine` is pure `[Float]`/`Data` math with zero DB coupling → testable in isolation, reusable by `wikictl` or any future caller. `WikiFSCore → WikiFSSearch` is the existing dependency direction.

---

## 4. Retire `CSqliteVec` (the deletion)

1. Delete `Sources/CSqliteVec/` (entire directory)
2. Remove `.target(name: "CSqliteVec", ...)` from `Package.swift`
3. Remove `"CSqliteVec"` from `WikiFSCore` dependencies
4. Remove `import CSqliteVec` from `GRDBWikiStore.swift:4`
5. Remove the 3 `wikifs_vec_register` blocks (`:147-155`, `:224-227`, `:269-272`)
6. Remove `isVecAvailable` (`:6190-6192`)
7. Swap `isVecAvailable` gates → `EmbeddingService.isAvailable` (`:5326`, `:5410`, `:5964`, `:6449`)
8. Remove/repurpose `vecRegisteredForTesting` (`:7517-7519`)
9. Update comment-only wording

After deletion: `rg "vec_distance_cosine|wikifs_vec_register|CSqliteVec|isVecAvailable|sqlite-vec" Sources Tests` must return **zero** hits.

**Order:** (a) add `VectorCosine` + tests; (b) switch the three queries + gates; (c) remove `CSqliteVec`.

---

## 5. Normalization — decision

**v1 (preferred):** assume unit-norm, dot product only. Document the invariant.

**Defensive fallback (only if golden-set test reveals non-unit stored vectors):** add `vDSP_normalize` on decode.

---

## 6. Testing plan (Swift Testing)

### 6.1 `VectorCosineTests.swift` (pure math, no store, no model)
- `decode` round-trips
- `dot` correctness (orthogonal→0, identical→1, opposite→-1, mismatch→0)
- `dot` == manual sum
- L2-normalized equivalence
- `rankBestChunkPerDoc` (multi-chunk, most-similar-first, truncation, decode-failure skip)
- Golden ordering vs sqlite-vec math equivalence (Swift dot vs `1 − dot` asc)

### 6.2 `SemanticSearchSwiftCosineTests.swift` (store-level, in-memory)
- Seed `*_chunks` with hand-crafted unit vectors via public store API
- Pages/Sources/Chats: assert ranking + RRF fusion
- Gate behavior: no chunks + embedder unavailable → `[]`
- No `SELECT *` carryover

### 6.3 Regression: `make test` (~1.5 min, in-memory fixtures)

### 6.4 Manual / app-gated smoke check

---

## 7. Acceptance criteria

- [ ] `searchSimilar*` rank via Swift-side dot product, fused into `RankFusion.rrf` exactly as today
- [ ] Golden equivalence: `VectorCosine` ordering == sqlite-vec `MIN(vec_distance_cosine) GROUP BY doc` ordering
- [ ] `rg "vec_distance_cosine|wikifs_vec_register|CSqliteVec|sqlite-vec|isVecAvailable|vecRegisteredForTesting" Sources Tests` returns **zero** hits
- [ ] `CSqliteVec` target + `Sources/CSqliteVec/` deleted; `Package.swift` clean
- [ ] No C extension registered on any connection path
- [ ] Existing wiki DBs open and search cleanly — no schema migration
- [ ] `make build` + `make test` green; no new `print`; no bare `try?`
- [ ] MIT-clean: no sqlite-vec source in tree

---

## 8. Gotchas & risks

1. **Off-main reads** — new query runs on same `db` the search method already holds; no new concurrency surface
2. **Scale threshold** — full table scan is fine now; revisit at ~100K+ vectors
3. **L2-normalization is load-bearing** — guaranteed by `Embedder` contract + `MiniLMEmbedder` re-normalize
4. **`RankFusion.rrf` input shape unchanged** — most-similar-first list of same summary type
5. **File Provider RO pool** — no longer registers extension; plain `SELECT` is enough
6. **`WITHOUT ROWID` tables** — sequential scan of clustered index, fine at scale
7. **Decode alignment** — `Data.withUnsafeBytes` + `assumingMemoryBound(to: Float.self)` is safe
8. **Tie-breaking** — `RankFusion.rrf` robust to equal-rank ties
9. **`wikictl`** — no change required
10. **Sequencing vs #625** — land #628 FIRST

---

## 9. Files to modify (consolidated)

**Add:**
- `Sources/WikiFSSearch/VectorCosine.swift`
- `Tests/WikiFSTests/VectorCosineTests.swift`
- `Tests/WikiFSTests/SemanticSearchSwiftCosineTests.swift`

**Modify:**
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift`
- `Sources/WikiFSCore/Store/WikiStore.swift`
- `Sources/WikiFSSearch/Embedder.swift`
- `Sources/WikiFSSearch/EmbeddingService.swift`
- `Package.swift`

**Delete:**
- `Sources/CSqliteVec/` (entire directory)

**Update tests:**
- `Tests/WikiFSTests/SourceEmbeddingSearchTests.swift`
- `Tests/WikiFSTests/InMemoryStoreTests.swift`
