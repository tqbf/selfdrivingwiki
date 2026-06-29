# MLX MiniLM Implementation Plan — Phase 0: Prepare + validate the MLX model

**Goal:** Download `mlx-community/all-MiniLM-L6-v2-bf16` and validate that its
mean-pooled + L2-normalized embeddings match `sentence-transformers` reference
at cosine ≥ 0.999 on a probe set. This is the **gate** for all Swift phases —
MLX loads weights with no conversion, so parity should be near-exact; confirm it
before building inference on top.

**Architecture:** Python-only offline phase. MLX loads the HF weights directly
(no conversion/quantization, unlike the abandoned CoreML path). Pooling +
L2-norm are applied in Python here to replicate what Swift will do via
`MLXEmbedders`' pooler. Deliverable model dir lands in `Resources/` for the
Swift phases.

**Tech Stack:** Python 3.12, uv, `mlx`, `mlx-embeddings` (or `mlx-transformers`),
`sentence-transformers`, `numpy`, `scipy`, `huggingface_hub`

**Scope:** Phase 0 of 4. This is an offline tooling/validation phase; artifacts
feed Phases 1–3.

**Codebase verified:** 2026-06-29

---

## Acceptance Criteria Coverage

### coreml→mlx.AC1: MiniLMEmbedder cosine accuracy
- **AC1-python-gate:** The bf16 MLX model, mean-pooled + L2-normalized in Python,
  produces embeddings with cosine ≥ 0.999 vs `sentence-transformers` reference on
  a 20-sentence probe set. Establishes the model is correct before Swift phases.

---

## Task 1: Create tools/minilm-prepare/ project

**Files:**
- Create: `tools/minilm-prepare/pyproject.toml`
- Create: `tools/minilm-prepare/download.py`
- Create: `tools/minilm-prepare/validate.py`

**Step 1: Initialize uv project**

```bash
cd /Users/wsargent/work/selfdrivingwiki/tools
uv init minilm-prepare --no-workspace
cd minilm-prepare
uv python pin 3.12
```

If `uv python pin 3.12` fails with an `requires-python` conflict (uv init picks
the system default), edit `pyproject.toml` to `requires-python = ">=3.12"` first,
then re-pin.

**Step 2: Add dependencies**

```bash
uv add mlx mlx-embeddings sentence-transformers numpy "scipy>=1.10" huggingface_hub
```

If `mlx-embeddings` fails to resolve, fall back to `mlx-transformers` (same role).

> Note: `mlx` is Apple Silicon only (arm64 macOS). This tool runs on the dev
> machine, not CI.

**Step 3: Verify install**

```bash
uv run python -c "import mlx; import mlx_embeddings; import sentence_transformers; print('OK')"
```

Expected: `OK` with no errors.

**Step 4: Remove the boilerplate `main.py` uv init creates, then commit skeleton**

```bash
rm -f main.py
git add tools/minilm-prepare/pyproject.toml tools/minilm-prepare/uv.lock tools/minilm-prepare/.python-version
git commit -m "chore: add minilm-prepare Python project skeleton"
```

---

## Task 2: Write download.py — fetch the bf16 model dir

**Files:**
- Create: `tools/minilm-prepare/download.py`

```python
#!/usr/bin/env python3
"""
Download mlx-community/all-MiniLM-L6-v2-bf16 into Resources/all-MiniLM-L6-v2/.

MLX loads these weights directly in Swift (Phase 1) — no conversion step. The
non-quantized mlx-community/all-MiniLM-L6-v2 does NOT exist; bf16 is the best-
parity variant (no quantization loss, ~45 MB).
"""
import os

# Disable hf_transfer unless it's actually installed (the user's shell may export
# HF_HUB_ENABLE_HF_TRANSFER=1, which raises at download time otherwise).
try:
    import hf_transfer  # noqa: F401
except ImportError:
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

import pathlib
from huggingface_hub import snapshot_download

MODEL_ID = "mlx-community/all-MiniLM-L6-v2-bf16"
DEST = pathlib.Path(__file__).parent.parent.parent / "Resources" / "all-MiniLM-L6-v2"


def download() -> None:
    DEST.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {MODEL_ID} -> {DEST} ...")
    snapshot_download(
        MODEL_ID,
        local_dir=str(DEST),
        # all model + tokenizer files (safetensors, config.json, tokenizer.json, ...)
    )
    files = sorted(p.name for p in DEST.iterdir() if p.is_file())
    total_mb = sum(p.stat().st_size for p in DEST.rglob("*") if p.is_file()) / 1_048_576
    print(f"  {len(files)} files, {total_mb:.1f} MB total")
    for f in files:
        print(f"    {f}")
    print("\nNext: run validate.py to confirm cosine >= 0.999.")


if __name__ == "__main__":
    download()
```

**Step 1: Run download (~45 MB on first run)**

```bash
cd tools/minilm-prepare
uv run python download.py
```

Expected: `Resources/all-MiniLM-L6-v2/` populated with `config.json`,
`model.safetensors`, `tokenizer.json`, `tokenizer_config.json`, `vocab.txt`,
`special_tokens_map.json` (file set may vary slightly).

**Step 2: Commit script**

```bash
git add tools/minilm-prepare/download.py
git commit -m "feat: add MLX MiniLM download script"
```

---

## Task 3: Write validate.py — cosine gate

**Files:**
- Create: `tools/minilm-prepare/validate.py`

