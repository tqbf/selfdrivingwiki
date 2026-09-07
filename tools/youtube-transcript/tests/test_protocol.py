"""Protocol revision 3 tests for the youtube-transcript extractor entry point.

Run from the tools/youtube-transcript directory:
    uv run pytest tests/test_protocol.py -v

All youtube-transcript-api behavior is mocked — no network access required.
Failure messages are fixed strings: these tests double as the redaction
contract, asserting the source URL, video IDs, upstream error text, and
paths never reach a frame or stderr.
"""

from __future__ import annotations

import io
import json
import sys
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

import pytest
from conftest import (
    IpBlocked,
    MockFetchedTranscript,
    MockTranscript,
    NoTranscriptFound,
    RequestBlocked,
    TranscriptsDisabled,
    VideoUnavailable,
    YouTubeDataUnparsable,
    YouTubeRequestFailed,
    build_mock_segments,
)

# ── Import the youtube-transcript module (extensionless script) ────────

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "youtube-transcript"
assert _SCRIPT_PATH.exists(), f"youtube-transcript script not found at {_SCRIPT_PATH}"

_yt = SourceFileLoader("youtube_transcript", str(_SCRIPT_PATH)).load_module()
sys.modules["youtube_transcript"] = _yt

_REQUEST_ID = "11111111-2222-3333-4444-555555555555"
_VIDEO_ID = "dQw4w9WgXcQ"


@pytest.fixture(autouse=True)
def _operation_root(tmp_path: Path, monkeypatch: Any) -> None:
    """The host runs the package with its CWD at the operation root.

    Relative request paths must therefore resolve inside each test's
    temporary directory, exactly as they resolve inside the private
    operation directory in production.
    """
    monkeypatch.chdir(tmp_path)


# ── Helpers ────────────────────────────────────────────────────────────


def _deadline_ms(seconds_from_now: float = 300) -> int:
    return int((time.time() + seconds_from_now) * 1000)


def _request(**overrides: Any) -> dict[str, Any]:
    request: dict[str, Any] = {
        "requestID": _REQUEST_ID,
        "protocolRevision": 3,
        "kind": "youtube-transcript",
        "mimeType": "video/youtube",
        "originalFilename": "youtube-dQw4w9WgXcQ",
        "inputTransport": "remote-url",
        "remoteURL": f"https://www.youtube.com/watch?v={_VIDEO_ID}",
        "outputPath": "output/result.md",
        "deadlineMillisecondsSince1970": _deadline_ms(),
    }
    request.update(overrides)
    return request


def _run(
    request: dict[str, Any] | str,
    mocker: Any,
    mock_yta: Any,
    fetched: Any = None,
) -> tuple[int, str, str]:
    """Serve one request against mocked library behavior."""
    mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
    if fetched is not None:
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = fetched
    out = io.StringIO()
    err = io.StringIO()
    text = request if isinstance(request, str) else json.dumps(request)
    code = _yt.run_extractor_protocol(text, out_stream=out, log_stream=err)
    return code, out.getvalue(), err.getvalue()


def _frames(out_text: str) -> list[dict[str, Any]]:
    return [json.loads(line) for line in out_text.splitlines() if line.strip()]


def _terminal(frames: list[dict[str, Any]]) -> dict[str, Any]:
    terminals = [f for f in frames if f["kind"] in ("result", "failure")]
    assert len(terminals) == 1, f"expected exactly one terminal frame, got {terminals}"
    return terminals[0]


def _failure_cause(out_text: str) -> str:
    terminal = _terminal(_frames(out_text))
    assert terminal["kind"] == "failure"
    return terminal["payload"]["cause"]


def _watch_url(video_id: str = _VIDEO_ID) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


# ── Strict URL → video ID extraction (package path) ────────────────────


