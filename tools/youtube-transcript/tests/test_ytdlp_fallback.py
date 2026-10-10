"""In-process tests for the reviewed package's yt-dlp caption fallback.

The real pinned yt-dlp library is exercised separately in
`_ytdlp_offline_contract.py` under `uv run --script` (the dev test
environment deliberately does not install yt-dlp). Here the fallback runs
inside `run_extractor_protocol` with fakes at exactly two seams:

- `_import_ytdlp` — the library module namespace (a YoutubeDL stand-in).
- `_fetch_caption_bytes`'s `https_handler` — the low-level connection stub.

The URL validation, manual-redirect, content-encoding, byte-bound, and VTT
parsing layers always run for real. Failure messages are fixed strings:
these tests double as the fallback redaction contract.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import time
from email.message import Message
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest
from _ytdlp_offline_contract import (
    _TIMEDTEXT_URL,
    _VTT_BYTES,
    _ConnectionStub,
    _FakeResponse,
)
from conftest import (
    InvalidVideoId,
    IpBlocked,
    MockFetchedTranscript,
    NoTranscriptFound,
    RequestBlocked,
    TooManyRequests,
    TranscriptsDisabled,
    VideoUnavailable,
    YouTubeRequestFailed,
)

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "youtube-transcript"
assert _SCRIPT_PATH.exists(), f"youtube-transcript script not found at {_SCRIPT_PATH}"

_yt = SourceFileLoader("youtube_transcript", str(_SCRIPT_PATH)).load_module()
sys.modules["youtube_transcript"] = _yt

_REQUEST_ID = "11111111-2222-3333-4444-555555555555"
_VIDEO_ID = "dQw4w9WgXcQ"
_BUN_PATH = "/opt/host-resolved/bun"


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


def _write_bun_config(tmp_path: Path, document: dict | None) -> dict[str, Any]:
    """Stage the host-owned operation configuration in the operation root."""
    if document is None:
        return {}
    config_dir = tmp_path / "config"
    config_dir.mkdir(exist_ok=True)
    (config_dir / "operation.json").write_text(json.dumps(document), encoding="utf-8")
    return {"operationConfigurationPath": "config/operation.json"}


def _bun_config(path: str = _BUN_PATH) -> dict[str, str]:
    return {"kind": "reviewed-youtube-bun-runtime", "executablePath": path}


class FakeYoutubeDL:
    """The YoutubeDL stand-in: records construction and the one call."""

    last_params: dict[str, Any] | None = None
    last_url: str | None = None
    last_download: bool | None = None

    extract_info_error: Exception | None = None
    info_result: Any = None
    construction_error: Exception | None = None

    def __init__(self, params: dict[str, Any]) -> None:
        if FakeYoutubeDL.construction_error is not None:
            raise FakeYoutubeDL.construction_error
        FakeYoutubeDL.last_params = params

    def extract_info(self, url: str, download: bool = True) -> Any:
        FakeYoutubeDL.last_url = url
        FakeYoutubeDL.last_download = download
        if FakeYoutubeDL.extract_info_error is not None:
            raise FakeYoutubeDL.extract_info_error
        return FakeYoutubeDL.info_result

    def close(self) -> None:
        return

    @classmethod
    def reset(cls) -> None:
        cls.last_params = None
        cls.last_url = None
        cls.last_download = None
        cls.extract_info_error = None
        cls.info_result = None
        cls.construction_error = None


@pytest.fixture
def fake_ytdlp(mocker: Any) -> type[FakeYoutubeDL]:
    FakeYoutubeDL.reset()
    module = MagicMock()
    module.YoutubeDL = FakeYoutubeDL
    mocker.patch.object(_yt, "_import_ytdlp", return_value=module)
    return FakeYoutubeDL


def _info_fixture() -> dict[str, Any]:
    return {
        "id": _VIDEO_ID,
        "subtitles": {
            "en": [
                {"ext": "srv3", "url": "https://www.youtube.com/api/timedtext?fmt=srv3"},
                {"ext": "vtt", "url": _TIMEDTEXT_URL},
            ],
            "fr": [{"ext": "vtt", "url": "https://www.youtube.com/api/timedtext?lang=fr"}],
        },
        "automatic_captions": {
            "en-orig": [{"ext": "vtt", "url": "https://www.youtube.com/api/timedtext?kind=asr"}],
        },
    }


def _run(
    request: dict[str, Any] | str, mocker: Any, mock_yta: Any, fetched: Any = None
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


def _stub_fetch(mocker: Any, outcomes: list[Any]) -> _ConnectionStub:
    """Route the fallback's byte fetch through the low-level connection stub.

    Only the socket layer is replaced: the production `_fetch_caption_bytes`
    runs unchanged with the stub injected as its https handler.
    """
    stub = _ConnectionStub(outcomes)
    original = _yt._fetch_caption_bytes

    def wrapped(url: str, deadline_ms: int, https_handler: Any = None) -> bytes:
        return original(url, deadline_ms, https_handler=stub)

    mocker.patch.object(_yt, "_fetch_caption_bytes", side_effect=wrapped)
    return stub


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


# ── AC.1: fallback success ──────────────────────────────────────────────


class TestYtdlpFallbackSuccess:
    @pytest.fixture(autouse=True)
    def _operation_root(self, tmp_path: Path, monkeypatch: Any) -> None:
        monkeypatch.chdir(tmp_path)

    def test_ytdlp_fallback_success(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        """Primary reports no track → the fallback fetches real VTT bytes
        and publishes Markdown with the route's provenance."""
        overrides = _write_bun_config(tmp_path, _bun_config())
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("t")
        fake_ytdlp.info_result = _info_fixture()
        stub = _stub_fetch(mocker, [_FakeResponse(200, _VTT_BYTES)])

        code, out, err = _run(_request(**overrides), mocker, mock_yta)

        assert code == 0
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result"

        # The metadata call: one bounded attempt, download disabled.
        assert fake_ytdlp.last_url == f"https://www.youtube.com/watch?v={_VIDEO_ID}"
        assert fake_ytdlp.last_download is False
        assert fake_ytdlp.last_params is not None
        assert fake_ytdlp.last_params["skip_download"] is True
        assert fake_ytdlp.last_params["retries"] == 0
        assert fake_ytdlp.last_params["js_runtimes"] == {"bun": {"path": _BUN_PATH}}
        # One descriptor fetch: actual subtitle BYTES, no media request.
        assert len(stub.requests) == 1

        written = tmp_path / "output/result.md"
        content = written.read_text(encoding="utf-8")
        assert content.startswith(f"# YouTube Transcript: {_VIDEO_ID}\n\n")
        assert "hello everyone welcome to the video" in content

        payload = terminal["payload"]
        assert payload["markdownByteCount"] == len(content.encode("utf-8"))
        metadata = payload["metadata"]
        # The result frame names the route that produced the bytes.
        assert metadata["toolName"] == "yt-dlp"
        assert metadata["toolVersion"] == "2026.08.19"
        assert metadata["language"] == "en"
        assert metadata["transcriptGenerated"] is False

    def test_fallback_uses_english_automatic_then_first_language(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        _write_bun_config(tmp_path, _bun_config())
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = TranscriptsDisabled("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = TranscriptsDisabled("t")

        info = _info_fixture()
        info["subtitles"] = {}
        fake_ytdlp.info_result = info
        _stub_fetch(mocker, [_FakeResponse(200, _VTT_BYTES)])
        overrides = _write_bun_config(tmp_path, _bun_config())

        code, out, _ = _run(_request(**overrides), mocker, mock_yta)
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result", out
        metadata = terminal["payload"]["metadata"]
        assert metadata["language"] == "en-orig"
        assert metadata["transcriptGenerated"] is True

    def test_fallback_picks_first_language_when_no_english(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        _write_bun_config(tmp_path, _bun_config())
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("t")
        fake_ytdlp.info_result = {"subtitles": {"de": [{"ext": "vtt", "url": _TIMEDTEXT_URL}]}}
        _stub_fetch(mocker, [_FakeResponse(200, _VTT_BYTES)])
        overrides = _write_bun_config(tmp_path, _bun_config())

        code, out, _ = _run(_request(**overrides), mocker, mock_yta)
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result"
        assert terminal["payload"]["metadata"]["language"] == "de"

    def test_missing_bun_still_publishes_on_primary_success(self, mocker, mock_yta, fake_ytdlp):
        """A missing grant never blocks the primary route."""
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = MockFetchedTranscript("en")

        code, out, _ = _run(_request(), mocker, mock_yta)

        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result"
        assert terminal["payload"]["metadata"]["toolName"] == "youtube-transcript"
        # yt-dlp was never imported and never called.
        assert fake_ytdlp.last_url is None

    def test_missing_bun_yields_fixed_setup_frame_on_eligible_failure(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("t")

        code, out, _ = _run(_request(), mocker, mock_yta)

        assert code == 0
        assert _failure_cause(out) == "setup"
        terminal = _terminal(_frames(out))
        assert terminal["payload"]["message"] == "the caption fallback runtime is unavailable"
        # No import happened: the fail-fast precedes the library.
        assert fake_ytdlp.last_url is None
        assert not (tmp_path / "output/result.md").exists()


# ── AC.3: eligibility ───────────────────────────────────────────────────


class TestYtdlpFallbackEligibility:
    @pytest.fixture(autouse=True)
    def _operation_root(self, tmp_path: Path, monkeypatch: Any) -> None:
        monkeypatch.chdir(tmp_path)

    @pytest.fixture
    def fallback_spy(self, mocker: Any) -> Any:
        from youtube_transcript import ProtocolFailure  # noqa: PLC0415

        return mocker.patch.object(
            _yt,
            "_fetch_captions_via_ytdlp",
            side_effect=ProtocolFailure(
                "extraction-failure",
                "the caption fallback could not retrieve captions",
            ),
        )

    def test_ytdlp_fallback_eligibility(
        self, mocker, mock_yta, fallback_spy, monkeypatch, tmp_path
    ):
        """Exactly the eligible primary failures reach the single fallback
        attempt; every other terminal state never imports it."""
        cases = [
            # (primary setup, expected fallback calls, expected terminal
            #  kind, expected terminal cause)
            ("success", 0, "result", None),
            ("no-track", 1, "failure", "extraction-failure"),
            ("disabled", 1, "failure", "extraction-failure"),
            ("unavailable", 0, "failure", "unsupported-input"),
            ("blocked-request", 0, "failure", "extraction-failure"),
            ("ip-blocked", 0, "failure", "extraction-failure"),
            ("too-many-requests", 0, "failure", "extraction-failure"),
            ("invalid-id", 0, "failure", "invalid-request"),
            ("generic-library-failure", 1, "failure", "extraction-failure"),
        ]

        def primary(scenario: str) -> Any:
            api = mock_yta.YouTubeTranscriptApi.return_value
            api.fetch.side_effect = None
            api.list.side_effect = None
            if scenario == "success":
                api.fetch.return_value = MockFetchedTranscript("en")
            elif scenario == "no-track":
                api.fetch.side_effect = NoTranscriptFound("t")
                api.list.side_effect = NoTranscriptFound("t")
            elif scenario == "disabled":
                api.fetch.side_effect = TranscriptsDisabled("t")
                api.list.side_effect = TranscriptsDisabled("t")
            elif scenario == "unavailable":
                api.fetch.side_effect = VideoUnavailable("t")
                api.list.side_effect = VideoUnavailable("t")
            elif scenario == "blocked-request":
                api.fetch.side_effect = RequestBlocked("t")
            elif scenario == "ip-blocked":
                api.fetch.side_effect = IpBlocked("t")
            elif scenario == "too-many-requests":
                api.fetch.side_effect = TooManyRequests("t")
            elif scenario == "invalid-id":
                api.fetch.side_effect = InvalidVideoId("t")
            elif scenario == "generic-library-failure":
                api.fetch.side_effect = YouTubeRequestFailed("t")
            else:  # pragma: no cover - fixture error
                raise AssertionError(scenario)

        for scenario, expected_calls, expected_kind, expected_cause in cases:
            fallback_spy.reset_mock()
            primary(scenario)
            code, out, _ = _run(_request(), mocker, mock_yta)
            terminal = _terminal(_frames(out))
            assert terminal["kind"] == expected_kind, (scenario, out)
            if expected_cause is not None:
                assert terminal["payload"]["cause"] == expected_cause, scenario
            assert fallback_spy.call_count == expected_calls, scenario
            assert code == 0

    def test_expired_deadline_never_reaches_the_fallback(self, mocker, mock_yta, fallback_spy):
        code = _yt.run_extractor_protocol(
            json.dumps(_request(deadlineMillisecondsSince1970=1)),
            out_stream=io.StringIO(),
            log_stream=io.StringIO(),
        )
        assert code == 0
        assert fallback_spy.call_count == 0

    def test_conversion_failure_never_invokes_the_fallback(
        self, mocker, mock_yta, fallback_spy, tmp_path
    ):
        # The primary SUCCEEDS but the segments are malformed: the failure
        # happens after the fallback decision point, so yt-dlp is untouched.
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = [
            {"start": 0.0, "duration": 1.0}
        ]
        code, out, _ = _run(_request(), mocker, mock_yta)
        assert _failure_cause(out) == "extraction-failure"
        assert fallback_spy.call_count == 0
        assert not (tmp_path / "output/result.md").exists()

    def test_output_limit_failure_never_invokes_the_fallback(
        self, mocker, mock_yta, fallback_spy, monkeypatch, tmp_path
    ):
        monkeypatch.setattr(_yt, "_MAX_OUTPUT_BYTES", 600)
        monkeypatch.setattr(_yt, "_OUTPUT_RESERVE_BYTES", 100)
        # 10 segments x 100 Cyrillic characters = 2000 body bytes: the
        # output bound trips during consumption.
        segments = [{"text": "я" * 100, "start": float(i), "duration": 1.0} for i in range(10)]
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = MockFetchedTranscript(
            "en", segments=segments
        )
        code, out, _ = _run(_request(), mocker, mock_yta)
        assert _failure_cause(out) == "extraction-failure"
        assert fallback_spy.call_count == 0
        assert not (tmp_path / "output/result.md").exists()

    def test_publication_failure_never_invokes_the_fallback(
        self, mocker, mock_yta, fallback_spy, monkeypatch, tmp_path
    ):
        def broken_replace(source: Any, destination: Any) -> None:
            raise OSError("disk on fire")

        monkeypatch.setattr(_yt.os, "replace", broken_replace)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = MockFetchedTranscript("en")
        code, out, _ = _run(_request(), mocker, mock_yta)
        assert _failure_cause(out) == "extraction-failure"
        assert fallback_spy.call_count == 0
        assert not (tmp_path / "output/result.md.partial").exists()


# ── AC.4: the failure matrix ────────────────────────────────────────────


class TestYtdlpFailureMatrix:
    @pytest.fixture(autouse=True)
    def _operation_root(self, tmp_path: Path, monkeypatch: Any) -> None:
        monkeypatch.chdir(tmp_path)

    def _eligible_primary(self, mock_yta: Any) -> None:
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("t")

    def test_import_failure_reports_setup_without_paths(self, mocker, mock_yta, tmp_path):
        self._eligible_primary(mock_yta)
        mocker.patch.object(
            _yt,
            "_import_ytdlp",
            side_effect=ImportError("no module named yt_dlp (/secret/path)"),
        )
        code, out, err = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert code == 0
        assert _failure_cause(out) == "setup"
        combined = out + err
        assert "/secret/path" not in combined
        assert "no module named" not in combined

    def test_construction_failure_reports_setup(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        fake_ytdlp.construction_error = ValueError("bad js_runtimes shape")
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "setup"
        assert "js_runtimes" not in out

    def test_metadata_failure_is_redacted(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        fake_ytdlp.extract_info_error = RuntimeError("SECRET: HTTP Error 429 at https://secret")
        code, out, err = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert code == 0
        assert _failure_cause(out) == "extraction-failure"
        terminal = _terminal(_frames(out))
        assert terminal["payload"]["message"] == (
            "the caption fallback could not retrieve captions"
        )
        combined = out + err
        assert "SECRET" not in combined
        assert "secret" not in combined
        assert "429" not in combined

    def test_no_advertised_track_reports_unsupported_input(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = {"id": _VIDEO_ID}
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "unsupported-input"
        assert not (tmp_path / "output/result.md").exists()

    def test_listed_track_without_webvtt_fails_bounded(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        """A track listing is not access: no VTT descriptor → bounded
        failure, zero network fetches."""
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = {
            "subtitles": {"en": [{"ext": "srv3", "url": "https://www.youtube.com/api/timedtext"}]}
        }
        stub = _stub_fetch(mocker, [])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert len(stub.requests) == 0
        assert not (tmp_path / "output/result.md").exists()

    def test_429_on_descriptor_ends_the_attempt_without_retry(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        """The known-blocked status gets exactly one attempt — the package
        never repeats a request against a blocked address."""
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        stub = _stub_fetch(mocker, [_FakeResponse(429)])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert len(stub.requests) == 1
        assert not (tmp_path / "output/result.md").exists()

    def test_disallowed_redirect_host_is_rejected_before_connecting(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        # A loopback redirect: validated BEFORE the next connection, so the
        # stub sees exactly the first request.
        stub = _stub_fetch(mocker, [(302, "https://127.0.0.1/api/timedtext")])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert len(stub.requests) == 1
        assert not (tmp_path / "output/result.md").exists()

    def test_excessive_redirects_fail_bounded(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        # Three hops: the manual ceiling is two.
        stub = _stub_fetch(
            mocker,
            [
                (302, _TIMEDTEXT_URL + "&hop=1"),
                (302, _TIMEDTEXT_URL + "&hop=2"),
                (302, _TIMEDTEXT_URL + "&hop=3"),
            ],
        )
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        terminal = _terminal(_frames(out))
        assert terminal["payload"]["message"] == "the caption location redirected too many times"
        assert len(stub.requests) == 3  # two redirects + the third refused hop

    def test_malformed_vtt_fails_bounded(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        _stub_fetch(mocker, [_FakeResponse(200, b"\xff\xfe not webvtt at all")])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert not (tmp_path / "output/result.md").exists()

    def test_empty_transcript_through_fallback_fails_bounded(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        _stub_fetch(mocker, [_FakeResponse(200, b"WEBVTT\n\n")])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert not (tmp_path / "output/result.md").exists()

    def test_unknown_config_kind_means_no_runtime(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        """A configuration the package does not recognize is simply 'no
        fallback runtime': the fixed setup frame, nothing more."""
        self._eligible_primary(mock_yta)
        overrides = _write_bun_config(
            tmp_path, {"kind": "something-else", "executablePath": "/bin/evil"}
        )
        code, out, _ = _run(_request(**overrides), mocker, mock_yta)
        assert _failure_cause(out) == "setup"
        assert fake_ytdlp.last_url is None
        assert "/bin/evil" not in out

    def test_relative_executable_path_rejected(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        overrides = _write_bun_config(tmp_path, _bun_config("relative/bun"))
        code, out, _ = _run(_request(**overrides), mocker, mock_yta)
        assert _failure_cause(out) == "setup"


# ── AC.4: redaction and bounds ──────────────────────────────────────────


class TestYtdlpRedactionAndBounds:
    @pytest.fixture(autouse=True)
    def _operation_root(self, tmp_path: Path, monkeypatch: Any) -> None:
        monkeypatch.chdir(tmp_path)

    def _eligible_primary(self, mock_yta: Any) -> None:
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("t")

    def test_logger_output_is_discarded(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        """Upstream messages through every logger method never reach a
        frame or stderr."""
        self._eligible_primary(mock_yta)

        logger_seen: list[str] = []

        class LoggingYoutubeDL(FakeYoutubeDL):
            def __init__(self, params: dict[str, Any]) -> None:
                super().__init__(params)
                logger = params.get("logger")
                assert logger is not None
                logger.debug("SECRET-DEBUG leak")
                logger.warning("SECRET-WARNING leak")
                logger.error("SECRET-ERROR leak")
                logger_seen.extend(["debug", "warning", "error"])

        module = MagicMock()
        module.YoutubeDL = LoggingYoutubeDL
        mocker.patch.object(_yt, "_import_ytdlp", return_value=module)
        fake_ytdlp.info_result = _info_fixture()
        _stub_fetch(mocker, [_FakeResponse(200, _VTT_BYTES)])

        code, out, err = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert logger_seen == ["debug", "warning", "error"]
        combined = out + err
        for secret in ("SECRET-DEBUG", "SECRET-WARNING", "SECRET-ERROR"):
            assert secret not in combined
        assert _terminal(_frames(out))["kind"] == "result"

    def test_descriptor_query_parameters_never_reach_frames(
        self, mocker, mock_yta, fake_ytdlp, tmp_path
    ):
        self._eligible_primary(mock_yta)
        secret_url = "https://www.youtube.com/api/timedtext?signature=TOPSECRET&v=" + _VIDEO_ID
        fake_ytdlp.info_result = {"subtitles": {"en": [{"ext": "vtt", "url": secret_url}]}}
        _stub_fetch(mocker, [_FakeResponse(200, _VTT_BYTES)])
        code, out, err = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        combined = out + err
        assert "TOPSECRET" not in combined
        assert "timedtext" not in combined
        assert _terminal(_frames(out))["kind"] == "result"

    def test_oversized_payload_fails_at_limit_plus_one(
        self, mocker, mock_yta, fake_ytdlp, monkeypatch, tmp_path
    ):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        cap = 64
        monkeypatch.setattr(_yt, "_MAX_CAPTION_PAYLOAD_BYTES", cap)
        stub = _stub_fetch(mocker, [_FakeResponse(200, b"x" * (cap + 8))])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert len(stub.requests) == 1

    def test_compressed_response_is_rejected(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        headers = Message()
        headers["Content-Encoding"] = "gzip"
        _stub_fetch(mocker, [_FakeResponse(200, _VTT_BYTES, {"Content-Encoding": "gzip"})])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert "gzip" not in out

    def test_non_200_status_fails_bounded(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        _stub_fetch(mocker, [_FakeResponse(403)])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        assert "403" not in out


# ── AC.4: redirect guards + the real-library plugin guard ───────────────


class TestYtdlpPluginAndRedirectGuards:
    @pytest.fixture(autouse=True)
    def _operation_root(self, tmp_path: Path, monkeypatch: Any) -> None:
        monkeypatch.chdir(tmp_path)

    def _eligible_primary(self, mock_yta: Any) -> None:
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("t")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("t")

    def test_redirect_chain_revalidates_each_location(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        """Every hop passes through the same allowlist: one allowed hop
        succeeds, and each request still carries identity encoding."""
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        hop = "https://www.youtube.com/api/timedtext?hop=1&fmt=vtt"
        stub = _stub_fetch(mocker, [(302, hop), _FakeResponse(200, _VTT_BYTES)])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        terminal = _terminal(_frames(out))
        assert terminal["kind"] == "result"
        assert len(stub.requests) == 2
        assert stub.requests[1].full_url == hop
        assert stub.requests[1].get_header("Accept-encoding") == "identity"

    def test_unsafe_redirect_schemes_are_rejected(self, mocker, mock_yta, fake_ytdlp, tmp_path):
        self._eligible_primary(mock_yta)
        fake_ytdlp.info_result = _info_fixture()
        stub = _stub_fetch(mocker, [(302, "http://www.youtube.com/api/timedtext")])
        code, out, _ = _run(
            _request(**_write_bun_config(tmp_path, _bun_config())), mocker, mock_yta
        )
        assert _failure_cause(out) == "extraction-failure"
        # The plain-http location was refused before any connection to it.
        assert len(stub.requests) == 1

    def test_real_ytdlp_plugin_guard(self) -> None:
        """The pinned release's `load_plugins()` honors YTDLP_NO_PLUGINS.

        Runs the offline contract script's plugin arm inside the SAME
        pinned PEP 723 environment as the package entry point: a fake
        plugin that yt-dlp WOULD discover (proven by the unguarded control
        run) must not import while the package's guard is set.
        """
        pytest.importorskip("subprocess")
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            ["uv", "run", "--script", str(_CONTRACT_PATH), "plugin-guard"],
            capture_output=True,
            text=True,
            timeout=600,
            cwd=_SCRIPT_PATH.parent,
            check=False,
        )
        assert result.returncode == 0, f"plugin guard arm failed:\n{result.stdout}\n{result.stderr}"
        assert "PLUGIN GUARD OK" in result.stdout
        assert "PLUGIN CONTROL OK" in result.stdout


# ── AC.1/AC.5: the real-library offline contract ────────────────────────


_CONTRACT_PATH = Path(__file__).resolve().parent / "_ytdlp_offline_contract.py"


class TestRealYtdlpOfflineContract:
    def test_pep723_blocks_match_the_entry_point(self) -> None:
        """The contract script imports the SAME pinned dependencies as the
        generated entry point — one drift gate, not a second pin."""

        def block(path: Path) -> str:
            text = path.read_text(encoding="utf-8")
            return text.split("# /// script", 1)[1].split("# ///", 1)[0]

        assert block(_CONTRACT_PATH) == block(_SCRIPT_PATH)

    def test_real_ytdlp_offline_contract(self) -> None:
        """Real YoutubeDL option parsing + descriptor selection + a WebVTT
        byte fetch through the production opener with a connection stub.

        No network access is required or attempted: the stub replaces only
        the socket layer, and the request-count assertions fail if any
        real connection is attempted.
        """
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            ["uv", "run", "--script", str(_CONTRACT_PATH), "contract"],
            capture_output=True,
            text=True,
            timeout=600,
            cwd=_SCRIPT_PATH.parent,
            check=False,
        )
        assert result.returncode == 0, f"offline contract failed:\n{result.stdout}\n{result.stderr}"
        assert "CONTRACT OK" in result.stdout
