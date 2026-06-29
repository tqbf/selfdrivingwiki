# CoreML all-MiniLM-L6-v2 on-device embeddings — design

> **Status:** design / not yet implemented. Research complete (see
> `PROGRESS.md` "Deferred: CoreML all-MiniLM-L6-v2"). This doc is the blueprint;
> implementation is a follow-up.

## Goal
Replace Apple `NLEmbedding` (512-dim) with a CoreML-converted
`sentence-transformers/all-MiniLM-L6-v2` (384-dim) running on the Apple Neural
Engine, as the embedder behind `EmbeddingService`. Drives:

- **Speed:** NLEmbedding ≈ 5 s / 100k chars (a full-corpus first backfill takes
  minutes). MiniLM on ANE ≈ 5–15 ms / sentence → **100–1000× faster**.
- **Off-main safety:** NLEmbedding/CoreNLP crashes (`EXC_BAD_ACCESS` in
  `BNNSFilterApplyBatch`) when called off the main thread, forcing the backfill
  onto the main actor with per-chunk UI jank. CoreML/ANE inference is safe
  off-main → the backfill can move back to a background queue (jank gone).
- **No crash cliff:** NLEmbedding throws an uncatchable `std::bad_alloc` > ~250k
  chars. MiniLM truncates at 512 tokens predictably (chunking still applies — see
  below).
- **Quality:** MiniLM is open and well-benchmarked (STS-B ≈ 85); NLEmbedding is
  opaque and anecdotally weaker.

The per-chunk index + best-chunk-per-doc query (`page_chunks`/`source_chunks`,
`vec_distance_cosine`, RRF fusion) built in the search PR is **embedder-agnostic**,
so this is a swap behind `EmbeddingService` — no search/query architecture change.

## Verified facts grounding this design
- NLEmbedding measured on this machine: 100k chars ≈ 5.1 s, 200k ≈ 8.5 s, ≥ ~300k
  → `std::bad_alloc` (uncatchable C++ exception → terminate). 4k-char chunk ≈ 0.3 s.
- Off-main NLEmbedding crashes inside `BNNSFilterApplyBatch` (confirmed via `lldb`
  break on `__cxa_throw`; faulting thread `com.apple.root.utility-qos.cooperative`).
- CoreML MiniLM references: conversion recipe
  https://github.com/Abhishek6353/AllMiniLML6V2-coreml ; tokenizer
  https://github.com/huggingface/swift-transformers ; gotchas
  https://www.thunderkitty.app/learn/three-models-zero-api-calls .
- MiniLM outputs **token embeddings** → mean-pool + L2-normalize must be done in
  Swift (NOT baked into the CoreML model).
- Model size ≈ 90 MB unquantized (~25–30 MB after INT8 linear quantization);
  output dim = 384.
- The chunk index stores raw Float32 BLOBs and compares with
  `vec_distance_cosine` (dimension-agnostic as long as both operands match) — so a
  dim change is fine **iff** every chunk + the query vector use the same dim.

## Architecture

### `Embedder` abstraction
Introduce a single protocol so the store depends on an abstraction, not NLEmbedding:

```swift
public protocol Embedder {
    var identifier: String { get }      // e.g. "nlembedding-512", "minilm-384"
    var dimension: Int { get }          // 512 or 384
    func vector(for text: String) -> [Float]?   // one vector for a short string (query)
}
```

`EmbeddingService` holds the active `Embedder` (selected at launch):
- `MiniLMEmbedder` when the bundled `.mlpackage` + tokenizer are present;
- `NLEmbedder` (current behavior) as the fallback (e.g. dev builds without the model bundle).

`EmbeddingService.embeddingBlob(for:)` / `chunkedEmbeddings(for:)` / `chunks(for:)`
delegate to the active embedder and serialize its `[Float]` to a Float32 BLOB.

### `MiniLMEmbedder` pipeline (Swift)
1. **Tokenize** → `input_ids` + `attention_mask` (WordPiece; see Tokenizer below).
2. Run the CoreML model → token embeddings `[seq_len × 384]`.
3. **Mean-pool** over non-pad tokens using `attention_mask` as weights.
4. **L2-normalize** the pooled vector.
5. Return `[Float]` (384). `EmbeddingService` packs to `Data` (384 × 4 bytes).

### Dimension cutover (the critical correctness concern)
`vec_distance_cosine` between a 512-dim and a 384-dim vector is undefined garbage,
so a DB must contain **one** embedder's vectors only. Cutover design:

- New tiny table `embedding_meta(id INTEGER PRIMARY KEY CHECK(id=1), embedder TEXT NOT NULL)`,
  seeded with the active embedder's `identifier`.
- On open, if `activeEmbedder.identifier != stored.embedder`:
  `DELETE FROM page_chunks; DELETE FROM source_chunks; UPDATE embedding_meta SET embedder=?;`
  then the existing async backfill re-embeds everything in the new dim (it already
  embeds "documents missing chunks" — after the wipe, all are missing).
- This makes the switch self-healing and idempotent, mirroring the FTS self-heal.
- Add `embedding_meta` to **both** `createFreshSchemaV14()` and the `migrate(from:)`
  ladder — the repo's `freshFastPathMatchesStepwiseLadder` parity test enforces they
  stay identical; seed it with the active embedder identifier at creation.

### Tokenizer (pick one at implementation time)
- **Preferred:** `huggingface/swift-transformers` (`AutoTokenizer` from a bundled
  `tokenizer.json`/`vocab.txt`) — official, handles WordPiece + special tokens.
