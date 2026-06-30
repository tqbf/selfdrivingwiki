# MLX all-MiniLM-L6-v2 on-device embeddings — design of record (shipped)

> **Status: shipped** (PR #96, branch `feature/minilm-metal-embeddings`). This
> doc records what was actually built. The original pre-implementation plan
> proposed an off-main `Task.detached` backfill (Phase 3); that was implemented,
> caused two launch crashes, and was **reversed** into a main-thread-only,
> blocking upgrade. Those reversals are the most important parts of this doc —
> read "The SQLite invariant" before touching anything near the store.

## Goal
Replace Apple `NLEmbedding` (512-dim, opaque, ≈5 s/100k chars, crashes off-main
and above ~250k chars) with MLX `all-MiniLM-L6-v2` (384-dim) on Metal/GPU behind
`EmbeddingService`: ~100–1000× faster, safe off-main, predictable 512-token
truncation, better quality. The chunk index + best-chunk-per-doc query
(`page_chunks`/`source_chunks`, `vec_distance_cosine`, RRF fusion) is
embedder-agnostic, so this is a swap behind `EmbeddingService` — no search/query
architecture change beyond the dimension cutover.

## Architecture

### `Embedder` protocol (`Sources/WikiFSCore/Embedder.swift`)
The store depends on the abstraction, not NLEmbedding:

```swift
public protocol Embedder: Sendable {
    static var identifier: String { get }   // "nlembedding-512" | "minilm-384"
    var dimension: Int { get }              // 512 | 384
    func vector(for text: String) -> [Float]?   // one L2-normalized vector
}
```

`EmbeddingService` (`Sources/WikiFSCore/EmbeddingService.swift`) holds the active
embedder behind an `NSLock`, selected at launch:
- `MiniLMEmbedder` when the bundled model dir (`all-MiniLM-L6-v2/`) is present;
- `NLEmbedder` (the prior behavior) as the fallback (a build without the model,
  tests, `wikictl`).

Entry points: `embeddingBlob(for:)` (one vector for a short query),
`chunkedEmbeddings(for:maxChunks:)` (one vector per `TextChunker` chunk),
`chunks(for:)` (split only), `configure()` (async, loads the model once).

### Target isolation: MLX lives in `WikiFSMLX`, NOT `WikiFSCore` ⚠️
**`MLXEmbedders` is a dependency of the app-only `WikiFSMLX` target, never
`WikiFSCore`.** The File Provider extension (`com.apple.fileprovider-nonui`)
links `WikiFSCore`; MLX → Metal, and Metal is forbidden in that extension on
macOS 26 (it asserts in `_EXRunningExtension._start`). The first cut of this
work added `MLXEmbedders` to `WikiFSCore` and pulled Metal into the extension;
`Package.swift` now keeps `WikiFSCore` Metal-free. `MiniLMEmbedder` and
`EmbedderBootstrap` all live in `WikiFSMLX`.

Core reaches the implementation through an injectable seam rather than a direct
dependency: `EmbeddingService.miniLMFactory` (a `(URL) async throws -> any
Embedder`). The app installs it at launch:

```swift
// WikiFSMLX/EmbedderBootstrap.install(), called from WikiFSApp.init
EmbeddingService.miniLMFactory = { modelDirectoryURL in
    try await withError {                          // see "MLX error handling"
        try await MiniLMEmbedder(modelDirectoryURL: modelDirectoryURL)
    }
}
```

Non-app contexts (extension, `wikictl`, tests) keep the `nil` factory → MiniLM
unavailable → `NLEmbedder` fallback.

### `MiniLMEmbedder` pipeline (`Sources/WikiFSMLX/MiniLMEmbedder.swift`)
Load once via `MLXEmbedders.loadModelContainer(...)`; per text, inside
`container.perform { model, tokenizer, pooler in … }`: forward → mean-pool +
L2-normalize (`pooler(output, normalize: true)`, matching `sentence-transformers`)
→ `asType(.float32).toArray(Float.self)` → `[Float]` (384). `@unchecked Sendable`
(`ModelContainer` is thread-safe; the conformance is asserted manually).

## Model + metallib sourcing (operational, load-bearing)

- **Model:** `mlx-community/all-MiniLM-L6-v2-bf16` (~45 MB). **Gitignored, never
  committed.** Fetched on demand by `tools/minilm-prepare/download.py` (idempotent
  "ensure present", pinned HF revision + recorded SHA). `build.sh` runs the
  prepare step if absent and copies the dir into the `.app`'s `Resources/`. The
  shipped app is offline/self-contained; the source repo stays lean.
- **metallib:** `swift build` cannot compile MLX's Metal shaders (needs
  `xcodebuild`), so a **prebuilt, version-matched** `mlx.metallib` (~107 MB,
  from the `mlx-metal` wheel matched to mlx-swift's vendored MLX C++ version) is
  bundled. A mismatched metallib **silently corrupts GPU output** — the version
  pin in `download.py` is load-bearing; re-match it when bumping `mlx-swift`.

### Where the metallib must live (the launch-crash finding) ⚠️
MLX's C++ `load_default_library` searches for `mlx.metallib` **relative to the
binary** (`<binary_dir>/mlx.metallib`, then `<binary_dir>/Resources/mlx.metallib`)
— **not** via `NSBundle`. The app binary is in `Contents/MacOS/`, so a
`Contents/Resources/mlx.metallib` (the standard, signs-as-a-resource spot) is
**never found**. All 5 fallback paths fail and MLX's **default** error handler
calls `exit()` (see below). `build.sh` therefore keeps the file in
`Contents/Resources/` (so it signs correctly) and adds a symlink
`Contents/MacOS/mlx.metallib → ../Resources/mlx.metallib` so the binary-dir lookup
resolves. (A real file in `MacOS/` breaks codesign — a `.metallib` there is an
unsigned code subobject.) The raw `.build/debug` binary works without this because
SwiftPM places the metallib next to the executable.

## MLX error handling (do not let MLX `exit()` the app)
MLX's C++ default error handler prints and calls `exit()` — an **uncatchable**
process death with no `.ips`. mlx-swift only installs its non-fatal handler
**lazily** (first `withError`/`setErrorHandler` call). So `MiniLMEmbedder`
construction is wrapped in `withError { }` (in the factory above): a metallib /
init failure becomes a Swift throw caught by `EmbeddingService.configure()` →
`_embedder` stays `nil` → graceful `NLEmbedder` fallback / upgrade no-op, instead
of `exit()`. Any new MLX call site that can fail must go through `withError`.

## The SQLite invariant (the most important section)
**All `SQLiteWikiStore` access is main-thread only. Off-main is allowed for pure
compute (MLX inference, the JS linter, networking) — never `store.*`.** There is
no background "backfill."

Why this is load-bearing: `SQLiteWikiStore` keeps **one connection** with a
**prepared-statement cache keyed by SQL**. `SQLITE_OPEN_FULLMUTEX` serializes
individual C calls, but it cannot protect the app holding a column pointer across
calls while another thread mutates the same `sqlite3_stmt*`. Two threads running
the same query get the **same cached statement** and interleave
`step`/`reset`/`column_text` → a garbage column read → invalid UTF-8 → a trap
(this is exactly the launch `EXC_BREAKPOINT` in `String(cString:)` the off-main
backfill caused). See `docs/skills/sqlite-concurrency/SKILL.md` and
`docs/skills/debugging-with-lldb/SKILL.md`.

### Bulk embedding = a blocking modal upgrade (not a background task)
`WikiStoreModel.upgradeSearchIndex()` (`@MainActor`, `async`) is the sole bulk
path:

- All SQLite reads (`missingPageEmbeddingWork`/`missingSourceEmbeddingWork`) and
  writes (`storePageChunks`/`storeSourceChunks`) on the main actor.
- **Only the MLX inference hops off-main**, via `embedChunksOffMain` — a
  `Task.detached` that calls `EmbeddingService.chunkedEmbeddings(for:)` and
  touches **no** SQLite.
- A **non-dismissible sheet** (`SearchUpgradeView`, `interactiveDismissDisabled`
  + a no-op binding setter so only the model can end it) blocks all UX while it
  runs → the upgrade is the **sole owner of the store** → no second thread.
- Single-flight via `isUpgrading`, set **before any `await`** (gating on
  `searchUpgrade` itself was too late — a second trigger entered during the
  `configure()` suspension and double-ran it).
- **Skips when there's no work** (warm DB → no sheet, instant launch) and **when
  MiniLM isn't bundled** (no model → never block on the slow NLEmbedder path;
  search falls back to FTS). Triggered by the app layer
  (`WikiManager.upgradeActiveStoreSearchIndex()` from `scenePhase == .active` and
  wiki switch), never from the launch `.task`.

