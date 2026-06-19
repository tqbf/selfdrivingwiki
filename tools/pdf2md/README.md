# pdf2md

Convert a PDF to Markdown using [docling](https://github.com/docling-project/docling) +
[granite-docling](https://www.ibm.com/granite/docs/models/docling) VLM pipeline
(runs locally on Apple Silicon via MLX).

Part of [Self Driving Wiki](../..) — replaces Claude `Read`-tool PDF extraction
with a local, deterministic pipeline.

## Quick start

```bash
# First run: uv downloads Python + dependencies (one-time cost, ~2 GB)
./pdf2md input.pdf

# Write to file
./pdf2md input.pdf -o output.md

# Faster pipeline for text-heavy digital PDFs
./pdf2md input.pdf --pipeline standard

# JSON metadata instead of markdown
./pdf2md input.pdf --json
```

**Requirements:** [uv](https://docs.astral.sh/uv/) (installs automatically if
missing — run `curl -LsSf https://astral.sh/uv/install.sh | sh`).

## Development

```bash
# Default suite (unit + fast integration — safe, never hangs)
uv run pytest tests/ -v

# VLM pipeline tests (slow, needs real PDF + ~2 GB granite model)
uv run pytest tests/test_vlm.py -v

# Lint
uv run ruff check pdf2md tests/

# Type check
uv run pyright pdf2md tests/
```

## Files

| File | Purpose |
|---|---|
| `pdf2md` | PEP 723 inline script — the tool itself |
| `pyproject.toml` | Dependencies + tool config (ruff, pyright, pytest) |
| `tests/test_pdf2md.py` | Unit tests (regex, cleanup, CLI parsing) |
| `tests/test_integration.py` | Fast integration tests (CLI I/O, JSON, errors — minimal PDF fixture) |
| `tests/test_vlm.py` | Slow quality tests (standard + VLM pipeline with real PDF) |
| `tests/conftest.py` | Shared fixtures (minimal_pdf, real_pdf_or_skip) |

## Architecture

A single-file Python script with embedded dependency metadata (PEP 723).
`uv run --script pdf2md` reads the inline `# /// script` block, creates an
ephemeral venv, installs dependencies, and executes.

- **VLM pipeline** (`--pipeline vlm`, default): `VlmPipeline` +
  `GRANITEDOCLING_MLX` — best quality, runs on Apple Silicon GPU via MLX.
- **Standard pipeline** (`--pipeline standard`): multi-stage pipeline with
  OCR + table structure — faster, good for born-digital PDFs.
- **Post-processing:** margin line-number stripping, soft-hyphen removal,
  multi-space collapse, spaCy sentence-aware page-break joining.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Unable to parse PDF (corrupted, not found) |
| 2 | PDF contains no extractable text |
| 3 | docling not available |
