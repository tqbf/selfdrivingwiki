# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = [
#     "youtube-transcript-api>=1.0",
#     "yt-dlp==2026.08.19",
#     "yt-dlp-ejs==0.8.0",
# ]
# ///
"""Offline contract between the reviewed youtube-transcript package and its
pinned yt-dlp release.

This script runs INSIDE the package's pinned PEP 723 environment
(`uv run --script`, resolved from the entry point's exact pins) — never in
the dev test environment, which deliberately does not install yt-dlp. The
pytest suite invokes one arm at a time:

  plugin-guard   A fake plugin in a discoverable yt-dlp plugin directory
                 must NOT load while the package's `YTDLP_NO_PLUGINS`
                 guard is set — and MUST load without the guard, proving
                 the fixture is live. This pins the guard's behavior
                 against the tagged release's `load_plugins()` source.

  contract       Real `YoutubeDL` option parsing (including the
                 `js_runtimes` shape validation), descriptor selection
                 against local fixture metadata, the pinned Bun minimum
                 comparison, and a WebVTT byte fetch through the
                 production bounded opener with an injected low-level
                 connection stub. The stub replaces ONLY the socket layer;
                 the package's URL validation, manual-redirect, and
                 content-encoding layers always run for real.

Every arm is offline: no arm performs a metadata extraction or opens a
network connection. Exit 0 with the arm's OK line is the pass signal; any
other exit is a contract failure with a fixed diagnostic.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import urllib.request
from email.message import Message
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
_SCRIPT_PATH = _HERE.parent / "youtube-transcript"


def _load_package_module() -> Any:
    loader = SourceFileLoader("youtube_transcript", str(_SCRIPT_PATH))
    import importlib.util

    spec = importlib.util.spec_from_loader("youtube_transcript", loader)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["youtube_transcript"] = module
    loader.exec_module(module)
    return module


# ── Shared fixtures ────────────────────────────────────────────────────

_VIDEO_ID = "dQw4w9WgXcQ"
# Rolling auto-caption shape: the second cue restates the first plus a
# delta, exactly like live YouTube VTT.
_VTT_BYTES = (
    b"WEBVTT\n"
    b"\n"
    b"00:00:00.000 --> 00:00:03.500 align:start position:0%\n"
    b"hello<00:00:00.359><c> everyone</c>\n"
    b"\n"
    b"00:00:03.500 --> 00:00:05.500\n"
    b"hello everyone welcome to the video\n"
)

_TIMEDTEXT_URL = "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en&fmt=vtt"

_INFO: dict[str, Any] = {
    "id": _VIDEO_ID,
    "title": "fixture",
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


class _FakeResponse:
    """The minimum urllib response surface the package's fetch path uses."""

    def __init__(self, status: int, body: bytes = b"", headers: dict | None = None):
        self.status = status
        self.code = status
        self.msg = "fixture"
        self.headers = Message()
        for key, value in (headers or {}).items():
            self.headers[key] = value
        self._body = body

    def info(self) -> Message:
        return self.headers

    def __enter__(self) -> _FakeResponse:
        return self

    def __exit__(self, *_args: Any) -> None:
        self.close()

    def read(self, size: int = -1) -> bytes:
        if size < 0 or size >= len(self._body):
            data, self._body = self._body, b""
        else:
            data, self._body = self._body[:size], self._body[size:]
        return data

    def close(self) -> None:
        return


class _ConnectionStub(urllib.request.HTTPSHandler):
    """The injected low-level connection: no socket is ever opened.

    Queued as an HTTPS handler, this stub REPLACES urllib's default HTTPS
    connection for the opener under test; each queued outcome is one of: a
    `_FakeResponse` (returned as the connection result), an
    `(status, location)` tuple (a canned redirect response), or an
    Exception (raised at connection time). Everything above the connection
    — the error processor, the no-auto-redirect handler, the package's URL
    validation and encoding checks — runs unchanged. A test that reaches
    the real network instead of the stub fails its request-count
    assertion.
    """

    def __init__(self, outcomes: list[Any]):
        super().__init__()
        self.outcomes = list(outcomes)
        self.requests: list[Any] = []

    def https_open(self, req: Any) -> Any:
        return self._next(req)

    def http_open(self, req: Any) -> Any:
        # Never reached by the production fetcher (https only); present so
        # a scheme mistake cannot fall through to a real connection.
        return self._next(req)

    def _next(self, req: Any) -> Any:
        self.requests.append(req)
        if not self.outcomes:
            raise AssertionError("the fetch loop opened more connections than stubbed")
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        if isinstance(outcome, tuple):
            status, location = outcome
            headers = {"Location": location} if location else None
            return _FakeResponse(status=status, headers=headers)
        return outcome


