"""Shared fixtures for pdf2md tests."""

from __future__ import annotations

from pathlib import Path

import pytest

# ── Minimal hand-crafted PDF ──────────────────────────────────────────────
# A tiny valid PDF with known extractable text ("Hello World").  Used by
# tests that only care about the I/O path (stdout, file output, JSON, error
# handling), not conversion quality.  Fast, deterministic, never hangs.

_MINIMAL_PDF_BYTES = (
    b"%PDF-1.4\n"
    b"1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
    b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
    b"3 0 obj<</Type/Page/MediaBox[0 0 612 792]/Parent 2 0 R"
    b"/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj\n"
    b"4 0 obj<</Length 44>>stream\n"
    b"BT /F1 12 Tf 72 720 Td (Hello World) Tj ET\n"
    b"endstream\nendobj\n"
    b"5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n"
    b"xref\n0 6\n0000000000 65535 f \n0000000009 00000 n \n"
    b"0000000058 00000 n \n0000000115 00000 n \n"
    b"0000000266 00000 n \n0000000360 00000 n \n"
    b"trailer<</Size 6/Root 1 0 R>>\nstartxref\n437\n%%EOF"
)


@pytest.fixture(scope="session")
def minimal_pdf(tmp_path_factory) -> Path:
    """A tiny valid PDF with known text ('Hello World').  Created once per session."""
    p = tmp_path_factory.mktemp("pdf") / "minimal.pdf"
    p.write_bytes(_MINIMAL_PDF_BYTES)
    return p


# ── Real-PDF fixtures (for quality/slow tests) ───────────────────────────


@pytest.fixture(scope="session")
def test_pdf() -> Path | None:
    """Return path to a valid test PDF, or None if none is available."""
    candidates = [
        Path.home() / "work/R2R/py/core/examples/supported_file_types/pdf.pdf",
        Path.home() / "work/hermes-agent/docs/hermes-kanban-v1-spec.pdf",
    ]
    for p in candidates:
        if p.exists() and p.stat().st_size > 100:
            return p
    return None


@pytest.fixture(scope="session")
def real_pdf_or_skip(test_pdf: Path | None) -> Path:  # pyright: ignore[reportReturnType]
    """Verify the PDF exists and is non-empty.  Skips the test if not."""
    if test_pdf is None:
        pytest.skip("No test PDF available — set TEST_PDF env var to a PDF path")
    if test_pdf.stat().st_size == 0:  # pyright: ignore[reportOptionalMemberAccess]
        pytest.skip("Test PDF is empty")
    return test_pdf
