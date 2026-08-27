"""Tests for pdf2md's extractor protocol mode.

The host writes one JSON request on standard input and reads JSON Lines
frames from standard output. These tests never invoke docling: they replace
`convert_pdf` so the protocol contract is verified on its own.

Run from the tools/pdf2md directory:
    uv run pytest tests/test_extractor_protocol.py -v
"""

from __future__ import annotations

import io
import json
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "pdf2md"
assert _SCRIPT_PATH.exists(), f"pdf2md script not found at {_SCRIPT_PATH}"

_pdf2md = SourceFileLoader("pdf2md", str(_SCRIPT_PATH)).load_module()
sys.modules["pdf2md"] = _pdf2md


def _request(tmp_path: Path, **overrides) -> dict:
    source = tmp_path / "input" / "source.pdf"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"%PDF-1.4\n")
    request = {
        "requestID": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
        "protocolRevision": 1,
        "kind": "pdf",
        "mimeType": "application/pdf",
        "originalFilename": "source.pdf",
        "inputTransport": "operation-file",
        "inputPath": str(source),
        "outputPath": str(tmp_path / "output" / "result.md"),
        "deadlineMillisecondsSince1970": 4102444800000,
    }
    request.update(overrides)
    return request


def _run(request, monkeypatch=None, markdown="# Converted\n", raises=None):
    """Run one request and return (exit code, parsed frames, stderr text)."""
    if monkeypatch is not None:

        def fake_convert(pdf_path, pipeline):
            # Prove stdout redirection: a package that prints must not
            # corrupt the frame stream.
            print("docling chatter that must not reach stdout")
            if raises is not None:
                raise raises
            return markdown

        monkeypatch.setattr(_pdf2md, "convert_pdf", fake_convert)

    out = io.StringIO()
    log = io.StringIO()
    text = request if isinstance(request, str) else json.dumps(request)
    code = _pdf2md.run_extractor_protocol(text, out_stream=out, log_stream=log)
    frames = [json.loads(line) for line in out.getvalue().splitlines() if line]
    return code, frames, log.getvalue()


class TestSuccessfulRequest:
    def test_emits_progress_then_one_result(self, tmp_path, monkeypatch):
        request = _request(tmp_path)
        code, frames, _ = _run(request, monkeypatch)

        assert code == 0
        assert [f["kind"] for f in frames] == ["progress", "progress", "result"]
        assert sum(1 for f in frames if f["kind"] in ("result", "failure")) == 1

    def test_result_reports_the_requested_output_path_and_byte_count(self, tmp_path, monkeypatch):
        request = _request(tmp_path)
        _, frames, _ = _run(request, monkeypatch, markdown="# Title\n\nBody\n")

        result = frames[-1]["payload"]
        assert result["requestID"] == request["requestID"]
        assert result["outputPath"] == request["outputPath"]
        assert result["markdownByteCount"] == len(b"# Title\n\nBody\n")

    def test_writes_markdown_to_the_output_path(self, tmp_path, monkeypatch):
        request = _request(tmp_path)
        _run(request, monkeypatch, markdown="# Written\n")

        assert Path(request["outputPath"]).read_text(encoding="utf-8") == "# Written\n"

    def test_reports_tool_and_model_metadata(self, tmp_path, monkeypatch):
        _, frames, _ = _run(_request(tmp_path), monkeypatch)

        metadata = frames[-1]["payload"]["metadata"]
        assert metadata["toolName"] == "pdf2md"
        assert metadata["modelName"] == "granite-docling-mlx"

    def test_conversion_output_never_reaches_the_frame_stream(self, tmp_path, monkeypatch):
        _, frames, log = _run(_request(tmp_path), monkeypatch)

        # Every stdout line parsed as a frame above, and the chatter landed
        # on the log stream instead.
        assert all(f["kind"] in ("progress", "result") for f in frames)
        assert "docling chatter" in log


class TestRefusedRequest:
    def test_unsupported_protocol_revision_fails_the_request(self, tmp_path, monkeypatch):
        code, frames, _ = _run(_request(tmp_path, protocolRevision=99), monkeypatch)

        assert code == 0
        assert frames[-1]["kind"] == "failure"
        assert frames[-1]["payload"]["cause"] == "invalid-request"

    def test_non_pdf_kind_is_unsupported_input(self, tmp_path, monkeypatch):
        _, frames, _ = _run(_request(tmp_path, kind="html"), monkeypatch)

        assert frames[-1]["payload"]["cause"] == "unsupported-input"

    def test_missing_input_file_is_an_invalid_request(self, tmp_path, monkeypatch):
        request = _request(tmp_path, inputPath=str(tmp_path / "absent.pdf"))
        _, frames, _ = _run(request, monkeypatch)

        assert frames[-1]["payload"]["cause"] == "invalid-request"

    def test_malformed_request_exits_nonzero_without_a_frame(self, tmp_path):
        code, frames, log = _run("not json at all")

        assert code == 2
        assert frames == []
        assert "malformed" in log

    def test_request_without_an_id_exits_nonzero_without_a_frame(self, tmp_path):
        code, frames, _ = _run({"protocolRevision": 1})

        assert code == 2
        assert frames == []


class TestFailedConversion:
    def test_empty_extraction_reports_extraction_failure(self, tmp_path, monkeypatch):
        _, frames, _ = _run(
            _request(tmp_path), monkeypatch, raises=ValueError("PDF contains no extractable text")
        )

        assert frames[-1]["kind"] == "failure"
        assert frames[-1]["payload"]["cause"] == "extraction-failure"
        assert "no extractable text" in frames[-1]["payload"]["message"]

    def test_absent_docling_reports_a_missing_runtime(self, tmp_path, monkeypatch):
        _, frames, _ = _run(_request(tmp_path), monkeypatch, raises=SystemExit(3))

        assert frames[-1]["payload"]["cause"] == "missing-runtime"

    def test_unexpected_error_reports_extraction_failure(self, tmp_path, monkeypatch):
        _, frames, _ = _run(_request(tmp_path), monkeypatch, raises=RuntimeError("boom"))

        assert frames[-1]["payload"]["cause"] == "extraction-failure"
        assert "boom" in frames[-1]["payload"]["message"]

    def test_a_failed_request_still_emits_exactly_one_terminal_frame(self, tmp_path, monkeypatch):
        _, frames, _ = _run(_request(tmp_path), monkeypatch, raises=RuntimeError("boom"))

        assert sum(1 for f in frames if f["kind"] in ("result", "failure")) == 1


class TestHumanCLIIsPreserved:
    def test_parser_still_accepts_a_bare_input_path(self):
        args = _pdf2md.build_parser().parse_args(["input.pdf"])

        assert args.input == Path("input.pdf")
        assert args.extractor_protocol is False

    def test_parser_accepts_protocol_mode_without_an_input(self):
        args = _pdf2md.build_parser().parse_args(["--extractor-protocol"])

        assert args.extractor_protocol is True
        assert args.input is None

    def test_missing_input_without_protocol_mode_is_a_usage_error(self):
        with pytest.raises(SystemExit):
            _pdf2md.main([])