class TestStrictUrlExtraction:
    @pytest.mark.parametrize(
        ("url", "expected"),
        [
            (f"https://www.youtube.com/watch?v={_VIDEO_ID}", _VIDEO_ID),
            (f"https://youtube.com/watch?v={_VIDEO_ID}", _VIDEO_ID),
            (f"https://m.youtube.com/watch?v={_VIDEO_ID}", _VIDEO_ID),
            (f"https://youtu.be/{_VIDEO_ID}", _VIDEO_ID),
            (f"https://www.youtu.be/{_VIDEO_ID}", _VIDEO_ID),
            (f"https://www.youtube.com/shorts/{_VIDEO_ID}", _VIDEO_ID),
            (f"https://www.youtube.com/embed/{_VIDEO_ID}", _VIDEO_ID),
            (f"https://www.youtube.com/watch?v={_VIDEO_ID}&t=90s", _VIDEO_ID),
        ],
    )
    def test_supported_forms(self, url: str, expected: str) -> None:
        assert _yt.extract_video_id_from_url(url) == expected

    @pytest.mark.parametrize(
        "url",
        [
            f"https://example.com/watch?v={_VIDEO_ID}",
            "ftp://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/watch?v=short",
            f"https://www.youtube.com/watch?v={_VIDEO_ID}0",
            "https://www.youtube.com",
            "https://www.youtube.com/watch?t=90",
            f"https://user:pass@www.youtube.com/watch?v={_VIDEO_ID}",
            f"https://www.youtube.com/watch?v={_VIDEO_ID}#fragment",
            f"https://youtu.be/{_VIDEO_ID}/extra",
            "not a url",
            "",
        ],
    )
    def test_rejected_forms(self, url: str) -> None:
        assert _yt.extract_video_id_from_url(url) is None

    def test_over_limit_url_rejected(self) -> None:
        url = _watch_url() + "&x=" + "a" * 4096
        assert _yt.extract_video_id_from_url(url) is None


# ── Request validation (before any network work) ───────────────────────


