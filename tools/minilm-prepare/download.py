#!/usr/bin/env python3
"""
Ensure mlx-community/all-MiniLM-L6-v2-bf16 is present in Resources/.

Idempotent prepare step (run before tests/build). The model dir is gitignored —
it is NOT committed. Pinning REVISION makes the build reproducible; the resolved
commit SHA is recorded in DEST/.source-sha for verification. The non-quantized
mlx-community/all-MiniLM-L6-v2 does NOT exist; bf16 is the best-parity variant.
"""
import os

# Disable hf_transfer unless it's actually installed.
try:
    import hf_transfer  # noqa: F401
except ImportError:
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

import pathlib
from huggingface_hub import HfApi, snapshot_download

MODEL_ID = "mlx-community/all-MiniLM-L6-v2-bf16"
# Pin a revision (tag or commit SHA) for reproducibility. When updating, bump this
# and re-run validate.py to re-confirm the non-garbage + self-consistent gate.
REVISION = "b6691709eacd8f0afcc3faace288cf50e611f3aa"  # pinned after first run
DEST = pathlib.Path(__file__).parent.parent.parent / "Resources" / "all-MiniLM-L6-v2"
SHA_FILE = DEST / ".source-sha"


def _recorded_sha() -> str | None:
    return SHA_FILE.read_text().strip() if SHA_FILE.exists() else None


def ensure_present() -> None:
    api = HfApi()
    resolved = api.model_info(MODEL_ID, revision=REVISION).sha  # the pinned revision's SHA

    if _recorded_sha() == resolved and DEST.exists():
        print(f"Already present at {resolved[:12]} — nothing to do.")
        return

    DEST.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {MODEL_ID}@{REVISION} ({resolved[:12]}) -> {DEST} ...")
    snapshot_download(MODEL_ID, revision=REVISION, local_dir=str(DEST))
    SHA_FILE.write_text(resolved + "\n")

    files = sorted(p.name for p in DEST.iterdir() if p.is_file())
    total_mb = sum(p.stat().st_size for p in DEST.rglob("*") if p.is_file()) / 1_048_576
    print(f"  {len(files)} files, {total_mb:.1f} MB, sha={resolved[:12]}")
    print("Recorded SHA in .source-sha (for reproducible-build verification).")
    print("\nNext: run validate.py to confirm the non-garbage + self-consistent gate.")


if __name__ == "__main__":
    ensure_present()
