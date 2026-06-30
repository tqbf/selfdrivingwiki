#!/usr/bin/env python3
"""
Ensure the MLX MiniLM runtime is present locally: the model weights AND the
version-matched MLX metallib (Metal shaders).

Idempotent prepare step (run before tests/build). Nothing here is committed —
both the model dir and the metallib are gitignored.

Two artifacts:
  1. Model: mlx-community/all-MiniLM-L6-v2-bf16 -> Resources/all-MiniLM-L6-v2/
     (pinned HF revision; SHA recorded in .source-sha). The non-quantized
     all-MiniLM-L6-v2 does not exist; bf16 is the best-parity variant.
  2. Metallib: mlx==MLX_WHEEL_VERSION's mlx.metallib (extracted from the PyPI
     wheel) -> Resources/mlx.metallib (build.sh bundles into the app) + a
     repo-root default.metallib link for `swift test`'s CWD fallback.

     WHY: `swift build` CANNOT build MLX's Metal shaders (only xcodebuild can —
     mlx-swift README/issue #36). This repo is SwiftPM-only, so we ship a
     prebuilt metallib matched to mlx-swift's vendored C++ version. The version
     MUST match exactly: mlx-swift 0.31.4 vendors MLX C++ 0.31.1, hence
     MLX_WHEEL_VERSION=0.31.1. Bumping mlx-swift requires re-matching this (a
     mismatched metallib silently corrupts GPU output).
"""
import os

# Disable hf_transfer unless it's actually installed.
try:
    import hf_transfer  # noqa: F401
except ImportError:
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "0"

import io
import json
import pathlib
import urllib.request
import zipfile
from huggingface_hub import HfApi, snapshot_download

REPO_ROOT = pathlib.Path(__file__).parent.parent.parent
RESOURCES = REPO_ROOT / "Resources"

# --- Model ---
MODEL_ID = "mlx-community/all-MiniLM-L6-v2-bf16"
REVISION = "b6691709eacd8f0afcc3faace288cf50e611f3aa"  # pinned; re-run validate.py if bumped
MODEL_DEST = RESOURCES / "all-MiniLM-L6-v2"
SHA_FILE = MODEL_DEST / ".source-sha"

# --- Metallib ---
# MUST match mlx-swift's vendored MLX C++ version (Source/Cmlx/mlx/mlx/version.h).
# mlx-swift 0.31.4 -> MLX C++ 0.31.1. Bump together; a mismatch corrupts the GPU.
# The metallib ships in the `mlx-metal` PyPI package (the thin `mlx` wheel depends
# on it); extract mlx/lib/mlx.metallib from the version-matched wheel.
METAL_PACKAGE = "mlx-metal"
METAL_VERSION = "0.31.1"
METALLIB_DEST = RESOURCES / "mlx.metallib"        # build.sh bundles this into the .app
CWD_METALLIB = REPO_ROOT / "default.metallib"     # swift test finds it via the CWD fallback


def _recorded_sha() -> str | None:
    return SHA_FILE.read_text().strip() if SHA_FILE.exists() else None


def ensure_model() -> None:
    api = HfApi()
    resolved = api.model_info(MODEL_ID, revision=REVISION).sha
    if _recorded_sha() == resolved and MODEL_DEST.exists():
        print(f"Model already present at {resolved[:12]} — nothing to do.")
        return
    MODEL_DEST.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {MODEL_ID}@{REVISION} ({resolved[:12]}) -> {MODEL_DEST} ...")
    snapshot_download(MODEL_ID, revision=REVISION, local_dir=str(MODEL_DEST))
    SHA_FILE.write_text(resolved + "\n")
    total_mb = sum(p.stat().st_size for p in MODEL_DEST.rglob("*") if p.is_file()) / 1_048_576
    print(f"  {sum(1 for _ in MODEL_DEST.iterdir())} files, {total_mb:.1f} MB, sha={resolved[:12]}")


def ensure_metallib() -> None:
    if METALLIB_DEST.exists() and (CWD_METALLIB.exists() or CWD_METALLIB.is_symlink()):
        print(f"Metallib already present ({METAL_PACKAGE}=={METAL_VERSION}) — nothing to do.")
        return
    print(f"Fetching version-matched metallib from {METAL_PACKAGE}=={METAL_VERSION} (PyPI) ...")
    meta = json.load(urllib.request.urlopen(
        f"https://pypi.org/pypi/{METAL_PACKAGE}/{METAL_VERSION}/json"))
    # The macOS arm64 wheel carries the (Python-agnostic) metallib.
    wheel = next(
        f for f in meta["urls"]
        if f["filename"].endswith(".whl") and "macosx" in f["filename"] and "arm64" in f["filename"]
    )
    print(f"  wheel: {wheel['filename']}")
    data = urllib.request.urlopen(wheel["url"]).read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        metallib = z.read("mlx/lib/mlx.metallib")
    RESOURCES.mkdir(exist_ok=True)
    METALLIB_DEST.write_bytes(metallib)
    # `swift test` resolves the metallib via the CWD fallback (default.metallib).
    if CWD_METALLIB.is_symlink() or CWD_METALLIB.exists():
        CWD_METALLIB.unlink()
    try:
        CWD_METALLIB.symlink_to(METALLIB_DEST)
    except OSError:
        CWD_METALLIB.write_bytes(metallib)  # symlink-unfriendly FS: fall back to a copy
    print(f"  metallib: {len(metallib) / 1e6:.0f} MB -> {METALLIB_DEST} (+ CWD link {CWD_METALLIB.name})")


def main() -> None:
    ensure_model()
    ensure_metallib()
    print("\nNext: run validate.py to confirm the non-garbage + self-consistent gate.")


if __name__ == "__main__":
    main()