class TestRequestValidation:
    def test_wrong_protocol_revision(self, mocker, mock_yta):
        code, out, _ = _run(_request(protocolRevision=2), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "invalid-request"
        assert mock_yta.YouTubeTranscriptApi.call_count == 0

    def test_wrong_kind(self, mocker, mock_yta):
        code, out, _ = _run(_request(kind="podcast-transcript"), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "unsupported-input"

    def test_wrong_mime_type(self, mocker, mock_yta):
        code, out, _ = _run(_request(mimeType="audio/podcast"), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "unsupported-input"

    def test_wrong_transport(self, mocker, mock_yta):
        code, out, _ = _run(_request(inputTransport="operation-file"), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "invalid-request"

    def test_remote_url_request_must_not_carry_input_path(self, mocker, mock_yta):
        code, out, _ = _run(_request(inputPath="input/source"), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "invalid-request"

    @pytest.mark.parametrize(
        "remote_url",
        [None, "", 42, f"https://example.com/watch?v={_VIDEO_ID}"],
    )
    def test_unsupported_or_missing_source_url(self, mocker, mock_yta, remote_url):
        code, out, _ = _run(_request(remoteURL=remote_url), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) in ("invalid-request", "unsupported-input")
        assert mock_yta.YouTubeTranscriptApi.call_count == 0

    def test_over_limit_source_url(self, mocker, mock_yta):
        url = _watch_url() + "&x=" + "a" * 4096
        code, out, _ = _run(_request(remoteURL=url), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "invalid-request"

    @pytest.mark.parametrize(
        "deadline",
        [None, "soon", True, 0, -5],
    )
    def test_invalid_deadline(self, mocker, mock_yta, deadline):
        code, out, _ = _run(_request(deadlineMillisecondsSince1970=deadline), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "invalid-request"
        assert mock_yta.YouTubeTranscriptApi.call_count == 0

    @pytest.mark.parametrize(
        "output_path",
        [None, "", "/abs/result.md", "output\\result.md", "..", "a/../b.md", "a//b.md", "out/"],
    )
    def test_invalid_output_path(self, mocker, mock_yta, output_path, tmp_path):
        code, out, _ = _run(_request(outputPath=output_path), mocker, mock_yta)
        assert code == 0
        assert _failure_cause(out) == "invalid-request"
        assert mock_yta.YouTubeTranscriptApi.call_count == 0

    def test_oversized_request_document_is_unframeable(self, mocker, mock_yta):
        oversized = _request(junk="x" * (1_048_577))
        code, out, err = _run(oversized, mocker, mock_yta)
        assert code == 2
        assert out == ""

    def test_malformed_json_is_unframeable(self, mocker, mock_yta):
        code, out, err = _run("{not json", mocker, mock_yta)
        assert code == 2
        assert out == ""

    def test_missing_request_id_is_unframeable(self, mocker, mock_yta):
        request = _request()
        del request["requestID"]
        code, out, err = _run(request, mocker, mock_yta)
        assert code == 2
        assert out == ""

    def test_non_object_request_is_unframeable(self, mocker, mock_yta):
        code, out, err = _run("[1, 2, 3]", mocker, mock_yta)
        assert code == 2
        assert out == ""


# ── Success path ───────────────────────────────────────────────────────


class TestSuccess:
    def test_writes_markdown_and_emits_one_result_frame(self, mocker, mock_yta, tmp_path):
        output_path = "output/result.md"
        code, out, err = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))

        assert code == 0
        frames = _frames(out)
        terminal = _terminal(frames)
        assert terminal["kind"] == "result"

        written = tmp_path / output_path
        content = written.read_text(encoding="utf-8")
        assert content.startswith(f"# YouTube Transcript: {_VIDEO_ID}\n\n")
        assert "Hello everyone" in content
        assert content.endswith("\n")

        result = terminal["payload"]
        assert result["requestID"] == _REQUEST_ID
        assert result["outputPath"] == output_path
        assert result["markdownByteCount"] == len(content.encode("utf-8"))

        # Atomic publication: no partial file remains beside the output.
        assert not (tmp_path / "output/result.md.partial").exists()

    @pytest.mark.parametrize(
        ("url", "label"),
        [
            (_watch_url(), "watch"),
            (f"https://youtu.be/{_VIDEO_ID}", "short"),
            (f"https://www.youtube.com/shorts/{_VIDEO_ID}", "shorts"),
            (f"https://www.youtube.com/embed/{_VIDEO_ID}", "embed"),
            (f"https://m.youtube.com/watch?v={_VIDEO_ID}", "mobile"),
        ],
    )
    def test_supported_url_forms_fetch_the_same_video(self, mocker, mock_yta, tmp_path, url, label):
        code, out, _ = _run(
            _request(remoteURL=url), mocker, mock_yta, fetched=MockFetchedTranscript("en")
        )
        assert code == 0
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result"
        fetched_id = mock_yta.YouTubeTranscriptApi.return_value.fetch.call_args.args[0]
        assert fetched_id == _VIDEO_ID

    def test_progress_frames_are_bounded_and_ordered(self, mocker, mock_yta):
        code, out, _ = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))
        frames = _frames(out)
        progress = [f for f in frames if f["kind"] == "progress"]
        assert len(progress) == 4
        assert [f["payload"]["completedUnitCount"] for f in progress] == [0, 1, 2, 3]
        assert all(f["payload"]["requestID"] == _REQUEST_ID for f in progress)
        # No frame may follow the terminal frame.
        assert frames[-1]["kind"] == "result"

    def test_progress_cap_never_exceeds_the_package_bound(self, mocker, mock_yta, monkeypatch):
        monkeypatch.setattr(_yt, "_MAX_PROGRESS_FRAMES", 2)
        code, out, _ = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))
        frames = _frames(out)
        progress = [f for f in frames if f["kind"] == "progress"]
        assert len(progress) == 2
        assert frames[-1]["kind"] == "result"

    def test_reported_metadata_carries_selection_facts(self, mocker, mock_yta):
        code, out, _ = _run(
            _request(),
            mocker,
            mock_yta,
            fetched=MockFetchedTranscript("es", is_generated=True),
        )
        terminal = _terminal(_frames(out))
        metadata = terminal["payload"]["metadata"]
        assert metadata["toolName"] == "youtube-transcript"
        assert metadata["toolVersion"] == "1.0.0"
        assert metadata["language"] == "es"
        assert metadata["transcriptGenerated"] is True

    def test_manual_captions_report_not_generated(self, mocker, mock_yta):
        code, out, _ = _run(
            _request(), mocker, mock_yta, fetched=MockFetchedTranscript("en", is_generated=False)
        )
        terminal = _terminal(_frames(out))
        assert terminal["payload"]["metadata"]["transcriptGenerated"] is False

    def test_missing_generated_status_is_omitted(self, mocker, mock_yta):
        # A plain list has no is_generated attribute — the older library
        # shape. The metadata key must be absent, never a guess.
        code, out, _ = _run(_request(), mocker, mock_yta, fetched=build_mock_segments())
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result"
        assert "transcriptGenerated" not in terminal["payload"]["metadata"]

    def test_fallback_track_selection_reports_its_language(self, mocker, mock_yta):
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        fallback = MockTranscript("fr", is_generated=True)
        mock_yta.YouTubeTranscriptApi.return_value.list.return_value = [fallback]

        code, out, _ = _run(_request(), mocker, mock_yta)
        terminal = _terminal(_frames(out))
        metadata = terminal["payload"]["metadata"]
        assert terminal["kind"] == "result"
        assert metadata["language"] == "fr"
        assert metadata["transcriptGenerated"] is True

    def test_empty_transcript_reports_no_captions(self, mocker, mock_yta, tmp_path):
        # A fetch with zero segments falls through to the track list; when
        # that finds nothing either, the video reports as caption-less.
        code, out, _ = _run(
            _request(), mocker, mock_yta, fetched=MockFetchedTranscript("en", segments=[])
        )
        assert code == 0
        assert _failure_cause(out) == "unsupported-input"
        assert not (tmp_path / "output/result.md").exists()

    def test_whitespace_only_captions_produce_no_text(self, mocker, mock_yta, tmp_path):
        segments = [{"text": "   ", "start": 0.0, "duration": 1.0}]
        code, out, _ = _run(
            _request(), mocker, mock_yta, fetched=MockFetchedTranscript("en", segments=segments)
        )
        assert code == 0
        assert _failure_cause(out) == "extraction-failure"
        assert not (tmp_path / "output/result.md").exists()


# ── Failure mapping ────────────────────────────────────────────────────


class TestFailureMapping:
    @pytest.mark.parametrize(
        ("exception", "expected_cause"),
        [
            (NoTranscriptFound("t"), "unsupported-input"),
            (TranscriptsDisabled("t"), "unsupported-input"),
            (VideoUnavailable("t"), "unsupported-input"),
            (RequestBlocked("t"), "extraction-failure"),
            (IpBlocked("t"), "extraction-failure"),
            (YouTubeRequestFailed("t"), "extraction-failure"),
            (YouTubeDataUnparsable("t"), "extraction-failure"),
            (RuntimeError("SECRET upstream detail"), "extraction-failure"),
        ],
    )
    def test_library_failures_map_to_typed_causes(
        self, mocker, mock_yta, tmp_path, exception, expected_cause
    ):
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = exception
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = exception

        code, out, err = _run(_request(), mocker, mock_yta)

        assert code == 0
        assert _failure_cause(out) == expected_cause
        # Failures write no transcript version and no partial output.
        assert not (tmp_path / "output/result.md").exists()
        assert not (tmp_path / "output/result.md.partial").exists()

    def test_generic_failure_discards_upstream_text(self, mocker, mock_yta):
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = RuntimeError(
            "SECRET-UPSTREAM-TEXT"
        )
        code, out, err = _run(_request(), mocker, mock_yta)
        terminal = _terminal(_frames(out))
        assert terminal["payload"]["message"] == "caption retrieval failed"
        assert "SECRET-UPSTREAM-TEXT" not in out
        assert "SECRET-UPSTREAM-TEXT" not in err


# ── Bounds: segments and output bytes ──────────────────────────────────


class TestBounds:
    def test_oversized_transcript_fails(self, mocker, mock_yta, monkeypatch, tmp_path):
        monkeypatch.setattr(_yt, "_MAX_OUTPUT_BYTES", 2000)
        monkeypatch.setattr(_yt, "_OUTPUT_RESERVE_BYTES", 600)
        # 10 segments x 200 bytes = 2000 bytes of body text alone.
        segments = [{"text": "я" * 100, "start": float(i), "duration": 1.0} for i in range(10)]
        code, out, _ = _run(
            _request(),
            mocker,
            mock_yta,
            fetched=MockFetchedTranscript("ru", segments=segments),
        )
        assert _failure_cause(out) == "extraction-failure"
        assert not (tmp_path / "output/result.md").exists()

    def test_multibyte_text_accounts_bytes_not_characters(
        self, mocker, mock_yta, monkeypatch, tmp_path
    ):
        monkeypatch.setattr(_yt, "_MAX_OUTPUT_BYTES", 2000)
        monkeypatch.setattr(_yt, "_OUTPUT_RESERVE_BYTES", 600)
        # 6 segments x 200 bytes = 1200 <= 1400 budget: passes.
        segments = [{"text": "я" * 100, "start": float(i), "duration": 1.0} for i in range(6)]
        code, out, _ = _run(
            _request(),
            mocker,
            mock_yta,
            fetched=MockFetchedTranscript("ru", segments=segments),
        )
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result"
        written = tmp_path / "output/result.md"
        content = written.read_text(encoding="utf-8")
        assert terminal["payload"]["markdownByteCount"] == len(content.encode("utf-8"))

    def test_oversized_single_segment_fails(self, mocker, mock_yta, tmp_path):
        # 3000 characters but 6000 UTF-8 bytes: the byte bound trips first.
        segments = [{"text": "я" * 3000, "start": 0.0, "duration": 1.0}]
        code, out, _ = _run(
            _request(), mocker, mock_yta, fetched=MockFetchedTranscript("ru", segments=segments)
        )
        assert _failure_cause(out) == "extraction-failure"
        assert not (tmp_path / "output/result.md").exists()

    def test_segment_count_cap(self, mocker, mock_yta, monkeypatch):
        monkeypatch.setattr(_yt, "_MAX_SEGMENT_COUNT", 5)
        segments = [{"text": f"seg {i}", "start": float(i), "duration": 1.0} for i in range(6)]
        code, out, _ = _run(
            _request(), mocker, mock_yta, fetched=MockFetchedTranscript("en", segments=segments)
        )
        assert _failure_cause(out) == "extraction-failure"

    @pytest.mark.parametrize(
        "segments",
        [
            ["not a dict"],
            [{"start": 0.0, "duration": 1.0}],
            [{"text": 42, "start": 0.0}],
            [{"text": "ok", "start": "zero", "duration": 1.0}],
            [{"text": "ok", "start": 0.0, "duration": "one"}],
            [{"text": "ok", "start": True}],
        ],
    )
    def test_malformed_segment_collections_fail(self, mocker, mock_yta, tmp_path, segments):
        code, out, _ = _run(
            _request(), mocker, mock_yta, fetched=MockFetchedTranscript("en", segments=segments)
        )
        assert _failure_cause(out) == "extraction-failure"
        assert not (tmp_path / "output/result.md").exists()


# ── Deadline seams ─────────────────────────────────────────────────────


class TestDeadline:
    def test_expired_deadline_performs_zero_api_calls(self, mocker, mock_yta):
        import_api = mocker.patch.object(_yt, "_import_api")
        out = io.StringIO()
        err = io.StringIO()
        request = _request(deadlineMillisecondsSince1970=1)
        code = _yt.run_extractor_protocol(json.dumps(request), out_stream=out, log_stream=err)
        assert code == 0
        assert _failure_cause(out.getvalue()) == "timeout"
        import_api.assert_not_called()

    def test_deadline_expiring_before_fetch_performs_zero_api_calls(
        self, mocker, mock_yta, monkeypatch
    ):
        calls = {"n": 0}

        def fake_deadline_passed(deadline_ms: int) -> bool:
            calls["n"] += 1
            return calls["n"] > 1  # pass validation, trip at the fetch seam

        monkeypatch.setattr(_yt, "_deadline_passed", fake_deadline_passed)
        code, out, _ = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))
        assert _failure_cause(out) == "timeout"
        assert mock_yta.YouTubeTranscriptApi.return_value.fetch.call_count == 0


