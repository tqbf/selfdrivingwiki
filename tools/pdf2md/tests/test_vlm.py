"""Slow conversion-quality tests for pdf2md — real PDF, standard + VLM pipeline.

These tests require a real PDF on disk AND the ~2 GB docling + granite model
download.  They can hang when run in the same session as other docling tests
(likely GPU resource contention), so they live in their own file.

Run on demand:
    uv run pytest tests/test_vlm.py -v

The default suite (tests/test_integration.py + tests/test_pdf2md.py) never
touches these.
"""

from __future__ import annotations

from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "pdf2md"
assert _SCRIPT_PATH.exists(), f"pdf2md script not found at {_SCRIPT_PATH}"
_pdf2md = SourceFileLoader("pdf2md", str(_SCRIPT_PATH)).load_module()


@pytest.mark.slow
class TestFullConversion:
    """End-to-end PDF→Markdown conversion — needs a real PDF."""

    def test_converts_pdf_to_non_empty_markdown(self, real_pdf_or_skip):
        text = _pdf2md.convert_pdf(real_pdf_or_skip, pipeline="standard")
        assert isinstance(text, str)
        assert len(text.strip()) > 0

    def test_converts_pdf_with_vlm_pipeline(self, real_pdf_or_skip):
        text = _pdf2md.convert_pdf(real_pdf_or_skip, pipeline="vlm")
        assert isinstance(text, str)
        assert len(text.strip()) > 0

    def test_output_is_valid_utf8(self, real_pdf_or_skip):
        text = _pdf2md.convert_pdf(real_pdf_or_skip, pipeline="standard")
        text.encode("utf-8")  # does not raise

    def test_output_has_no_soft_hyphens(self, real_pdf_or_skip):
        text = _pdf2md.convert_pdf(real_pdf_or_skip, pipeline="standard")
        assert "­" not in text

    def test_nonexistent_file_raises(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            _pdf2md.convert_pdf(tmp_path / "nonexistent.pdf", pipeline="standard")