### Incremental content = inline embedding at write time
Don't accumulate "missing" content. The write paths embed their own content
synchronously on the main actor: page upsert → `storePageChunks`
(`PageUpsert.upsert`); source markdown append → `reembedSource`
(`appendProcessedMarkdown`). This keeps the launch upgrade a rare event and makes
new content searchable immediately.

### Metal foreground gating
The upgrade is only triggered while the app is foreground — from
`scenePhase == .active` (and on wiki switch when already active) — so the
historical "submit Metal work while backgrounded → `Insufficient Permission`
crash" does not arise. There is no separate foreground observer; the launch
hook is the gate. (If a future path submits MLX work outside the upgrade, it
must likewise run only while foreground.)

## Dimension cutover (correctness)
`vec_distance_cosine` between a 512-dim and a 384-dim vector is garbage, so a DB
must hold **one** embedder's vectors. `embedding_meta(id=1, embedder)` stores the
active identifier; `SQLiteWikiStore.ensureEmbedderConsistency()` wipes
`page_chunks`/`source_chunks` and updates `embedding_meta` when the selected
embedder differs from the stored one, then the upgrade re-embeds everything. This
is in **both** the fresh-schema path and the migration ladder. `vec_distance_cosine`
queries are unchanged (same-dim operands guaranteed by the cutover).