# ── Redaction ──────────────────────────────────────────────────────────


class TestRedaction:
    def test_source_url_never_reaches_frames_or_stderr(self, mocker, mock_yta):
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = TranscriptsDisabled("t")
        secret_url = "https://www.youtube.com/watch?v=SECRETVIDX1&t=42"
        code, out, err = _run(_request(remoteURL=secret_url), mocker, mock_yta)
        assert code == 0
        combined = out + err
        assert "SECRETVIDX1" not in combined
        assert "youtube.com" not in combined

    def test_non_youtube_url_is_never_echoed(self, mocker, mock_yta):
        code, out, err = _run(
            _request(remoteURL="https://secret-host.example/watch?v=aaaaaaaaaaa"),
            mocker,
            mock_yta,
        )
        combined = out + err
        assert "secret-host" not in combined
        assert "aaaaaaaaaaa" not in combined

    def test_output_path_never_reaches_frames_or_stderr(self, mocker, mock_yta):
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = TranscriptsDisabled("t")
        code, out, err = _run(_request(outputPath="a/very/secret/path.md"), mocker, mock_yta)
        combined = out + err
        assert "a/very/secret/path.md" not in combined

    def test_video_id_appears_only_in_markdown_content(self, mocker, mock_yta, tmp_path):
        code, out, err = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))
        # The result frame and stderr carry no video ID; the written
        # transcript (the content product) may title it.
        assert _VIDEO_ID not in err
        terminal = _terminal(_frames(out))
        assert _VIDEO_ID not in json.dumps(terminal)
        content = (tmp_path / "output/result.md").read_text(encoding="utf-8")
        assert _VIDEO_ID in content


