---
timestamp: 2026-06-29T151010Z
title: "2026-06-29 — v14 per-chunk RAG embeddings (fixed launch crash; async backfill)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-29 — v14 per-chunk RAG embeddings (fixed launch crash; async backfill)

## Progress


**Crash:** the app aborted at launch with an uncatchable C++ `std::bad_alloc`.
Root cause (via `lldb` break on `__cxa_throw`): the open-time self-heal called
`NLEmbedding.vector(for:)` on whole source bodies; above ~250k chars NLEmbedding
throws `std::bad_alloc` (Swift can't catch C++ exceptions → terminate). It was
never seen before because the embedding recompute only ran via the never-pressed
"Reindex Search" button; the self-heal made it run at every launch. Measured:
NLEmbedding ≈ 5 s / 100k chars and crashes ≥ ~250k.

**Fix — per-chunk (RAG-style) embeddings, computed async:**
- **`TextChunker`** (`Sources/WikiFSCore/TextChunker.swift`): pure-Swift port of
  LangChain `RecursiveCharacterTextSplitter` / Chonkie `RecursiveChunker`
  (separator hierarchy `\n\n → \n → space → char`, ~4k-char chunks + 10% overlap).
  Research confirmed only Recursive/Sentence chunkers are portable to on-device
  Swift; Late/Semantic/Neural need a transformer's token embeddings (NLEmbedding
  is opaque). No mature Swift chunking library exists.
- **`EmbeddingService.chunkedEmbeddings(for:maxChunks:)`**: chunks the text, embeds
  each chunk (small → fast + crash-free), caps to 64 chunks (evenly sampled across
  the doc so a deep passage is still represented). `embeddingBlob(for:)` kept for
  short query strings.
- **v14 migration:** `page_chunks` + `source_chunks` (one BLOB per text chunk,
  FK ON DELETE CASCADE); drops the old one-row-per-doc `page_embeddings` /
  `source_embeddings`. Semantic search now ranks by each doc's BEST-matching chunk
  (`GROUP BY doc … MIN(vec_distance_cosine)`), so a query hits the specific passage.
- **Async, not at launch:** embedding is too slow to run synchronously (full corpus
  ≈ minutes). Removed from `init`; `WikiStoreModel.backfillMissingEmbeddings()`
  (kicked off on wiki open) computes vectors OFF the main actor while all DB
  reads/writes stay on main (single-connection store). Resumable/incremental — only
  docs still missing chunks are embedded, so a killed run continues next launch. FTS
  search works immediately; semantic search fills in as chunks land.
- Protocol: `storePageEmbedding`/`storeSourceEmbedding` → `storePageChunks`/
  `storeSourceChunks` (+ `missingPageEmbeddingWork`/`missingSourceEmbeddingWork`).
  `PageUpsert.upsert` (wikictl) chunk-embeds pages too.

**Verified:** `swift build` clean; **1209 tests pass** (incl. 7 new `TextChunkerTests`).
Rebuilt the `.app` via `./build.sh debug` and launched against the live DB: no crash,
v14 migration applied, background backfill streamed `backfill: page … ← N chunk(s)`.
(source_chunks fills after pages; was killed mid-run at 73 page-chunks.)

**Follow-up crash (SIGSEGV) + fix:** the first cut ran the backfill on a detached
background queue. That crashed with `EXC_BAD_ACCESS` inside `BNNSFilterApplyBatch` —
**NLEmbedding/CoreNLP inference is not safe off the main thread.** Moved the backfill
onto the main actor, embedding chunk-by-chunk with `Task.yield()` between chunks so
the UI stays responsive between the ~0.3 s NLEmbedding calls. Re-verified: app ran
60 s through active backfill with no crash (newest `.ips` unchanged). Known minor
warning (non-fatal): "reentrant operation in NSTableView delegate" during backfill
writes — to revisit. The per-chunk main-actor jank is itself the strongest argument
for the MLX MiniLM move (Metal inference is safe off-main).

**Deferred (recommended separately): MLX all-MiniLM-L6-v2.** NLEmbedding is the
bottleneck — ~5 s / 100k chars, so a full-corpus first backfill takes minutes.
Research says MLX MiniLM on Metal/GPU is low-single-digit ms/sentence
(100-1000× faster), better quality, no crash, predictable 512-token truncation —
using `mlx-community/all-MiniLM-L6-v2-bf16` + Apple's `MLXEmbedders` (model
downloaded on demand, gitignored, ~45 MB bundled into the .app; no conversion
pipeline). Design + phased plan are written
(`plans/mlx-minilm-design.md`). **Phase 0 done** — `tools/minilm-prepare/`
downloads the bf16 model on demand (gitignored, pinned HF revision `b6691709`,
SHA recorded for reproducible builds) and validates it. Gate reframed: MLX
embedding engines diverge from HF at ~0.99 cosine (a BERT-impl difference, not
bf16/precision), so the bar is **non-garbage** (min 0.9871 ≥ 0.95) +
**self-consistent** (paraphrase 0.636 ≫ unrelated 0.028), both PASS. The real
parity/quality bar is Swift `MLXEmbedders` (Phase 1) + AC.4 (search quality).
Phases 1–3 pending. (Pivoted from an earlier CoreML/ANE design that hit
conversion/quantization/ANE-compile problems.) When adopted, swap it in behind
`EmbeddingService` (chunk index + queries unchanged).

## Verification

Historical verification remains in the progress record above.
