"""Unit tests for the extractor-package protocol entry point.

The reviewed package serves ONE revision-3 `remote-url` request per process:
a JSON request object on stdin, JSON Lines frames on stdout, Markdown only at
the requested output path. These tests pin the request parsing, transport
rules, failure mapping, bounded diagnostics, and output byte accounting.

Run from the tools/podcast-transcript directory:
    uv run pytest tests/test_package_protocol.py -v
"""

from __future__ import annotations

import io
import json
import sys
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch

import pytest
import requests

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "podcast-transcript"
assert _SCRIPT_PATH.exists(), f"podcast-transcript script not found at {_SCRIPT_PATH}"

_loader = SourceFileLoader("podcast_transcript", str(_SCRIPT_PATH))
_podcast = _loader.load_module()
sys.modules["podcast_transcript"] = _podcast

_REQUEST_ID = "4f25e76a-be09-467f-b71e-68c02da4d16a"


def _request(**overrides) -> dict:
    request = {
        "requestID": _REQUEST_ID,
        "protocolRevision": 3,
        "kind": "podcast-transcript",
        "mimeType": "audio/podcast",
        "originalFilename": "feed",
        "inputTransport": "remote-url",
        "remoteURL": "https://example.com/feed.rss",
        "outputPath": "output/result.md",
        "deadlineMillisecondsSince1970": 9999999999999,
    }
    request.update(overrides)
    return request


@pytest.fixture(autouse=True)
def _relative_output_path(tmp_path, monkeypatch):
    """Keep every write inside tmp: the default request outputPath is
    relative, and an unpatched write would pollute the working tree."""
    monkeypatch.chdir(tmp_path)
    return None