# ── Arms ────────────────────────────────────────────────────────────────


def _write_plugin(root: Path) -> Path:
    """A discoverable fake plugin that leaves a marker file on import.

    The root doubles as a sys.path candidate: `default_plugin_paths()`
    yields every sys.path entry, and the finder looks for
    `<candidate>/yt_dlp_plugins/<plugin_type>/<module>.py` beneath it.
    """
    marker = root / "marker"
    package = root / "yt_dlp_plugins" / "extractor"
    package.mkdir(parents=True)
    (root / "yt_dlp_plugins" / "__init__.py").write_text("", encoding="utf-8")
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "guard_fixture_plug.py").write_text(
        "from pathlib import Path\n"
        "from yt_dlp.extractor.common import InfoExtractor\n"
        f"Path({str(marker)!r}).write_text('loaded', encoding='utf-8')\n"
        "class GuardFixtureIE(InfoExtractor):\n"
        "    IE_NAME = 'guard-fixture'\n"
        "    _VALID_URL = r'guardfixture:'\n",
        encoding="utf-8",
    )
    return marker


def _plugin_child(control: bool, plugin_root: Path) -> int:
    """One plugin-discovery run. Exit 0 = the expected discovery state."""
    marker = _write_plugin(plugin_root)
    if control:
        os.environ.pop("YTDLP_NO_PLUGINS", None)
    else:
        os.environ["YTDLP_NO_PLUGINS"] = "1"
    import yt_dlp

    extractor = yt_dlp.YoutubeDL({"quiet": True, "logger": _load_package_module()._DiscardLogger()})
    loaded = marker.exists()
    extractor.close()
    if control and not loaded:
        print("PLUGIN CONTROL FAILED: the fixture plugin was not discovered", file=sys.stderr)
        return 3
    if not control and loaded:
        print("PLUGIN GUARD FAILED: the plugin loaded despite YTDLP_NO_PLUGINS", file=sys.stderr)
        return 4
    print("PLUGIN GUARD OK" if not control else "PLUGIN CONTROL OK")
    return 0


def arm_plugin_guard() -> int:
    """The guard run + the unguarded control run, in disposable roots."""
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in ("XDG_CONFIG_HOME", "YTDLP_NO_PLUGINS", "PYTHONPATH")
    }
    for control, expect in ((False, "PLUGIN GUARD OK"), (True, "PLUGIN CONTROL OK")):
        with tempfile.TemporaryDirectory(prefix="ytdlp-plugin-guard-") as raw_root:
            root = Path(raw_root)
            child_environment = dict(environment)
            # The plugin root is a sys.path candidate, which the pinned
            # release treats as a plugin directory.
            child_environment["PYTHONPATH"] = str(root)
            completed = subprocess.run(  # noqa: S603 - fixed argv, no shell
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "plugin-child",
                    str(root),
                    "control" if control else "guarded",
                ],
                env=child_environment,
                capture_output=True,
                text=True,
                timeout=300,
                check=False,
            )
            if completed.returncode != 0 or expect not in completed.stdout:
                print(completed.stdout, file=sys.stderr)
                print(completed.stderr, file=sys.stderr)
                print(f"{expect} arm failed", file=sys.stderr)
                return completed.returncode or 5
            print(expect)
    return 0


