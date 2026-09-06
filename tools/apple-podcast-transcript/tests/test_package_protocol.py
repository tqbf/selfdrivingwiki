"""Unit tests for the apple-podcast-transcript package source.

The reviewed package serves ONE revision-3 `remote-url` request per process.
These tests pin the request parsing, transport rules, the workflow split
(RSS fallback ONLY without staged support; never after an admitted Apple
failure), the TTML parser semantics ported from the former Swift parser, the
helper-path validation, the token cache lifecycle, and bounded diagnostics.

Run from the tools/apple-podcast-transcript directory:
    uv run pytest tests/ -v
"""

from __future__ import annotations

import io
import json
import os
import sys
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "apple-podcast-transcript"
assert _SCRIPT_PATH.exists(), f"script not found at {_SCRIPT_PATH}"

sys.dont_write_bytecode = True
_loader = SourceFileLoader("apple_podcast_transcript", str(_SCRIPT_PATH))
_apple = _loader.load_module()
sys.modules["apple_podcast_transcript"] = _apple

_REQUEST_ID = "8f25e76a-be09-467f-b71e-68c02da4d16b"
_FAKE_JWT = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0In0.aGVsbG9fbGl2ZV93b3JsZA"


def _request(**overrides) -> dict:
    request = {
        "requestID": _REQUEST_ID,
        "protocolRevision": 3,
        "kind": "apple-podcast-transcript",
        "mimeType": "audio/apple-podcast",
        "originalFilename": "episode",
        "inputTransport": "remote-url",
        "remoteURL": "https://podcasts.apple.com/us/podcast/show/id123?i=456",
        "outputPath": "output/result.md",
        "deadlineMillisecondsSince1970": 9999999999999,
    }
    request.update(overrides)
    return request


