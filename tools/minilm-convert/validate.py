#!/usr/bin/env python3
"""
Validate MiniLM.mlpackage against sentence-transformers reference embeddings.

Gate: cosine similarity >= 0.999 on all 20 probe sentences.
If any probe fails, the conversion is broken (likely position-embedding drop).
Do NOT proceed to Phase 2 until this passes.
"""
import os

# Disable hf_transfer unless it's actually installed (see convert.py for rationale).
try:
    import hf_transfer  # noqa: F401
except ImportError:
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

import pathlib
import sys

import coremltools
import numpy as np
from scipy.spatial.distance import cosine
from sentence_transformers import SentenceTransformer
from transformers import AutoTokenizer

MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
RESOURCES = pathlib.Path(__file__).parent.parent.parent / "Resources"
THRESHOLD = 0.999

PROBE = [
    "The quick brown fox jumps over the lazy dog.",
    "Natural language processing with transformer models.",
    "Apple Neural Engine accelerates machine learning inference.",
    "The mitochondria is the powerhouse of the cell.",
    "CoreML enables on-device inference without network calls.",
    "Semantic search retrieves documents by meaning, not keywords.",
    "SQLite vec0 extension stores float32 embeddings as BLOBs.",
    "Swift concurrency uses structured tasks and actors.",
    "Mean pooling aggregates token embeddings into a sentence vector.",
    "L2 normalization scales a vector to unit length.",
    "WordPiece tokenization splits rare words into subwords.",
    "The attention mechanism weighs token relevance dynamically.",
    "Cosine similarity measures angle between two vectors.",
    "A self-driving wiki automatically organizes its own content.",
    "Quantization reduces model size by lowering weight precision.",
    "Background tasks should not block the main thread.",
    "INT8 weights use 8-bit integers instead of 32-bit floats.",
    "The embedding dimension determines the vector space size.",
    "Retrieval-augmented generation combines search and generation.",
    "On-device models protect user privacy by avoiding cloud calls.",
]


def mean_pool_and_normalize(
    token_embeddings: np.ndarray,  # [1, seq_len, 384]
    attention_mask: np.ndarray,    # [1, seq_len]
) -> np.ndarray:
    """Replicate what Swift MiniLMEmbedder will do."""
    mask = attention_mask[0, :, np.newaxis].astype(np.float32)  # [seq_len, 1]
    pooled = (token_embeddings[0] * mask).sum(axis=0) / mask.sum()  # [384]
    norm = np.linalg.norm(pooled)
    return pooled / norm if norm > 0 else pooled


def validate() -> None:
    mlpackage = RESOURCES / "MiniLM.mlpackage"
    if not mlpackage.exists():
        print(f"ERROR: {mlpackage} not found. Run convert.py first.", file=sys.stderr)
        sys.exit(1)

    print("Loading sentence-transformers reference model...")
    st_model = SentenceTransformer(MODEL_ID)
    ref_embeddings = st_model.encode(PROBE, normalize_embeddings=True)  # [20, 384]

    print("Loading CoreML model...")
    ml = coremltools.models.MLModel(str(mlpackage))
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)

    print(f"\nValidating {len(PROBE)} probe sentences (threshold: cosine >= {THRESHOLD}):")
    failures = []

    for i, sentence in enumerate(PROBE):
        enc = tokenizer(
            sentence,
            max_length=512,
            truncation=True,
            padding="max_length",
            return_tensors="np",
        )
        input_ids = enc["input_ids"].astype(np.int32)
        attention_mask = enc["attention_mask"].astype(np.int32)

        out = ml.predict({"input_ids": input_ids, "attention_mask": attention_mask})
        token_embs = out["token_embeddings"]  # [1, 512, 384]

        coreml_vec = mean_pool_and_normalize(token_embs, attention_mask)
        sim = 1.0 - cosine(ref_embeddings[i], coreml_vec)

        status = "\u2713" if sim >= THRESHOLD else "\u2717 FAIL"
        print(f"  [{i:02d}] cosine={sim:.4f} {status}  {sentence[:50]}")

        if sim < THRESHOLD:
            failures.append((i, sim, sentence))

    print()
    if failures:
        print(f"VALIDATION FAILED: {len(failures)} probe(s) below {THRESHOLD}:")
        for idx, sim, sentence in failures:
            print(f"  [{idx:02d}] cosine={sim:.4f}: {sentence}")
        print()
        print("Likely cause: position embeddings dropped during tracing (cosine ~0.17).")
        print("Fix: ensure convert.py wrapper passes attention_mask explicitly.")
        sys.exit(1)
    else:
        print(f"VALIDATION PASSED: all {len(PROBE)} probes >= {THRESHOLD}")
        print("Model is ready for Phase 2 (Swift inference).")


if __name__ == "__main__":
    validate()