## Search index (what makes results correct)
- **FTS self-heal fixed.** The launch health check rebuilt FTS5 only when
  `count(*) FROM pages_fts < count(*) FROM pages` — but for an **external-content**
  FTS5 table, `count(*)` reads the content table, so the two are always equal and
  the rebuild **never ran**. Wikis migrated through the schema ladder ended with
  `pages_fts` "232/232" but **zero indexed terms** → MATCH returned nothing →
  search degraded to semantic-only and ranked poorly. The check now probes the
  `_idx` shadow segment b-tree (`ftsIndexRowCount`): `_idx == 0` ⇒ never built ⇒
  rebuild. Applies to `pages_fts` and `sources_fts`.
- **`searchSimilar` / "Find Similar…" restored.** It had been a no-op since
  NLEmbedding froze the main thread; it now delegates to the store's hybrid search
  (FTS5 bm25 always; +MiniLM cosine fused via RRF). Safe because its only caller
  (the link menu) builds its submenu once per right-click, and MiniLM is ms-scale.
- **Defense in depth:** `SQLiteStatement.text(at:)` no longer uses
  `String(cString:)` (traps on invalid UTF-8 / stops at NUL); it decodes by byte
  length with a lossy UTF-8 fallback.

## Verified facts (measured; held through shipping)
- **Parity caveat:** MLX embedding engines diverge from HF/sentence-transformers
  at ~0.99 cosine even on identical weights (a BERT-implementation difference, not
  bf16/precision). A strict ≥0.999-vs-HF bar is **not met and not expected**. The
  embeddings are non-garbage (~0.99, not ~0.17) and self-consistent (paraphrase ≫
  unrelated). Quality is judged empirically (AC.4), not by HF parity.
- **Latency:** median ~8–9 ms / max ~13 ms per chunk on Metal (Swift `MLXEmbedders`);
  model load ~80 ms.
- **NLEmbedding (the fallback):** ≈5 s/100k chars; `std::bad_alloc` (uncatchable)
  ≥ ~250k chars; off-main crashes inside `BNNSFilterApplyBatch`. This is why the
  fallback stays on the main actor and the upgrade skips when MiniLM isn't bundled.
- The chunk index stores opaque Float32 BLOBs compared by `vec_distance_cosine`
  (dimension-agnostic iff both operands match) — the key enabler for the swap.

## Acceptance criteria (status)
- **AC.1 non-garbage + self-consistent:** ✓ (Phase 1, Swift MLXEmbedders).
- **AC.2 latency ≤ ~20 ms/chunk on Metal:** ✓ (~8–13 ms).
- **AC.3 one embedder's dims per DB; cutover wipes + re-embeds:** ✓ (`embedding_meta`).
- **AC.4 hybrid search quality ≥ NLEmbedding:** shipped; the FTS self-heal fix was
  required for real quality (semantic-only ranked poorly).
- **AC.5 launches, no jank, no crash, survives background/foreground:** ✓, with the
  **caveat that "no jank" is achieved by a blocking modal upgrade, not off-main
  work** — the off-main attempt crashed (see History) and was reversed.

## History: why the off-main backfill was reversed
The original Phase 3 plan moved embedding to a `Task.detached` (MLX is safe
off-main). That shipped and then crashed twice, each a launch death:
1. **Silent `exit()`** — MLX couldn't find its metallib (the binary-dir lookup
   above) and its default handler `exit()`d. Found via `lldb` (`os_log` left no
   `.ips` because the death was a clean `exit()`). Fixed by the metallib symlink +
   `withError` wrapping.
2. **`EXC_BREAKPOINT` in `String(cString:)`** — two backfill threads on the single
   connection raced the cached statement (the SQLite invariant above). Fixed
   structurally by making the upgrade main-thread-only behind a modal sheet.

Lesson: "MLX is safe off-main" was true but irrelevant — **SQLite is not safe
off-main in this app**, and the backfill did both. The blocking upgrade makes the
upgrade the sole owner of the store so there is no second thread to race.