# ── Publication discipline ─────────────────────────────────────────────


class TestPublication:
    def test_failed_replace_leaves_no_partial_file(self, mocker, mock_yta, monkeypatch, tmp_path):
        def broken_replace(source: Any, destination: Any) -> None:
            raise OSError("disk on fire")

        monkeypatch.setattr(_yt.os, "replace", broken_replace)
        code, out, _ = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))
        assert code == 0
        assert _failure_cause(out) == "extraction-failure"
        assert not (tmp_path / "output/result.md").exists()
        assert not (tmp_path / "output/result.md.partial").exists()

    def test_exactly_one_terminal_frame_on_every_path(self, mocker, mock_yta):
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("t")
        code, out, _ = _run(_request(), mocker, mock_yta)
        frames = _frames(out)
        assert sum(1 for f in frames if f["kind"] in ("result", "failure")) == 1
        assert frames[-1]["kind"] == "failure"


# ── Unexpected package failures still emit one terminal frame ─────────


class TestUnexpectedPackageFailures:
    def test_import_failure_emits_setup_frame_without_leaking_paths(
        self, mocker, mock_yta, tmp_path
    ):
        import_api = mocker.patch.object(
            _yt, "_import_api", side_effect=ImportError("no module named x (/secret/path)")
        )
        out = io.StringIO()
        err = io.StringIO()
        code = _yt.run_extractor_protocol(json.dumps(_request()), out_stream=out, log_stream=err)
        assert code == 0
        assert _failure_cause(out.getvalue()) == "setup"
        combined = out.getvalue() + err.getvalue()
        assert "/secret/path" not in combined
        assert "no module named x" not in combined
        import_api.assert_called_once()
        assert not (tmp_path / "output/result.md").exists()

    def test_unexpected_internal_error_emits_redacted_failure_frame(
        self, mocker, mock_yta, monkeypatch, tmp_path
    ):
        def broken_consume(raw_segments, deadline_ms):
            raise RuntimeError("SECRET-INTERNAL-DETAIL")

        monkeypatch.setattr(_yt, "_consume_segments", broken_consume)
        code, out, err = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))
        assert code == 0
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "failure"
        assert terminal["payload"]["message"] == "caption retrieval failed"
        combined = out + err
        assert "SECRET-INTERNAL-DETAIL" not in combined
        assert not (tmp_path / "output/result.md").exists()

    def test_published_output_is_never_reported_as_failure(
        self, mocker, mock_yta, monkeypatch, tmp_path
    ):
        # A deadline expiring after publication is irrelevant: publication is
        # the commit point and the result frame follows unconditionally.
        original = _yt._publish_markdown
        state = {"published": False}

        def spy(output_path: str, markdown: str) -> int:
            result = original(output_path, markdown)
            state["published"] = True
            return result

        monkeypatch.setattr(_yt, "_publish_markdown", spy)
        monkeypatch.setattr(_yt, "_deadline_passed", lambda deadline_ms: state["published"])
        code, out, _ = _run(_request(), mocker, mock_yta, fetched=MockFetchedTranscript("en"))
        assert state["published"] is True
        assert _terminal(_frames(out))["kind"] == "result"
        assert (tmp_path / "output/result.md").exists()


