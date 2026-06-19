"""Fast integration tests for pdf2md — CLI behaviour, stdout/file I/O, error
handling.  No heavy PDF required; the `minimal_pdf` fixture (538 bytes, "Hello
World") is fast, deterministic, and never hangs.

Run from the tools/pdf2md directory:
    uv run pytest tests/test_integration.py -v

For real-PDF conversion quality tests (standard + VLM pipeline), see
tests/test_vlm.py.  Those tests are slow and require a real PDF on disk.
"""

from __future__ import annotations

import json
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

# ── Import the pdf2md module ──────────────────────────────────────────────

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "pdf2md"
assert _SCRIPT_PATH.exists(), f"pdf2md script not found at {_SCRIPT_PATH}"
_pdf2md = SourceFileLoader("pdf2md", str(_SCRIPT_PATH)).load_module()


# ── CLI: stdout path ──────────────────────────────────────────────────────
# The code path PdfExtractionService.run() exercises — pdf2md writes
# markdown to stdout, which the Swift side reads through a pipe.


class TestCLIStdout:
    """Test that main() writes markdown to stdout."""

    def test_stdout_contains_markdown(self, minimal_pdf, capsys):
        _pdf2md.main(argv=[str(minimal_pdf)])
        captured = capsys.readouterr()
        assert len(captured.out.strip()) > 0, "stdout should contain markdown text"
        assert "Error:" not in captured.err, (
            f"stderr should not contain errors, got: {captured.err!r}"
        )

    def test_stdout_matches_file_output(self, minimal_pdf, tmp_path, capsys):
        """The markdown written to stdout must be byte-identical to --output."""
        out = tmp_path / "out.md"
        _pdf2md.main(argv=["-o", str(out), str(minimal_pdf)])
        file_content = out.read_text()

        _pdf2md.main(argv=[str(minimal_pdf)])
        stdout_content = capsys.readouterr().out

        assert stdout_content == file_content, (
            "stdout and --output must produce identical markdown"
        )

    def test_json_to_stdout(self, minimal_pdf, capsys):
        """--json writes metadata to stdout (no markdown)."""
        _pdf2md.main(argv=["--json", str(minimal_pdf)])
        captured = capsys.readouterr()
        data = json.loads(captured.out.strip())
        assert "char_count" in data
        assert "line_count" in data
        assert data["char_count"] > 0
        assert data["line_count"] > 0
        assert data["pipeline"] == "vlm"

    def test_json_ignores_output_flag(self, minimal_pdf, tmp_path, capsys):
        """--json always writes to stdout; the -o flag is ignored for JSON.
        This is existing behaviour — documented, not prescribed."""
        out = tmp_path / "out.json"
        _pdf2md.main(argv=["--json", "-o", str(out), str(minimal_pdf)])
        captured = capsys.readouterr()
        data = json.loads(captured.out.strip())
        assert data["char_count"] > 0
        assert not out.exists()  # --json ignores -o


# ── CLI: JSON mode ────────────────────────────────────────────────────────


class TestCLIJSONMode:
    """Test --json output format (uses minimal PDF — JSON behaviour, not quality).
    --json always writes to stdout (the -o flag is ignored for JSON), so these
    capture stdout."""

    def test_json_output_is_valid(self, minimal_pdf, capsys):
        _pdf2md.main(argv=["--json", str(minimal_pdf)])
        data = json.loads(capsys.readouterr().out.strip())
        assert "input" in data
        assert "pipeline" in data
        assert "char_count" in data
        assert "line_count" in data
        assert data["char_count"] > 0
        assert data["line_count"] > 0

    def test_json_output_default_pipeline(self, minimal_pdf, capsys):
        _pdf2md.main(argv=["--json", str(minimal_pdf)])
        data = json.loads(capsys.readouterr().out.strip())
        assert data["pipeline"] == "vlm"

    def test_json_output_standard_pipeline_flag(self, minimal_pdf, capsys):
        _pdf2md.main(argv=["--json", "--pipeline", "standard", str(minimal_pdf)])
        data = json.loads(capsys.readouterr().out.strip())
        assert data["pipeline"] == "standard"


# ── CLI: file output ──────────────────────────────────────────────────────


class TestCLIOutputFile:
    """Test --output writes markdown to a file."""

    def test_output_file_written(self, minimal_pdf, tmp_path):
        out = tmp_path / "out.md"
        _pdf2md.main(argv=["-o", str(out), str(minimal_pdf)])
        assert out.exists()
        content = out.read_text()
        assert len(content.strip()) > 0

    def test_output_file_overwrites(self, minimal_pdf, tmp_path):
        out = tmp_path / "out.md"
        out.write_text("preexisting content")
        _pdf2md.main(argv=["-o", str(out), str(minimal_pdf)])
        assert out.read_text() != "preexisting content"

    def test_json_stdout_metadata(self, minimal_pdf, capsys):
        """--json writes metadata to stdout (no -o flag needed)."""
        _pdf2md.main(argv=["--json", str(minimal_pdf)])
        captured = capsys.readouterr()
        data = json.loads(captured.out.strip())
        assert data["char_count"] == 11  # "Hello World" is 11 characters
        assert data["line_count"] == 1
        assert data["pipeline"] == "vlm"


# ── CLI: error handling ───────────────────────────────────────────────────


class TestErrorOutput:
    """Error messages go to the right file descriptor."""

    def test_nonexistent_file_error_to_stderr(self, capsys):
        with pytest.raises(SystemExit) as exc:
            _pdf2md.main(argv=["/nonexistent/path.pdf"])
        assert exc.value.code == 1
        captured = capsys.readouterr()
        assert captured.out == "", "stdout should be empty on error"
        assert "Error:" in captured.err
        assert "nonexistent" in captured.err

    def test_nonexistent_file_also_stderr_in_json_mode(self, capsys):
        """The file-exists check runs before --json is consulted, so
        'file not found' always goes to stderr regardless of --json."""
        with pytest.raises(SystemExit) as exc:
            _pdf2md.main(argv=["--json", "/nonexistent/path.pdf"])
        assert exc.value.code == 1
        captured = capsys.readouterr()
        assert captured.out == ""
        assert "Error:" in captured.err
        assert "nonexistent" in captured.err
