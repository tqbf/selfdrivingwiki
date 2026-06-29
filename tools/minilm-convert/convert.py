#!/usr/bin/env python3
"""
Convert sentence-transformers/all-MiniLM-L6-v2 to CoreML .mlpackage.

Exports token embeddings (last_hidden_state) only — mean-pool + L2-norm
are intentionally left to the Swift caller. INT8-quantizes the result.

Deliverables:
  ../../Resources/MiniLM.mlpackage          (quantized CoreML model)
  ../../Resources/minilm-vocab.txt          (BERT WordPiece vocab, 30522 lines)
"""
import pathlib
import os

# Disable hf_transfer unless it's actually installed: the user's shell may export
# HF_HUB_ENABLE_HF_TRANSFER=1, which makes huggingface_hub raise at download time
# if the hf_transfer package isn't present. Must run before transformers import.
try:
    import hf_transfer  # noqa: F401
except ImportError:
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

import numpy as np
import torch
import coremltools as ct
import coremltools.optimize as cto
from transformers import AutoModel, AutoTokenizer

MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
SEQ_LEN = 512  # MiniLM max; chunks that exceed this are silently truncated
RESOURCES = pathlib.Path(__file__).parent.parent.parent / "Resources"


class MiniLMTokenEmbedder(torch.nn.Module):
    """Wraps AutoModel to return last_hidden_state only.

    Explicit two-argument signature ensures torch.jit.trace captures
    both input_ids and attention_mask in the traced graph, preventing
    the coremltools position-embedding-drop bug (cosine ~0.17 symptom).
    """

    def __init__(self, model_id: str) -> None:
        super().__init__()
        self.encoder = AutoModel.from_pretrained(model_id)

    def forward(
        self,
        input_ids: torch.Tensor,       # [1, SEQ_LEN] int32
        attention_mask: torch.Tensor,  # [1, SEQ_LEN] int32
    ) -> torch.Tensor:
        # Provide position_ids + token_type_ids explicitly. BERT otherwise derives
        # position_ids dynamically (cumsum/arange over input_ids.size()), which
        # traces to an aten::Int (tensor→scalar) op that coremltools cannot fold
        # (TypeError: only 0-dimensional arrays can be converted to Python scalars).
        # We always pad/truncate to SEQ_LEN, so positions are a fixed [0..SEQ_LEN-1].
        # arange() from a Python int becomes a graph constant at trace time — it is
        # NOT a model input; the CoreML model keeps exactly two inputs.
        position_ids = torch.arange(SEQ_LEN, dtype=torch.long).unsqueeze(0)  # [1, SEQ_LEN]
        token_type_ids = torch.zeros((1, SEQ_LEN), dtype=torch.long)
        out = self.encoder(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
            position_ids=position_ids,
        )
        return out.last_hidden_state   # [1, SEQ_LEN, 384]


def convert() -> None:
    print("Loading model...")
    wrapper = MiniLMTokenEmbedder(MODEL_ID)
    wrapper.eval()

    print(f"Tracing with seq_len={SEQ_LEN}...")
    dummy_ids = torch.ones(1, SEQ_LEN, dtype=torch.int32)
    dummy_mask = torch.ones(1, SEQ_LEN, dtype=torch.int32)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (dummy_ids, dummy_mask))

    print("Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="token_embeddings"),  # [1, SEQ_LEN, 384]
        ],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS15,
    )

    print("Quantizing INT8 (linear_symmetric)...")
    op_config = cto.coreml.OpLinearQuantizerConfig(
        mode="linear_symmetric",
        weight_threshold=512,
    )
    config = cto.coreml.OptimizationConfig(global_config=op_config)
    quantized = cto.coreml.linear_quantize_weights(mlmodel, config=config)

    out_path = RESOURCES / "MiniLM.mlpackage"
    print(f"Saving to {out_path} ...")
    RESOURCES.mkdir(exist_ok=True)
    quantized.save(str(out_path))
    print(f"  Saved ({_mb(out_path):.1f} MB)")

    print("Extracting vocab.txt...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    tokenizer.save_vocabulary(str(RESOURCES))
    # save_vocabulary writes Resources/vocab.txt; rename to the design's named deliverable.
    raw_vocab = RESOURCES / "vocab.txt"
    vocab_path = RESOURCES / "minilm-vocab.txt"
    assert raw_vocab.exists(), f"vocab.txt not found at {raw_vocab}"
    raw_vocab.rename(vocab_path)
    print(f"  Vocab saved ({vocab_path.stat().st_size // 1024} KB, "
          f"{sum(1 for _ in vocab_path.open())} tokens)")

    print("\nConversion complete.")
    print(f"  Model: {out_path}")
    print(f"  Vocab: {vocab_path}")
    print("\nNext: run validate.py to confirm cosine >= 0.999.")


def _mb(path: pathlib.Path) -> float:
    total = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    return total / 1_048_576


if __name__ == "__main__":
    convert()