def arm_contract() -> int:
    os.environ["YTDLP_NO_PLUGINS"] = "1"
    import yt_dlp
    from yt_dlp.utils._jsruntime import BunJsRuntime

    module = _load_package_module()
    deadline = 4_102_444_800_000  # 2100-01-01: effectively unbounded offline

    # 1. The pinned release's Bun minimum equals the documented minimum the
    #    host enforces (the Swift side pins the same literal; this is the
    #    library-side half of that pair).
    assert BunJsRuntime.MIN_SUPPORTED_VERSION == (1, 2, 11), BunJsRuntime.MIN_SUPPORTED_VERSION

    # 2. Real option parsing: YoutubeDL construction validates the whole
    #    parameter set — including the js_runtimes shape — with no network.
    bun_path = "/absolute/host-resolved/bun"
    params = module._ytdlp_params(bun_path, deadline)
    extractor = yt_dlp.YoutubeDL(params)
    cleaned: dict[str, Any] = dict(extractor.params)
    assert cleaned["retries"] == 0, cleaned["retries"]
    assert cleaned["extractor_retries"] == 0, cleaned["extractor_retries"]
    assert cleaned["fragment_retries"] == 0
    assert cleaned["skip_download"] is True
    assert cleaned["noplaylist"] is True
    assert cleaned["proxy"] == ""
    assert cleaned["usenetrc"] is False
    assert cleaned["cookiefile"] is None
    assert cleaned["cookiesfrombrowser"] is None
    assert cleaned["remote_components"] == set()
    assert cleaned["js_runtimes"] == {"bun": {"path": bun_path}}
    close = getattr(extractor, "close", None)
    if callable(close):
        close()

    # And the no-Bun variant: an EMPTY runtime table, never a Deno default.
    extractor = yt_dlp.YoutubeDL(module._ytdlp_params(None, deadline))
    cleaned_default: dict[str, Any] = dict(extractor.params)
    assert cleaned_default["js_runtimes"] == {}
    close = getattr(extractor, "close", None)
    if callable(close):
        close()

    # 3. Descriptor selection against fixture metadata: English manual
    #    beats English automatic beats the first other language.
    picked = module._select_ytdlp_caption_track(_INFO)
    assert picked is not None
    formats, language, generated = picked
    assert (language, generated) == ("en", False), (language, generated)
    descriptor = module._select_webvtt_format(formats)
    assert descriptor == _TIMEDTEXT_URL, descriptor

    # 4. The byte fetch through the production opener (identity encoding,
    #    limit+1 read) with only the socket layer stubbed.
    stub = _ConnectionStub([_FakeResponse(200, _VTT_BYTES)])
    payload = module._fetch_caption_bytes(descriptor, deadline, https_handler=stub)
    assert payload == _VTT_BYTES
    assert len(stub.requests) == 1
    request = stub.requests[0]
    assert request.get_header("Accept-encoding") == "identity"

    # 5. The parsed segments collapse the rolling captions to their delta.
    segments = module._parse_webvtt(payload)
    assert [segment["text"] for segment in segments] == [
        "hello everyone",
        "welcome to the video",
    ], segments

    # 6. The caption URL allowlist rejects every other shape fail-closed.
    for bad in (
        "http://www.youtube.com/api/timedtext",
        "https://evil.example/api/timedtext",
        f"https://www.youtube.com:8443/api/timedtext?v={_VIDEO_ID}",
        f"https://user:pass@www.youtube.com/api/timedtext?v={_VIDEO_ID}",
        f"https://www.youtube.com/api/timedtext?v={_VIDEO_ID}#fragment",
        # The delimiter alone is rejected: urlparse reports it as an
        # EMPTY fragment.
        "https://www.youtube.com/api/timedtext#",
    ):
        try:
            module._validate_caption_url(bad)
        except module.ProtocolFailure:
            continue
        raise AssertionError(f"caption URL validation accepted {bad!r}")

    print("CONTRACT OK")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "plugin-guard":
        return arm_plugin_guard()
    if len(argv) >= 2 and argv[1] == "contract":
        return arm_contract()
    if len(argv) == 4 and argv[1] == "plugin-child":
        # argv: <script> plugin-child <root> <control|guarded>
        root = Path(sys.argv[2])
        control = sys.argv[3] == "control"
        return _plugin_child(control, root)
    print("usage: _ytdlp_offline_contract.py <plugin-guard|contract>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