- **Zero-dependency fallback:** a ~100-line WordPiece tokenizer + bundled
  `vocab.txt` (reference: TensorFlow's BERT example). Use this only if
  `swift-transformers` proves heavy for the build.

### Chunking
Keep `TextChunker` (~4k-char chunks) — MiniLM's 512-token limit means a 4k-char
chunk still truncates internally, which is fine (truncation, not a crash). Optionally
tune chunk size down (~1–2k chars ≈ ≤ 512 tokens) once MiniLM is in, so chunks
aren't silently truncated — revisit after benchmarking recall.

## Phased implementation

### Phase 0 — Convert + validate the model (Python, offline)
- `uv` env (Python 3.12) with `coremltools`, `sentence-transformers`, `torch`,
  `numpy`.
- Convert `all-MiniLM-L6-v2` → `.mlpackage` via a traced wrapper (token-embedding
  output). **Validate** against `sentence-transformers` reference embeddings: cosine
  ≥ 0.999 on a probe set. Watch the known gotcha: `coremltools` can silently drop
  position embeddings → plausible garbage (cosine ~0.17). Validate before trusting.
- INT8-quantize to shrink the bundle.
- Deliverables: `Resources/MiniLM.mlpackage`, `Resources/minilm-vocab.txt`, a
  validation report (cosine numbers).

### Phase 1 — Swift inference, isolated (no app wiring)
- Add an isolated executable/test target: load the `.mlpackage`, tokenize, predict,
  mean-pool + L2-normalize → 384-dim.
- Assert cosine vs the Phase-0 reference vectors; benchmark latency on this hardware
  (target: ≤ ~20 ms / chunk on ANE).
- This de-risks inference + tokenization before touching the store.

### Phase 2 — Wire into `EmbeddingService`
- Add `Embedder` protocol + `NLEmbedder` (wrap current code) + `MiniLMEmbedder`.
- Select at launch (MiniLM if bundle present, else NLEmbedder).
- Add `embedding_meta` + the cutover wipe in `ensureSearchIndexesPopulated()`.
- `vec_distance_cosine` queries unchanged (same-dim operands guaranteed).

### Phase 3 — Off-main backfill (the payoff)
- MiniLM is safe off-main → move the per-chunk embedding work off the main actor
  (e.g. into a background `Task.detached`/queue), eliminating the current
  `@MainActor` + `Task.yield()` jank-mitigation that NLEmbedding/BNNS required.
- Re-measure full-corpus first-backfill wall time; expect minutes → seconds.

## Acceptance criteria
- AC.1 `MiniLMEmbedder.vector(for:)` cosine ≥ 0.999 vs the Python reference on a
  fixed probe set.
- AC.2 Per-chunk latency ≤ ~20 ms on the target machine (ANE).
- AC.3 A DB opened with MiniLM active has only 384-dim chunks; switching embedders
  wipes + re-embeds automatically (`embedding_meta` driven).
- AC.4 Hybrid search (FTS + vec + RRF) returns equivalent-or-better results to
  NLEmbedding on a hand-curated query set.
- AC.5 The app launches and the first backfill completes with **no UI jank**
  (off-main) and no crash.

## Test strategy
- **Phase 0:** Python validation script asserts cosine ≥ 0.999 (gate; not in CI).
- **Phase 1:** isolated target unit tests: tokenizer round-trip, output dim = 384,
  cosine-vs-reference, L2-norm (‖v‖₂ ≈ 1).
- **Phase 2:** store tests — `embedding_meta` cutover wipes chunks on embedder
  change; backfill re-embeds in the new dim; vec query returns results.
- **Phase 3:** a hosted/integration check that the off-main backfill populates
  chunks without blocking the main actor (latency probe), reusing the
  `reproducing-live-ui-bugs` os_log approach if live verification is needed.
- Python tests are NOT in CI (per repo convention) — run manually when changing the
  model/conversion.

## Review strategy
- Plan-mode: run `plan-reviewer` on this design before implementation begins.
- Implementation: after Phase 1 (inference validated) and Phase 2 (wired), dispatch
  a `general-purpose` review subagent; fix/rebut all critical findings, re-review
  until clean.

## Documentation strategy
- This `plans/coreml-minilm-design.md` is the design of record.
- Update `PROGRESS.md` per phase and `EmbeddingService` doc comments.
- Note the ~bundle-size impact and the embedder-selection/fallback behavior in
  `plans/architecture.md` if it documents the storage layer.

## Risks, blockers, decisions
- **Conversion correctness (top risk):** silent position-embedding loss → garbage
  vectors. Mitigation: mandatory cosine ≥ 0.999 gate in Phase 0; do not proceed
  until it passes.
- **Bundle size:** +~25–90 MB. Acceptable for this app; INT8 quantize to reduce.
- **Tokenizer dependency:** `swift-transformers` adds a package dep; the ~100-line
  custom WordPiece is the escape hatch. Decide after Phase 1.
- **Cutover data cost:** first MiniLM backfill re-embeds the whole corpus — but at
  MiniLM speed that's seconds-to-a-minute, not minutes. One-time.
- **Decision needed before Phase 2:** drop NLEmbedding entirely or keep it as the
  no-bundle fallback? Recommendation: keep as fallback (dev builds / fresh clones
  without the model still get working semantic search at 512-dim).
- **Embedder-agnostic index is the key enabler:** because chunks are opaque BLOBs
  compared by `vec_distance_cosine`, this whole effort is a behind-the-scenes swap
  with no query/schema-for-search change (only the `embedding_meta` cutover helper).
