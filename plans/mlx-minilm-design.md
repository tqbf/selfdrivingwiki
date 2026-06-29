# MLX all-MiniLM-L6-v2 on-device embeddings — design

> **Status:** design / not yet implemented. Research complete (see the
> "Verified facts" section and `PROGRESS.md`). This doc is the blueprint;
> implementation is a follow-up (`docs/implementation-plans/2026-06-29-mlx-minilm/`).
>
> **Pivot note:** This supersedes the earlier CoreML/ANE design. CoreML Phase 1
> hit structural problems — torch/coremltools version incompatibility, a
> `torch.jit.trace` `aten::Int` bug, INT8 quantization dropping cosine to 0.9986
> (below the 0.999 gate), and the ANE compiler rejecting the model
> (`ANECCompile FAILED`). MLX removes the entire conversion pipeline: weights
> load directly from HuggingFace with no conversion/quantization.

## Goal
Replace Apple `NLEmbedding` (512-dim) with MLX `all-MiniLM-L6-v2` (384-dim)
running on Metal/GPU, as the embedder behind `EmbeddingService`. Drives the same
four concerns as the original CoreML design, restated for MLX/Metal:

- **Speed:** NLEmbedding ≈ 5 s / 100k chars (a full-corpus first backfill takes
  minutes). MiniLM on Metal/GPU is low-single-digit ms / sentence → **100–1000×
  faster**, fast full backfill.
- **Off-main safety:** NLEmbedding/CoreNLP crashes (`EXC_BAD_ACCESS` in
  `BNNSFilterApplyBatch`) when called off the main thread, forcing the backfill
  onto the main actor with per-chunk UI jank. MLX inference is safe off-main
  (`ModelContainer.perform` serializes access) → the backfill can move back to a
  background queue (jank gone).
- **No crash cliff:** NLEmbedding throws an uncatchable `std::bad_alloc` > ~250k
  chars. MiniLM truncates at 512 tokens predictably (chunking still applies — see
  below).
- **Quality:** MiniLM is open and well-benchmarked (STS-B ≈ 85); NLEmbedding is
  opaque and anecdotally weaker.

The per-chunk index + best-chunk-per-doc query (`page_chunks`/`source_chunks`,
`vec_distance_cosine`, RRF fusion) built in the search PR is **embedder-agnostic**,
so this is a swap behind `EmbeddingService` — no search/query architecture change.

## Verified facts grounding this design
(Research, 2026-06-29, external; sources cited inline.)

- `mlx-community/all-MiniLM-L6-v2` **non-quantized does NOT exist**. Available
  variants: `-bf16`, `-4bit`, `-8bit`. **Use `-bf16`**: no quantization loss →
  near-exact parity; plain BERT (`model_type: bert`); token-level output
  (`last_hidden_state`); `hidden_size = 384`; `max_position_embeddings = 512`;
  ~45 MB.
- MiniLM outputs **token embeddings** → mean-pool + L2-normalize must be applied
  to match `sentence-transformers`. With MLX this pooling is provided by the
  library (not hand-rolled).
- **Official Swift path:** `ml-explore/mlx-swift-lm` ships an `MLXEmbedders`
  library with a BERT implementation, pooling strategies, and a thread-safe
  `ModelContainer`:
  - Load: `loadModelContainer(...)` → `container.perform { model, tokenizer, pooler in ... }`.
  - Pool: `pooler(output, normalize: true)` (mean pool + L2), matching
    `sentence-transformers` parity.
  - Output to `[Float]`: `array.asType(.float32).toArray(Float.self)`.
  - Sources: `mlx-swift-lm` `Libraries/MLXEmbedders/Models/Bert.swift`,
    `Pooling.swift`, `skills/mlx-swift-lm/references/embeddings.md`.
- **Thread safety:** `ModelContainer.perform` serializes model access, so
  inference is safe off-main (from a `Task.detached`). Reuse one container; do
  not create one per call.