def _serve(request: dict | str, fetch: object = "ok") -> tuple[int, list[dict], str]:
    """Run one protocol request through ``run_extractor_protocol``.

    ``fetch`` stubs ``fetch_transcript``: a string is the returned markdown
    (no network), a BaseException is raised from it, and ``None`` runs the
    real function unpatched.
    """
    out = io.StringIO()
    request_text = request if isinstance(request, str) else json.dumps(request)
    if fetch is None:
        code = _podcast.run_extractor_protocol(
            request_text, out_stream=out, log_stream=io.StringIO()
        )
    elif isinstance(fetch, BaseException):
        with patch.object(_podcast, "fetch_transcript", side_effect=fetch):
            code = _podcast.run_extractor_protocol(
                request_text, out_stream=out, log_stream=io.StringIO()
            )
    else:
        result = {
            "show_id": None,
            "episode_id": None,
            "language": "en",
            "format": "vtt",
            "markdown": fetch,
        }
        with patch.object(_podcast, "fetch_transcript", return_value=result):
            code = _podcast.run_extractor_protocol(
                request_text, out_stream=out, log_stream=io.StringIO()
            )
    frames = [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
    return code, frames, out.getvalue()


def _terminal(frames: list[dict]) -> dict:
    terminal = [frame for frame in frames if frame["kind"] in ("result", "failure")]
    assert len(terminal) == 1, f"expected exactly one terminal frame, got {frames}"
    return terminal[0]


# ── Request parsing ───────────────────────────────────────────────────────────


class TestRequestParsing:
    def test_valid_request_emits_progress_and_one_result(self, tmp_path):
        request = _request(outputPath=str(tmp_path / "out/result.md"))
        code, frames, _ = _serve(request, fetch="hello world")
        assert code == 0
        assert [frame["kind"] for frame in frames] == ["progress", "progress", "progress", "result"]
        result = _terminal(frames)
        assert result["payload"]["requestID"] == _REQUEST_ID
        assert result["payload"]["metadata"] == {"toolName": "podcast-transcript"}

    def test_result_byte_count_matches_written_markdown(self, tmp_path):
        destination = tmp_path / "out/result.md"
        markdown = "line one\n\nline two"
        code, frames, _ = _serve(_request(outputPath=str(destination)), fetch=markdown)
        written = destination.read_text(encoding="utf-8")
        assert written == f"# Podcast Transcript\n\n{markdown}"
        assert _terminal(frames)["payload"]["markdownByteCount"] == len(written.encode("utf-8"))

    def test_markdown_is_written_only_to_the_output_path(self, tmp_path):
        destination = tmp_path / "out/result.md"
        _serve(_request(outputPath=str(destination)), fetch="text")
        assert destination.exists()
        assert list(tmp_path.rglob("*.md")) == [destination]

    def test_malformed_request_json_exits_nonzero_without_frames(self):
        code, frames, _ = _serve("not json", fetch=None)
        assert code == 2
        assert frames == []

    def test_request_without_id_exits_nonzero_without_frames(self):
        code, frames, _ = _serve('{"protocolRevision": 3}', fetch=None)
        assert code == 2
        assert frames == []


# ── Transport and revision rules ─────────────────────────────────────────────


class TestTransportRules:
    def test_wrong_protocol_revision_is_invalid_request(self):
        code, frames, _ = _serve(_request(protocolRevision=2))
        assert code == 0
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "invalid-request"

    def test_wrong_kind_is_unsupported_input(self):
        code, frames, _ = _serve(_request(kind="pdf"))
        assert code == 0
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "unsupported-input"

    def test_operation_file_transport_is_rejected(self):
        code, frames, _ = _serve(
            _request(inputTransport="operation-file", remoteURL=None, inputPath="input/source")
        )
        assert code == 0
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "invalid-request"
        assert failure["payload"]["message"] == "this package accepts a remote URL only"

    def test_missing_remote_url_is_invalid_request(self):
        code, frames, _ = _serve(_request(remoteURL=None))
        assert code == 0
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "invalid-request"

    def test_missing_output_path_is_invalid_request(self):
        code, frames, _ = _serve(_request(outputPath=None))
        assert code == 0
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "invalid-request"

    def test_passed_deadline_fails_with_timeout(self):
        request = _request(deadlineMillisecondsSince1970=int(time.time() * 1000) - 1_000)
        code, frames, _ = _serve(request)
        assert code == 0
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "timeout"


# ── Failure mapping ──────────────────────────────────────────────────────────


class TestFailureMapping:
    def test_podcast_not_found_maps_to_unsupported_input(self):
        code, frames, _ = _serve(_request(), fetch=ValueError("Podcast not found (show_id: 123)"))
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "unsupported-input"
        assert "123" not in failure["payload"]["message"]

    def test_missing_transcript_maps_to_unsupported_input(self):
        code, frames, _ = _serve(
            _request(), fetch=ValueError("No transcript available (use --transcribe)")
        )
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "unsupported-input"

    def test_episode_not_found_maps_to_unsupported_input(self):
        code, frames, _ = _serve(_request(), fetch=ValueError("Episode not found in feed"))
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "unsupported-input"

    def test_network_failure_maps_to_extraction_failure(self):
        code, frames, _ = _serve(_request(), fetch=requests.ConnectionError("refused"))
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "extraction-failure"
        assert failure["payload"]["message"] == "feed or transcript request failed"

    def test_unexpected_failure_maps_to_extraction_failure(self):
        code, frames, _ = _serve(_request(), fetch=RuntimeError("boom"))
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "extraction-failure"

    def test_empty_markdown_maps_to_extraction_failure(self, tmp_path):
        code, frames, _ = _serve(_request(outputPath=str(tmp_path / "out.md")), fetch="   ")
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "extraction-failure"
        assert not (tmp_path / "out.md").exists()

    def test_write_failure_maps_to_extraction_failure(self):
        request = _request(outputPath="/proc/definitely/not/writable.md")
        code, frames, _ = _serve(request, fetch="text")
        failure = _terminal(frames)
        assert failure["payload"]["cause"] == "extraction-failure"


# ── Bounded diagnostics ──────────────────────────────────────────────────────


class TestBoundedDiagnostics:
    def test_failure_messages_never_contain_the_source_url(self):
        url = "https://secret-host.example/very/secret/feed.rss"
        code, frames, _ = _serve(
            _request(remoteURL=url), fetch=requests.ConnectionError(f"refused {url}")
        )
        rendered = json.dumps(frames)
        assert url not in rendered
        assert "secret-host" not in rendered

    def test_failure_message_is_truncated_to_the_protocol_bound(self):
        code, frames, _ = _serve(
            _request(), fetch=ValueError("No transcript available " + "x" * 10_000)
        )
        message = _terminal(frames)["payload"]["message"]
        assert len(message) <= 4096

    def test_no_source_content_reaches_any_frame(self, tmp_path):
        destination = tmp_path / "out/result.md"
        transcript = "SECRET-TRANSCRIPT-CONTENT"
        code, frames, _ = _serve(_request(outputPath=str(destination)), fetch=transcript)
        rendered = json.dumps(frames)
        assert transcript not in rendered
