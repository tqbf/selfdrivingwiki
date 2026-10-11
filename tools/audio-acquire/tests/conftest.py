"""Shared fixtures for audio-acquire tests.

The package imports yt_dlp lazily (through `_import_ytdlp`), so the dev
test environment — which deliberately does not install yt-dlp — injects a
mock module namespace. The pinned-library contract tests run in a separate
`uv run --script` environment and never use these mocks.
"""

from __future__ import annotations

import sys
import types
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "audio-acquire"
assert _SCRIPT_PATH.exists(), f"audio-acquire script not found at {_SCRIPT_PATH}"


@pytest.fixture()
def audio() -> Any:
    """The package module, with the dev-only mock yt_dlp installed."""
    loader = SourceFileLoader("audio_acquire", str(_SCRIPT_PATH))
    module: Any = loader.load_module()
    sys.modules["audio_acquire"] = module
    _install_mock_ytdlp(module)
    return module


class MockYoutubeDL:
    """The minimum YoutubeDL surface the package's metadata path uses."""

    # Subclasses/tests set the extract result or the raise.
    extract_result: Any = {}
    extract_raises: Exception | None = None
    constructed_params: dict[str, Any] | None = None

    def __init__(self, params: dict[str, Any]) -> None:
        self.params = params
        type(self).constructed_params = dict(params)

    def extract_info(self, url: str, download: bool) -> Any:  # noqa: ARG002
        assert download is False, "the package must never download through yt-dlp"
        if MockYoutubeDL.extract_raises is not None:
            raise MockYoutubeDL.extract_raises
        return MockYoutubeDL.extract_result

    def urlopen(self, url_or_request: Any) -> Any:
        # The media phase goes through the pinned transport; protocol tests
        # patch the package's bounded fetch, so this must never run.
        raise AssertionError("urlopen ran: the media fetch was not patched")

    def close(self) -> None:
        return


def _install_mock_ytdlp(module: Any) -> None:
    """Point `_import_ytdlp` at the mock instead of the real library."""
    mock = types.ModuleType("yt_dlp_mock")
    mock.YoutubeDL = MockYoutubeDL  # type: ignore[attr-defined]

    def _import() -> Any:
        return mock

    module._import_ytdlp = _import  # type: ignore[attr-defined]


# ── Shared request fixtures ────────────────────────────────────────────

REQUEST_ID = "7c2d4f6a-0000-4000-8000-000000000004"
VIDEO_ID = "dQw4w9WgXcQ"
WATCH_URL = f"https://www.youtube.com/watch?v={VIDEO_ID}"

# A minimal valid M4A payload: ftyp box (size 0x18) + brand + a stub body.
FTYP_HEADER = bytes([0x00, 0x00, 0x00, 0x18]) + b"ftypM4A " + bytes(12)


def build_request(output_path: str = "output/fetch/result") -> dict[str, Any]:
    return {
        "requestID": REQUEST_ID,
        "role": "fetcher",
        "protocolRevision": 5,
        "mimeType": "audio/x-wiki-audio-acquire",
        "remoteURL": WATCH_URL,
        "outputPath": output_path,
        "deadlineMillisecondsSince1970": int(
            __import__("time").time() * 1000
        )
        + 600_000,
    }


def valid_metadata(url: str = "https://rr3---sn-p5qs7nz6.googlevideo.com/videoplayback?id=x") -> dict[str, Any]:
    """Fixture metadata: 10-minute video, one validated M4A format."""
    return {
        "id": VIDEO_ID,
        "title": "fixture",
        "duration": 600,
        "formats": [
            {
                "format_id": "18",
                "ext": "mp4",
                "vcodec": "avc1.42001E",
                "acodec": "mp4a.40.2",
                "url": "https://ignored.example/video",
            },
            {
                "format_id": "140",
                "ext": "m4a",
                "vcodec": "none",
                "acodec": "mp4a.40.2",
                "abr": 128.0,
                "url": url,
            },
            {
                "format_id": "139",
                "ext": "m4a",
                "vcodec": "none",
                "acodec": "mp4a.40.5",
                "abr": 48.0,
                "url": "https://rr1---sn-p5qs7nz6.googlevideo.com/videoplayback?itanum=48",
            },
        ],
    }