```python
#!/usr/bin/env python3
"""
Validate mlx-community/all-MiniLM-L6-v2-bf16 against sentence-transformers.

Gate: cosine similarity >= 0.999 on all 20 probe sentences (mean-pool + L2).
MLX loads the exact HF weights, so parity should be near-exact. Do NOT proceed
to Phase 1 until this passes.
"""
import os
try:
    import hf_transfer  # noqa: F401
except ImportError:
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

import pathlib
import sys
import numpy as np
from scipy.spatial.distance import cosine

MODEL_DIR = pathlib.Path(__file__).parent.parent.parent / "Resources" / "all-MiniLM-L6-v2"
THRESHOLD = 0.999

PROBE = [
    "The quick brown fox jumps over the lazy dog.",
    "Natural language processing with transformer models.",
    "Apple Neural Engine accelerates machine learning inference.",
    "The mitochondria is the powerhouse of the cell.",
    "MLX enables on-device inference on Apple Silicon.",
    "Semantic search retrieves documents by meaning, not keywords.",
    "SQLite vec0 extension stores float32 embeddings as BLOBs.",
    "Swift concurrency uses structured tasks and actors.",
    "Mean pooling aggregates token embeddings into a sentence vector.",
    "L2 normalization scales a vector to unit length.",
    "WordPiece tokenization splits rare words into subwords.",
    "The attention mechanism weighs token relevance dynamically.",
    "Cosine similarity measures angle between two vectors.",
    "A self-driving wiki automatically organizes its own content.",
    "Bfloat16 keeps near-exact parity with float32 for embeddings.",
    "Background tasks should not block the main thread.",
    "Metal GPU work must pause when a macOS app is backgrounded.",
    "The embedding dimension determines the vector space size.",
    "Retrieval-augmented generation combines search and generation.",
    "On-device models protect user privacy by avoiding cloud calls.",
]


def _normalize(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def mlx_embed(text: str):
    """Load once (module-level), return mean-pooled + L2-normalized [384] vector."""
    from mlx_embeddings import load
    import mlx.core as mx

    model, tokenizer = load(str(MODEL_DIR))
    enc = tokenizer.encode(text)
    input_ids = mx.array(enc["input_ids"] if isinstance(enc, dict) else enc)[None]
    attn = mx.array(enc.get("attention_mask", [1] * input_ids.size))[None] \
        if isinstance(enc, dict) else mx.ones_like(input_ids)
    out = model(input_ids, attn)  # last_hidden_state [1, seq, 384]
    token_embs = np.array(out[0]) if hasattr(out, "__getitem__") else np.array(out)
    mask = np.array(attn[0])[:, None].astype(np.float32)
    pooled = (token_embs * mask).sum(axis=0) / mask.sum()
    return _normalize(pooled.astype(np.float32))


def validate() -> None:
    if not MODEL_DIR.exists():
        print(f"ERROR: {MODEL_DIR} not found. Run download.py first.", file=sys.stderr)
        sys.exit(1)

    from sentence_transformers import SentenceTransformer
    print("Loading sentence-transformers reference model...")
    ref = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2").encode(
        PROBE, normalize_embeddings=True
    )

    print(f"\nValidating {len(PROBE)} probes (threshold: cosine >= {THRESHOLD}):")
    failures = []
    for i, sentence in enumerate(PROBE):
        try:
            vec = mlx_embed(sentence)
        except Exception as e:
            # mlx-embeddings API surface may differ — adjust the loader to the
            # installed package's actual signatures (see notes below).
            print(f"  [{i:02d}] ERROR loading MLX embedding: {e}")
            print("  Adjust mlx_embed() to match the installed mlx-embeddings API.")
            sys.exit(2)
        sim = 1.0 - cosine(ref[i], vec)
        status = "\u2713" if sim >= THRESHOLD else "\u2717 FAIL"
        print(f"  [{i:02d}] cosine={sim:.4f} {status}  {sentence[:50]}")
        if sim < THRESHOLD:
            failures.append((i, sim, sentence))

    print()
    if failures:
        print(f"VALIDATION FAILED: {len(failures)} probe(s) below {THRESHOLD}")
        for idx, sim, s in failures:
            print(f"  [{idx:02d}] cosine={sim:.4f}: {s}")
        sys.exit(1)
    print(f"VALIDATION PASSED: all {len(PROBE)} probes >= {THRESHOLD}")
    print("Model is ready for Phase 1 (Swift inference).")


if __name__ == "__main__":
    validate()
```

> **API hedge:** `mlx-embeddings`'s exact `load()` / forward / output-shape API
> may differ from the snippet. The intent is: tokenize → forward → take
> `last_hidden_state` → mean-pool + L2. If the loader or output differs, adjust
> `mlx_embed()` to match the installed package — the gate is the cosine number,
> not the exact call shape.

**Step 1: Run the gate**

```bash
cd tools/minilm-prepare
uv run python validate.py
```

Expected: all 20 probes `cosine >= 0.999`, then `VALIDATION PASSED`.

**Step 2: Commit**

```bash
git add tools/minilm-prepare/validate.py
git commit -m "feat: add MLX MiniLM validation script (cosine gate)"
```

---

## Task 4: Decide on model-dir git storage

```bash
du -sh ../../Resources/all-MiniLM-L6-v2
```

- If **< 50 MB** (bf16 ≈ 45 MB — expected): commit it for offline determinism.
- If **≥ 50 MB**: gitignore it and document `download.py` as the regen step.

```bash
# < 50 MB path:
git add ../../Resources/all-MiniLM-L6-v2
git commit -m "feat: bundle all-MiniLM-L6-v2-bf16 MLX weights (Phase 0 gate passed)"
```