# ── Generated-manifest parity ──────────────────────────────────────────


class TestManifestParity:
    """The package-owned bounds must equal or tighten the manifest limits.

    This test fails when either side drifts: the generated manifest in
    ExtractorPackages/YouTubeTranscript and the constants in the script are
    one contract, reviewed together.
    """

    MANIFEST_PATH = (
        Path(__file__).resolve().parents[3]
        / "ExtractorPackages"
        / "YouTubeTranscript"
        / "manifest.json"
    )

    def test_manifest_matches_package_bounds(self) -> None:
        assert self.MANIFEST_PATH.exists(), (
            f"generated YouTube package manifest missing at {self.MANIFEST_PATH}"
        )
        manifest = json.loads(self.MANIFEST_PATH.read_text(encoding="utf-8"))

        assert manifest["packageID"] == "org.selfdrivingwiki.youtube-transcript"
        assert manifest["version"] == "1.0.0"
        assert manifest["protocolRevision"] == _yt.PROTOCOL_REVISION == 3
        assert manifest["capabilities"] == ["network", "shared-runtime-cache"]

        registration = manifest["registrations"][0]
        assert registration["id"] == "captions"
        assert registration["kinds"] == ["youtube-transcript"]
        assert registration["mimeTypes"] == ["video/youtube"]
        assert manifest["launch"] == {
            "mode": "runtime",
            "command": "uv",
            "arguments": ["run", "--script"],
        }

        limits = manifest["limits"]
        assert limits["maximumInputByteCount"] == _yt._MAX_REQUEST_BYTES
        assert limits["maximumMarkdownOutputByteCount"] == _yt._MAX_OUTPUT_BYTES
        assert limits["maximumProgressEventCount"] == _yt._MAX_PROGRESS_FRAMES
        # Package-owned bounds tighten, never loosen, the manifest policy.
        assert 0 < _yt._OUTPUT_RESERVE_BYTES < _yt._MAX_OUTPUT_BYTES
        budget = _yt._MAX_OUTPUT_BYTES - _yt._OUTPUT_RESERVE_BYTES
        assert budget >= _yt._MAX_SEGMENT_TEXT_BYTES
        assert _yt._MAX_SEGMENT_COUNT >= 1
