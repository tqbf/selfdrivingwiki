# MLX MiniLM — Test Requirements

**Feature:** Replace NLEmbedding (512-dim) with MLX `all-MiniLM-L6-v2` (384-dim) on Metal/GPU

**Plan:** `docs/implementation-plans/2026-06-29-mlx-minilm/`

**Design:** `plans/mlx-minilm-design.md`

---

## Acceptance Criteria

| ID | Criterion | Type | Phase |
|----|-----------|------|-------|
| AC.1 | `MiniLMEmbedder` is non-garbage (min cosine ≥ 0.95 vs HF reference) + self-consistent (paraphrase ≫ unrelated). Strict ≥0.999-vs-HF not achievable with MLX engines (see design parity caveat) | Automated | Phase 1 |
| AC.2 | Per-chunk latency ≤ ~20 ms on the target machine (Metal/GPU) | Automated (benchmark) | Phase 1 |
| AC.3 | A DB opened with MiniLM active has only 384-dim chunks; switching embedders wipes + re-embeds automatically (`embedding_meta` driven) | Automated | Phase 2 |
| AC.4 | Hybrid search (FTS + vec + RRF) returns equivalent-or-better results to NLEmbedding on a hand-curated query set | Manual | Phase 3 |
| AC.5 | The app launches and the first backfill completes with no UI jank (off-main) and no crash — including surviving a background/foreground cycle (Metal backgrounding handled) | Manual | Phase 3 |

---

## Automated Tests

### Phase 0 — Python validation (the gate)

**File:** `tools/minilm-prepare/validate.py`

**Not in CI** (per repo convention for Python scripts). Run manually when changing the model.

| Test | AC | Pass criteria |
|------|----|---------------|
| MLX bf16 gate (G1 non-garbage + G2 self-consistent) | AC.1 | min cosine ≥ 0.95 vs HF ref; every paraphrase pair > every unrelated pair |

**How to run:**
```bash
cd tools/minilm-prepare
uv run python download.py   # once, to populate Resources/all-MiniLM-L6-v2/
uv run python validate.py
```

---

### Phase 1 — Swift inference unit tests

**File:** `Tests/WikiFSTests/MiniLMEmbedderTests.swift`

**Framework:** Swift Testing (`@Test`, `#expect`, `#require`)

**Resource path:** `#filePath`-relative discovery (no `Bundle.module`)

| Test | AC | Pass criteria |
|------|----|---------------|
| Output dimension | AC.1 | `vector.count == 384` |
| L2 normalization | AC.1 | `‖v‖₂` within 0.001 of 1.0 (vDSP magnitude check) |
| Non-garbage vs HF reference | AC.1 | `cosine(swift_vec, hf_ref) ≥ 0.95` for all probes (not a parity bar — Swift MLXEmbedders ≠ Python proxy) |
| Self-consistent | AC.1 | min cosine(paraphrase pairs) > max cosine(unrelated pairs) |
| Latency benchmark | AC.2 | Average `vector(for:)` call time ≤ 20 ms over 10 runs (warm) |
| Nil return for empty string | — | `vector(for: "") == nil` or a zero-norm vector (implementation-defined; must not crash) |

**How to run:**
```bash
swift test --filter MiniLMEmbedderTests
```

---

### Phase 2 — EmbeddingService wiring and schema v15

**Files:**
- `Tests/WikiFSTests/EmbeddingMetaCutoverTests.swift`
- `Tests/WikiFSTests/FreshSchemaParityTests.swift` (modified)

| Test | AC | Pass criteria |
|------|----|---------------|
| Fresh DB schema version | — | `pragmaValue("user_version") == "15"` |
| Cutover wipes source chunks on embedder mismatch | AC.3 | After `ensureEmbedderConsistency(activeIdentifierOverride: "minilm-384")` on a DB seeded with `"nlembedding-512"`, a source that had chunks appears in `missingSourceEmbeddingWork()` |
| No-op when identifier matches | AC.3 | `ensureEmbedderConsistency(activeIdentifierOverride: NLEmbedder.identifier)` on a fresh DB leaves chunks intact |
| `freshFastPathMatchesStepwiseLadder` | — | Both `user_version == "15"`; `embedding_meta` in expected-objects list |

**How to run:**
```bash
swift test --filter EmbeddingMetaCutoverTests
swift test --filter FreshSchemaParityTests
```

---

### Full test suite gate

After each phase, the full test suite must pass:

```bash
swift test
```

No test may be skipped or marked `.disabled` as a result of this implementation.

---

## Manual Verification

### AC.4 — Search quality parity

**When:** After Phase 3, after full-corpus backfill completes.

**Setup:**
1. Confirm `all-MiniLM-L6-v2/` is bundled in the app.
2. Delete/move the existing `wiki.db` (force full re-embed).
3. Launch and wait for backfill to complete (`backfill[page]: embedded N of M docs` in Console.app).

**Query set (5–10, varied):** factual lookup, conceptual/comparative, troubleshooting, cross-document, keyword-heavy (FTS-dominant), semantic-only.

**Pass:** every query returns ≥ 2 relevant results in the top 3; no empty result set; no off-topic top result.

**Record:** query + top-5 results in `tmp/minilm-quality-eval.md` (not committed).

---

### AC.5 — No UI jank during backfill + backgrounding survival

**When:** Immediately after launching with a fresh database (full re-embed required).

**Checklist during backfill:**

| Check | Expected |
|-------|----------|
| Console thread check | `backfill[page] starting on thread: background` (NOT MAIN) |
| App launch time | < 2 seconds to first page render |
| Page navigation during backfill | Immediate (no visible delay) |
| Scroll / search responsiveness during backfill | Instant, no stutter |
| **Background/foreground cycle** | cmd-Tab away ~10s mid-backfill, then return — **no crash**; Console shows `AppStateObserver: app backgrounded` then `active`; backfill resumes and completes |
| Crash check | No crash during or after backfill |

**Failure triage:**
- If `MAIN` in thread check: `isMiniLM` branch selecting the wrong path — check `selectedEmbedderIdentifier()` and bundle presence.
- If crash on background: Metal work submitted while inactive — check `AppStateObserver.shared.isActive` is checked before each inference in `backfillBackground`.
- If `BNNSFilterApplyBatch` in crash log: NLEmbedder running off-main → branch condition wrong.
- If empty search results after backfill: verify backfill completion log + `vec_distance_cosine` path active (not LIKE fallback).

---

## Test Execution Order

```
Phase 0 complete → run: cd tools/minilm-prepare && uv run python validate.py
Phase 1 complete → run: swift test --filter MiniLMEmbedderTests
Phase 2 complete → run: swift test --filter EmbeddingMetaCutoverTests
                 → run: swift test --filter FreshSchemaParityTests
                 → run: swift test   ← full suite gate
Phase 3 complete → manual: AC.5 jank + backgrounding check
                 → manual: AC.4 search quality eval
                 → run: swift test   ← full suite gate
```

---

## Not in CI

| Test | Reason |
|------|--------|
| `tools/minilm-prepare/validate.py` | Python / requires model download + Apple Silicon; per repo convention |
| AC.4 search quality evaluation | Manual; requires live app + curated query set |
| AC.5 UI jank + backgrounding check | Manual; requires live app observation |
| MiniLMEmbedder latency benchmark | Requires Metal/GPU hardware; results vary by machine |