@pytest.fixture(autouse=True)
def _relative_output_path(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv(_apple._TOKEN_CACHE_ENV, raising=False)
    return None


def _serve(request, workflow=None):
    """Run one protocol request. `workflow` patches run_workflow: a str is
    the returned markdown, a BaseException is raised, None runs unpatched."""
    out = io.StringIO()
    request_text = request if isinstance(request, str) else json.dumps(request)
    if workflow is None:
        code = _apple.run_extractor_protocol(request_text, out_stream=out, log_stream=io.StringIO())
    elif isinstance(workflow, BaseException):
        with patch.object(_apple, "run_workflow", side_effect=workflow):
            code = _apple.run_extractor_protocol(
                request_text, out_stream=out, log_stream=io.StringIO()
            )
    else:
        with patch.object(_apple, "run_workflow", return_value=workflow):
            code = _apple.run_extractor_protocol(
                request_text, out_stream=out, log_stream=io.StringIO()
            )
    frames = [json.loads(line) for line in out.getvalue().splitlines() if line.strip()]
    return code, frames


def _terminal(frames):
    terminal = [f for f in frames if f["kind"] in ("result", "failure")]
    assert len(terminal) == 1, f"expected exactly one terminal frame, got {frames}"
    return terminal[0]


# ── Request parsing and transport rules ──────────────────────────────────────


class TestRequestParsing:
    def test_valid_request_emits_bounded_progress_and_one_result(self, tmp_path):
        code, frames = _serve(_request(outputPath=str(tmp_path / "out/result.md")), "text")
        assert code == 0
        kinds = [f["kind"] for f in frames]
        assert kinds == ["progress", "progress", "progress", "result"]
        assert _terminal(frames)["payload"]["metadata"] == {"toolName": "apple-podcast-transcript"}

    def test_wrong_revision_is_invalid_request(self):
        assert (
            _terminal(_serve(_request(protocolRevision=2))[1])["payload"]["cause"]
            == "invalid-request"
        )

    def test_wrong_kind_is_unsupported_input(self):
        assert (
            _terminal(_serve(_request(kind="podcast-transcript"))[1])["payload"]["cause"]
            == "unsupported-input"
        )

    def test_operation_file_transport_is_rejected(self):
        request = _request(
            inputTransport="operation-file", remoteURL=None, inputPath="input/source"
        )
        assert _terminal(_serve(request)[1])["payload"]["cause"] == "invalid-request"

    def test_non_apple_url_is_rejected_before_network(self):
        request = _request(remoteURL="https://example.com/feed.rss")
        with patch.object(_apple.requests, "get", side_effect=AssertionError("network")):
            assert _terminal(_serve(request, None)[1])["payload"]["cause"] == "invalid-request"

    def test_passed_deadline_fails_with_timeout(self):
        request = _request(deadlineMillisecondsSince1970=int(time.time() * 1000) - 1_000)
        assert _terminal(_serve(request)[1])["payload"]["cause"] == "timeout"


# ── Workflow split: fallback only without support ────────────────────────────


class TestFallbackSemantics:
    def test_no_configuration_runs_rss_fallback(self):
        request = _request(remoteURL="https://podcasts.apple.com/us/podcast/s/id1?i=2")
        with (
            patch.object(_apple, "rss_transcript", return_value="rss text") as rss,
            patch.object(_apple, "read_helper_path", return_value=None),
        ):
            markdown = _apple.run_workflow(request["remoteURL"], None, os.getcwd())
        assert markdown == "rss text"
        rss.assert_called_once()

    def test_helper_failure_after_admission_never_falls_back(self):
        request = _request(remoteURL="https://podcasts.apple.com/us/podcast/s/id1?i=2")
        with (  # noqa: SIM117 - the raises-block stays separate for clarity
            patch.object(_apple, "read_helper_path", return_value="/staged/helper"),
            patch.object(
                _apple,
                "bearer_token",
                side_effect=_apple.WorkflowError("extraction-failure", "helper failed"),
            ),
            patch.object(_apple, "rss_transcript", side_effect=AssertionError("rss must not run")),
        ):
            with pytest.raises(_apple.WorkflowError):  # noqa: SIM117
                _apple.run_workflow(request["remoteURL"], None, os.getcwd())

    def test_unreadable_configuration_after_admission_fails_closed(self, tmp_path, monkeypatch):
        # The host NAMED a configuration file (support admitted); a missing
        # or unreadable file must FAIL, never downgrade to RSS.
        monkeypatch.setattr(_apple, "_request_configuration_path", "config/req/operation.json")
        with patch.object(  # noqa: SIM117 - raises separate
            _apple, "rss_transcript", side_effect=AssertionError("rss must not run")
        ):
            with pytest.raises(_apple.WorkflowError):
                _apple.read_helper_path(str(tmp_path))

    def test_invalid_configuration_json_after_admission_fails_closed(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config" / "req"
        config_dir.mkdir(parents=True)
        (config_dir / "operation.json").write_text("not json")
        monkeypatch.setattr(_apple, "_request_configuration_path", "config/req/operation.json")
        with patch.object(  # noqa: SIM117 - raises separate
            _apple, "rss_transcript", side_effect=AssertionError("rss must not run")
        ):
            with pytest.raises(_apple.WorkflowError):
                _apple.read_helper_path(str(tmp_path))

    def test_amp_failure_after_admission_never_falls_back(self):
        request = _request(remoteURL="https://podcasts.apple.com/us/podcast/s/id1?i=2")
        with (  # noqa: SIM117 - readability
            patch.object(_apple, "read_helper_path", return_value="/staged/helper"),
            patch.object(_apple, "bearer_token", return_value=_FAKE_JWT),
            patch.object(
                _apple,
                "ttml_url_from_response",
                side_effect=_apple.WorkflowError("extraction-failure", "amp down"),
            ),
            patch.object(_apple.requests.Session, "send", return_value=_FakeResponse(200, b"{}")),
            patch.object(_apple, "rss_transcript", side_effect=AssertionError("rss must not run")),
        ):
            with pytest.raises(_apple.WorkflowError):  # noqa: SIM117
                _apple.run_workflow(request["remoteURL"], None, os.getcwd())


class _FakeResponse:
    def __init__(self, status, body):
        self.status_code = status
        self.content = body


# ── AMP 40012 forced refresh ─────────────────────────────────────────────────


class TestAMPRefresh:
    def test_40012_refreshes_token_once_and_retries(self):
        refresh_flags: list[bool] = []

        def fake_token(helper_path, budget, force_refresh):
            refresh_flags.append(force_refresh)
            return _FAKE_JWT

        def fake_send(request, **kwargs):
            if not refresh_flags or not refresh_flags[-1]:
                # First attempt: the cached token lacks transcript permission.
                return _FakeResponse(400, b'{"error": "40012"}')
            return _FakeResponse(
                200,
                b'{"data":[{"attributes":{"ttmlAssetUrls":{"ttml":"https://ttml/x"}}}]}',
            )

        with (
            patch.object(_apple, "read_helper_path", return_value="/staged/helper"),
            patch.object(_apple, "bearer_token", side_effect=fake_token),
            patch.object(
                _apple, "download_ttml", return_value=b"<tt><body><div><p>Hi</p></div></body></tt>"
            ),
            patch.object(_apple.requests.Session, "send", side_effect=fake_send),
        ):
            markdown = _apple.run_workflow(
                "https://podcasts.apple.com/us/podcast/s/id1?i=456", None, os.getcwd()
            )
        assert markdown == "Hi"
        assert refresh_flags == [False, True]

    def test_non40012_400_is_a_failure_without_refresh(self):
        refresh_flags: list[bool] = []

        def fake_token(helper_path, budget, force_refresh):
            refresh_flags.append(force_refresh)
            return _FAKE_JWT

        with (  # noqa: SIM117 - readability
            patch.object(_apple, "read_helper_path", return_value="/staged/helper"),
            patch.object(_apple, "bearer_token", side_effect=fake_token),
            patch.object(
                _apple.requests.Session,
                "send",
                return_value=_FakeResponse(400, b'{"error": "other"}'),
            ),
        ):  # noqa: SIM117 - the raises-block stays separate for clarity
            with pytest.raises(_apple.WorkflowError):
                _apple.run_workflow(
                    "https://podcasts.apple.com/us/podcast/s/id1?i=456", None, os.getcwd()
                )
        assert refresh_flags == [False]


# ── TTML parsing (ported from TTMLTranscript.swift) ──────────────────────────


class TestTTMLParsing:
    def test_word_units_join_with_spaces(self):
        ttml = (
            '<tt xmlns:podcasts="x" xmlns:ttm="y"><body><div>'
            '<p begin="0.220" end="2.0" ttm:agent="SPEAKER_1">'
            '<span podcasts:unit="word">Welcome</span>'
            '<span podcasts:unit="word">to</span>'
            '<span podcasts:unit="word">War</span>'
            '<span podcasts:unit="word">Talk.</span>'
            "</p></div></body></tt>"
        )
        assert _apple.parse_ttml(ttml.encode()) == "SPEAKER_1: Welcome to War Talk."

    def test_namespace_prefixes_are_tolerated(self):
        ttml = (
            '<tt xmlns:a="u" xmlns:b="v"><body><div>'
            '<p a:begin="1:09.5" b:agent="S1"><span b:unit="word">Hi</span></p>'
            "</div></body></tt>"
        )
        assert _apple.parse_ttml(ttml.encode()) == "S1: Hi"

    def test_raw_paragraph_text_is_the_fallback(self):
        ttml = '<tt><body><div><p begin="0" end="1">Plain paragraph text</p></div></body></tt>'
        assert _apple.parse_ttml(ttml.encode()) == "Plain paragraph text"

    def test_clock_formats_parse(self):
        assert _apple.parse_clock("0.220") == pytest.approx(0.220)
        assert _apple.parse_clock("1:09") == pytest.approx(69.0)
        assert _apple.parse_clock("1:09:04.480") == pytest.approx(4144.480)
        assert _apple.parse_clock("bogus") == 0.0
        assert _apple.parse_clock(None) == 0.0

    def test_malformed_ttml_fails(self):
        with pytest.raises(_apple.WorkflowError):
            _apple.parse_ttml(b"<not-xml")

    def test_cue_free_ttml_fails(self):
        ttml = "<tt><body><div></div></body></tt>"
        with pytest.raises(_apple.WorkflowError):
            _apple.parse_ttml(ttml.encode())


# ── Helper path validation ───────────────────────────────────────────────────


class TestHelperPathValidation:
    def _config(self, tmp_path, monkeypatch, helper_path):
        config_dir = tmp_path / "config" / "req"
        config_dir.mkdir(parents=True)
        config = config_dir / "operation.json"
        config.write_text(
            json.dumps({"kind": "apple-podcast-transcript", "helperPath": helper_path})
        )
        monkeypatch.setattr(_apple, "_request_configuration_path", "config/req/operation.json")

    def test_relative_helper_resolves_and_requires_exec_regular(self, tmp_path, monkeypatch):
        helper = tmp_path / "support" / "req" / "podcast-token-helper"
        helper.parent.mkdir(parents=True)
        helper.write_bytes(b"#!/bin/sh\n")
        helper.chmod(0o500)
        self._config(tmp_path, monkeypatch, "support/req/podcast-token-helper")
        resolved = _apple.read_helper_path(str(tmp_path))
        assert resolved == str(helper)

    def test_absolute_path_is_rejected(self, tmp_path, monkeypatch):
        self._config(tmp_path, monkeypatch, "/usr/bin/true")
        with pytest.raises(_apple.WorkflowError):
            _apple.read_helper_path(str(tmp_path))

    def test_traversal_is_rejected(self, tmp_path, monkeypatch):
        self._config(tmp_path, monkeypatch, "../support/helper")
        with pytest.raises(_apple.WorkflowError):
            _apple.read_helper_path(str(tmp_path))

    def test_symlink_is_rejected(self, tmp_path, monkeypatch):
        target = tmp_path / "real-helper"
        target.write_bytes(b"#!/bin/sh\n")
        target.chmod(0o500)
        link = tmp_path / "support"
        link.mkdir()
        (link / "helper").symlink_to(target)
        self._config(tmp_path, monkeypatch, "support/helper")
        with pytest.raises(_apple.WorkflowError):
            _apple.read_helper_path(str(tmp_path))

    def test_non_executable_is_rejected(self, tmp_path, monkeypatch):
        helper = tmp_path / "support" / "req" / "helper"
        helper.parent.mkdir(parents=True)
        helper.write_bytes(b"#!/bin/sh\n")
        helper.chmod(0o600)
        self._config(tmp_path, monkeypatch, "support/req/helper")
        with pytest.raises(_apple.WorkflowError):
            _apple.read_helper_path(str(tmp_path))

    def test_unknown_configuration_kind_is_rejected(self, tmp_path, monkeypatch):
        config_dir = tmp_path / "config" / "req"
        config_dir.mkdir(parents=True)
        (config_dir / "operation.json").write_text(json.dumps({"kind": "other", "helperPath": "x"}))
        monkeypatch.setattr(_apple, "_request_configuration_path", "config/req/operation.json")
        with pytest.raises(_apple.WorkflowError):
            _apple.read_helper_path(str(tmp_path))

    def test_missing_configuration_means_no_support(self, tmp_path, monkeypatch):
        monkeypatch.setattr(_apple, "_request_configuration_path", None)
        assert _apple.read_helper_path(str(tmp_path)) is None


# ── Token cache lifecycle ────────────────────────────────────────────────────


class TestTokenCache:
    def _cache(self, tmp_path, monkeypatch):
        cache = tmp_path / "token-cache"
        cache.mkdir()
        cache.chmod(0o700)
        monkeypatch.setenv(_apple._TOKEN_CACHE_ENV, str(cache))
        return cache

    def test_token_round_trips(self, tmp_path, monkeypatch):
        cache = self._cache(tmp_path, monkeypatch)
        _apple.store_token(_FAKE_JWT)
        assert (cache / "token.json").stat().st_mode & 0o777 == 0o600
        assert _apple.load_cached_token() == _FAKE_JWT

    def test_expired_entry_is_ignored(self, tmp_path, monkeypatch):
        cache = self._cache(tmp_path, monkeypatch)  # noqa: F841 - dir must exist
        (cache / "token.json").write_text(
            json.dumps(
                {
                    "token": _FAKE_JWT,
                    "fetched": time.time() - _apple._TOKEN_CACHE_MAX_AGE_SECONDS - 1,
                }
            )
        )
        assert _apple.load_cached_token() is None

    def test_corrupt_entry_is_replaced(self, tmp_path, monkeypatch):
        cache = self._cache(tmp_path, monkeypatch)
        (cache / "token.json").write_text("not json {{{")
        assert _apple.load_cached_token() is None
        assert not (cache / "token.json").exists()

    def test_non_jwt_rejected(self, tmp_path, monkeypatch):
        self._cache(tmp_path, monkeypatch)
        _apple.store_token("definitely not a jwt")
        assert _apple.load_cached_token() is None

    def test_store_failure_never_raises(self, tmp_path, monkeypatch):
        monkeypatch.setenv(_apple._TOKEN_CACHE_ENV, str(tmp_path / "missing" / "deep"))
        _apple.store_token(_FAKE_JWT)  # creates parents; must not raise
        _apple.store_token(_FAKE_JWT)


# ── Helper supervision (real subprocesses, bounded) ──────────────────────────


class TestHelperSupervision:
    def test_healthy_helper_token_is_returned(self, tmp_path):
        helper = tmp_path / "helper"
        helper.write_text(f"#!/bin/sh\nprintf '{_FAKE_JWT}'\n")
        helper.chmod(0o500)
        token = _apple.run_helper(str(helper), 10.0)
        assert token == _FAKE_JWT

    def test_failing_helper_is_a_workflow_error(self, tmp_path):
        helper = tmp_path / "helper"
        helper.write_text("#!/bin/sh\nexit 3\n")
        helper.chmod(0o500)
        with pytest.raises(_apple.WorkflowError):
            _apple.run_helper(str(helper), 10.0)

    def test_hung_helper_times_out_and_leaves_no_helper(self, tmp_path):
        helper = tmp_path / "helper"
        helper.write_text("#!/bin/sh\nsleep 60\n")
        helper.chmod(0o500)
        start = time.monotonic()
        with pytest.raises(_apple.WorkflowError):
            _apple.run_helper(str(helper), 1.0)
        assert time.monotonic() - start < 15
        _assert_no_helper_processes(helper)

    def test_flooded_stdout_is_capped_and_fails(self, tmp_path):
        helper = tmp_path / "helper"
        helper.write_text("#!/bin/sh\nyes abuse | head -c 2000000\n")
        helper.chmod(0o500)
        with pytest.raises(_apple.WorkflowError):
            _apple.run_helper(str(helper), 15.0)
        _assert_no_helper_processes(helper)

    def test_non_jwt_output_is_rejected_without_echo(self, tmp_path):
        helper = tmp_path / "helper"
        helper.write_text("#!/bin/sh\nprintf 'internal error detail: secret-value'\n")
        helper.chmod(0o500)
        with pytest.raises(_apple.WorkflowError) as excinfo:
            _apple.run_helper(str(helper), 10.0)
        assert "secret-value" not in str(excinfo.value)
        assert "internal error" not in str(excinfo.value)
        _assert_no_helper_processes(helper)

    def test_term_ignoring_helper_group_is_killed(self, tmp_path):
        # The helper traps TERM; the supervisor must escalate to KILL so the
        # group actually dies.
        helper = tmp_path / "helper"
        helper.write_text("#!/bin/sh\ntrap '' TERM\nsleep 60\n")
        helper.chmod(0o500)
        start = time.monotonic()
        with pytest.raises(_apple.WorkflowError):
            _apple.run_helper(str(helper), 1.0)
        assert time.monotonic() - start < 15
        _assert_no_helper_processes(helper)

    def test_descendant_surviving_clean_exit_is_cleaned(self, tmp_path):
        # The helper exits 0 while a forked descendant stays in its process
        # group HOLDING the output pipe: the final drain exhausts the
        # deadline, the supervisor must treat that as failure, kill the
        # group, and publish nothing.
        helper = tmp_path / "helper"
        helper.write_text("#!/bin/sh\nsleep 30 &\nprintf 'no-token'\nexit 0\n")
        helper.chmod(0o500)
        start = time.monotonic()
        with pytest.raises(_apple.WorkflowError):
            _apple.run_helper(str(helper), 1.0)
        assert time.monotonic() - start < 20
        _assert_no_helper_processes(helper)

    def test_descendant_with_closed_pipes_is_still_cleaned(self, tmp_path):
        # The dangerous variant: the descendant CLOSES the inherited pipes,
        # so the drain reaches EOF and the token would publish while the
        # descendant lives. The group cleanup must still remove it.
        helper = tmp_path / "helper"
        helper.write_text(
            "#!/bin/sh\nsleep 30 >&- 2>&- &\nprintf 'eyJhbGciOiJIUzI1NiJ9.c3Vp.dG9rZW4'\nexit 0\n"
        )
        helper.chmod(0o500)
        token = _apple.run_helper(str(helper), 10.0)
        assert token == "eyJhbGciOiJIUzI1NiJ9.c3Vp.dG9rZW4"
        _assert_no_helper_processes(helper)


def _assert_no_helper_processes(helper_path: Path) -> None:
    """Every staged-helper invocation must be reaped: no live process may
    still carry the helper path in its command line. Polls briefly so a
    just-killed group has time to be reaped before the assertion fires."""
    deadline = time.monotonic() + 5.0
    result = ""
    while time.monotonic() < deadline:
        result = os.popen(f"ps -axo command | grep -F '{helper_path}' | grep -v grep").read()
        if result.strip() == "":
            return
        time.sleep(0.1)
    assert result.strip() == "", f"helper process leaked: {result}"


# ── Redaction ────────────────────────────────────────────────────────────────


class TestRedaction:
    def test_token_never_reaches_any_frame(self, tmp_path):
        destination = tmp_path / "out/result.md"
        request = _request(outputPath=str(destination))
        with (
            patch.object(_apple, "read_helper_path", return_value="/staged/helper"),
            patch.object(_apple, "bearer_token", return_value=_FAKE_JWT),
            patch.object(
                _apple.requests.Session,
                "send",
                return_value=_FakeResponse(
                    200, (b'{"data":[{"attributes":{"ttmlAssetUrls":{"ttml":"https://t/x"}}}]}')
                ),
            ),
            patch.object(
                _apple,
                "download_ttml",
                return_value=(b"<tt><body><div><p>Hi</p></div></body></tt>"),
            ),
        ):
            _apple.run_workflow(request["remoteURL"], None, os.getcwd())
        # Also drive the protocol surface with the same seams patched.
        out = io.StringIO()
        with (
            patch.object(_apple, "read_helper_path", return_value="/staged/helper"),
            patch.object(_apple, "bearer_token", return_value=_FAKE_JWT),
            patch.object(
                _apple.requests.Session,
                "send",
                return_value=_FakeResponse(
                    200, (b'{"data":[{"attributes":{"ttmlAssetUrls":{"ttml":"https://t/x"}}}]}')
                ),
            ),
            patch.object(
                _apple,
                "download_ttml",
                return_value=(b"<tt><body><div><p>Hi</p></div></body></tt>"),
            ),
        ):
            code = _apple.run_extractor_protocol(
                json.dumps(request), out_stream=out, log_stream=io.StringIO()
            )
        rendered = out.getvalue()
        assert _FAKE_JWT not in rendered
        assert "/staged/helper" not in rendered
        assert code == 0