- **New risk vs CoreML:** MLX submits Metal GPU work. If the macOS app is
  backgrounded mid-inference, Metal crashes with
  `Insufficient Permission` (`mlx-swift-examples` issue #230). The backfill must
  pause/cancel on app background and resume on foreground. (ANE/CoreML did not
  have this.) See Phase 3 + Risks.
- **Python validation:** `mlx-embeddings` (Blaizzy) or `mlx-transformers` loads
  the bf16 weights directly; compare vs `sentence-transformers` reference. MLX
  loads the exact HF weights with no conversion → parity is near-exact.
- NLEmbedding measured on this machine: 100k chars ≈ 5.1 s, 200k ≈ 8.5 s,
  ≥ ~300k → `std::bad_alloc` (uncatchable C++ exception → terminate). 4k-char
  chunk ≈ 0.3 s. Off-main NLEmbedding crashes inside `BNNSFilterApplyBatch`
  (confirmed via `lldb` break on `__cxa_throw`).
- The chunk index stores raw Float32 BLOBs and compares with
  `vec_distance_cosine` (dimension-agnostic as long as both operands match) — so
  a dim change is fine **iff** every chunk + the query vector use the same dim.

## Architecture

### `Embedder` abstraction
Introduce a single protocol so the store depends on an abstraction, not NLEmbedding:

```swift
public protocol Embedder: Sendable {
    var identifier: String { get }      // e.g. "nlembedding-512", "minilm-384"
    var dimension: Int { get }          // 512 or 384
    func vector(for text: String) -> [Float]?   // one L2-normalized vector for a short string (query)
}
```

`EmbeddingService` holds the active `Embedder` (selected at launch):
- `MiniLMEmbedder` when the model dir (`Resources/all-MiniLM-L6-v2/`) is present;
- `NLEmbedder` (current behavior) as the fallback (e.g. a build where the prepare
  step hasn't downloaded the model yet).

**Model sourcing (not committed):** the model dir is **gitignored** and fetched
on demand by `tools/minilm-prepare/download.py` (an idempotent "ensure present"
step pinned to a HF revision, recording the resolved SHA for reproducibility).
`build.sh` runs/depends on that prepare step and copies the model dir into the
.app bundle, so the **shipped app is self-contained/offline** while the **source
repo stays lean**.

`EmbeddingService.embeddingBlob(for:)` / `chunkedEmbeddings(for:)` / `chunks(for:)`
delegate to the active embedder and serialize its `[Float]` to a Float32 BLOB.

### `MiniLMEmbedder` pipeline (Swift)
1. Load the MLX model once (async) from the bundled model dir via
   `MLXEmbedders.loadModelContainer(...)` → a `ModelContainer`.
2. For each text: tokenize + forward + mean-pool + L2-normalize inside
   `container.perform { model, tokenizer, pooler in ... }`.
   - `let output = model(input)`
   - `let pooled = pooler(output, normalize: true)` (mean pool + L2, matching
     `sentence-transformers`).
3. Convert to `[Float]` (384) via `pooled.asType(.float32).toArray(Float.self)`.
4. Return `[Float]` (384). `EmbeddingService` packs to `Data` (384 × 4 bytes).

The embedder is `@unchecked Sendable` — `ModelContainer` is thread-safe, but the
type is not automatically `Sendable`, so the conformance is asserted manually.

### Dimension cutover (the critical correctness concern) — UNCHANGED from original
`vec_distance_cosine` between a 512-dim and a 384-dim vector is undefined garbage,
so a DB must contain **one** embedder's vectors only. Cutover design:

- New tiny table `embedding_meta(id INTEGER PRIMARY KEY CHECK(id=1), embedder TEXT NOT NULL)`,
  seeded with the active embedder's `identifier`.
- On open, if `activeEmbedder.identifier != stored.embedder`:
  `DELETE FROM page_chunks; DELETE FROM source_chunks; UPDATE embedding_meta SET embedder=?;`
  then the existing async backfill re-embeds everything in the new dim (it already
  embeds "documents missing chunks" — after the wipe, all are missing).
- This makes the switch self-healing and idempotent, mirroring the FTS self-heal.
- Add `embedding_meta` to **both** the fresh-schema path and the `migrate(from:)`
  ladder (schema v15) — the repo's `freshFastPathMatchesStepwiseLadder` parity
  test enforces they stay identical; seed it with the established baseline
  (`nlembedding-512`) at creation, updated to the active embedder on first open.

### Chunking
Keep `TextChunker` (~4k-char chunks) — MiniLM's 512-token limit means a 4k-char
chunk still truncates internally, which is fine (truncation, not a crash).
Optionally tune chunk size down (~1–2k chars ≈ ≤ 512 tokens) once MiniLM is in,
so chunks aren't silently truncated — revisit after benchmarking recall.

## Phased implementation
(See `docs/implementation-plans/2026-06-29-mlx-minilm/` for executable detail.)

### Phase 0 — Prepare + validate the MLX model (Python, offline)
- `uv` env (Python 3.12) in `tools/minilm-prepare/` with `mlx`, `mlx-embeddings`
  (or `mlx-transformers`), `sentence-transformers`, `numpy`, `scipy`,
  `huggingface_hub`. Guard `HF_HUB_ENABLE_HF_TRANSFER`.
- `download.py` (idempotent "ensure present") fetches
  `mlx-community/all-MiniLM-L6-v2-bf16` → `Resources/all-MiniLM-L6-v2/`, pinned to
  a HF `revision` and recording the resolved SHA. **The model dir is gitignored —
  never committed.** It is the prepare/regen step for dev, tests, and the build.
- **Validate** against `sentence-transformers` reference: mean-pool + L2 the MLX
  embeddings, assert min cosine ≥ 0.999 on a probe set. **Gate — do not proceed
  until it passes.**
- Deliverables: validation report (cosine numbers + resolved SHA),
  `Resources/all-MiniLM-L6-v2/` (local, gitignored).

### Phase 1 — Swift inference, isolated (no app wiring)
- Add `mlx-swift-lm` + `MLXEmbedders` to `Package.swift` (`WikiFSCore`).
- `MiniLMEmbedder` (async init loads the container from the local model dir;
  `vector(for:)` runs `container.perform { ... pooler(output, normalize:true) ... }`).
- **First task: a throwaway compile check** that the `MLXEmbedders` API matches
  the snippet above (loadModelContainer / perform / pooler); adjust to the real
  installed signatures if they differ.
- Tests: output dim = 384, L2-norm (‖v‖₂ ≈ 1), cosine ≥ 0.999 vs the Phase-0
  reference vectors, latency ≤ ~20 ms (warm). **Tests require the Phase 0 prepare
  step to have run** (model downloaded locally). De-risks inference before touching
  the store.

### Phase 2 — Wire into `EmbeddingService`
- Add `Embedder` protocol + `NLEmbedder` (wrap current code) + `MiniLMEmbedder`.
- Select at launch (MiniLM if model dir present, else NLEmbedder).
- Add `embedding_meta` + the cutover wipe in `ensureSearchIndexesPopulated()`
  (schema v15 via the raw-C migration ladder).
- `vec_distance_cosine` queries unchanged (same-dim operands guaranteed).
- `build.sh`: ensure the prepare step has downloaded the model (run
  `tools/minilm-prepare/download.py` if `Resources/all-MiniLM-L6-v2/` is absent),
  then conditionally copy it into the .app bundle.

### Phase 3 — Off-main backfill (the payoff) + Metal backgrounding safety
- MiniLM is safe off-main → move the per-chunk embedding work off the main actor
  (into a background `Task.detached`), eliminating the current `@MainActor` +
  `Task.yield()` jank-mitigation that NLEmbedding/BNNS required. (NLEmbedder
  fallback keeps the `@MainActor` path.)
- **Metal backgrounding handling (new vs CoreML):** subscribe to
  `NSApplication.willResignActiveNotification` / `didBecomeActiveNotification`;
  the backfill loop checks an `isAppActive` flag before each inference and
  yields/sleeps while inactive — do NOT submit Metal work while backgrounded.
  Resume on foreground. This prevents the `Insufficient Permission` Metal crash
  during a long backfill if the user backgrounds the app.
- Re-measure full-corpus first-backfill wall time; expect minutes → seconds.

## Acceptance criteria
- **AC.1** `MiniLMEmbedder.vector(for:)` cosine ≥ 0.999 vs the Python reference on
  a fixed probe set.
- **AC.2** Per-chunk latency ≤ ~20 ms on the target machine (**Metal/GPU** — was
  "ANE" in the CoreML design).
- **AC.3** A DB opened with MiniLM active has only 384-dim chunks; switching
  embedders wipes + re-embeds automatically (`embedding_meta` driven).
- **AC.4** Hybrid search (FTS + vec + RRF) returns equivalent-or-better results
  to NLEmbedding on a hand-curated query set.
- **AC.5** The app launches and the first backfill completes with **no UI jank**
  (off-main) and no crash — including surviving a background/foreground cycle
  mid-backfill (Metal backgrounding handled).

## Test strategy
- **Phase 0:** Python validation script asserts cosine ≥ 0.999 (gate; not in CI).
- **Phase 1:** isolated unit tests: output dim = 384, cosine-vs-reference, L2-norm,
  latency benchmark (≤ 20 ms warm on Metal/GPU).
- **Phase 2:** store tests — `embedding_meta` cutover wipes chunks on embedder
  change; backfill re-embeds in the new dim; vec query returns results;
  `FreshSchemaParityTests` updated to v15.
- **Phase 3:** hosted/integration check that the off-main backfill populates
  chunks without blocking the main actor (latency probe), plus a manual
  background/foreground-during-backfill check (no Metal crash). Reuse the
  `reproducing-live-ui-bugs` os_log approach if live verification is needed.
- Python tests are NOT in CI (per repo convention) — run manually when changing
  the model.

## Review strategy
- Plan-mode: this design was reviewed (plan-reviewer) before handoff.
- Implementation: after Phase 1 (inference validated) and Phase 2 (wired),
  dispatch a `general-purpose` review subagent; fix/rebut all critical findings,
  re-review until clean.

## Documentation strategy
- This `plans/mlx-minilm-design.md` is the design of record.
- Update `PROGRESS.md` per phase and `EmbeddingService` doc comments.
- Update `PLAN.md` index to point here.
- Note the bundle-size impact and the embedder-selection/fallback behavior in
  `plans/architecture.md` if it documents the storage layer.

## Risks, blockers, decisions
- **MLXEmbedders API stability (top risk):** the research snippet
  (loadModelContainer / perform / pooler) is source-cited but may differ in
  detail from the installed version. Mitigation: Phase 1's first task is a
  compile-check against the real API; adjust to actual signatures. Do not assume
  the snippet compiles verbatim.
- **Metal backgrounding crash (new vs CoreML):** genuine new risk. Mitigation:
  Phase 3 pauses/resumes the backfill on app-state changes. Documented in AC.5.
- **App bundle size:** +~45 MB (bf16 model dir) in the **shipped .app**. The
  model is **not committed to the repo** (gitignored); it's downloaded at
  build/prepare time from a pinned HF revision + recorded SHA, so the source repo
  stays lean and the build is reproducible. The shipped app is self-contained/offline.
- **MLX dependency footprint:** `mlx-swift-lm` adds to app size vs CoreML's
  runtime that ships with macOS. Accepted tradeoff for removing the conversion
  pipeline.
- **Decision (made):** use `mlx-community/all-MiniLM-L6-v2-bf16` — the requested
  non-quantized `all-MiniLM-L6-v2` does not exist in MLX format; bf16 is the
  best-parity variant.
- **Decision (made):** download the model on demand (gitignored, pinned HF
  revision + recorded SHA) and bundle it into the .app at build time — not commit
  it to the repo. This keeps the repo lean + the build reproducible while leaving
  the shipped app offline and the "model present → MiniLM" selection unchanged.
  (First-launch download via MLX `HubClient` is a noted future alternative if app
  size ever matters more than offline-first.)
- **Cutover data cost:** first MiniLM backfill re-embeds the whole corpus — but
  at MiniLM speed that's seconds-to-a-minute, not minutes. One-time.
- **Embedder-agnostic index is the key enabler:** because chunks are opaque BLOBs
  compared by `vec_distance_cosine`, this whole effort is a behind-the-scenes swap
  with no query/schema-for-search change (only the `embedding_meta` cutover helper).
