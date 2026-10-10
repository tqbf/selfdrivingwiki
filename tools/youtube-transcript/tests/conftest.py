"""Shared fixtures for youtube-transcript tests.

We vendor mock exception classes that mirror youtube_transcript_api's
exception hierarchy. The script catches exceptions by the attribute on the
module object returned by _import_api(), so the tests provide these
classes via a mock module namespace.
"""

from __future__ import annotations

import types
from typing import Any
from unittest.mock import MagicMock

import pytest

# ── Mock exception classes (mirror youtube_transcript_api 1.x) ──────────


class CouldNotRetrieveTranscript(Exception):
    """Base retrieval failure (mirrors the library's base class)."""


class TranscriptsDisabled(CouldNotRetrieveTranscript):
    pass


class NoTranscriptFound(CouldNotRetrieveTranscript):
    pass


class VideoUnavailable(CouldNotRetrieveTranscript):
    pass


class InvalidVideoId(CouldNotRetrieveTranscript):
    pass


class RequestBlocked(CouldNotRetrieveTranscript):
    pass


class IpBlocked(RequestBlocked):
    pass


class TooManyRequests(Exception):
    pass


class YouTubeRequestFailed(CouldNotRetrieveTranscript):
    pass


class YouTubeDataUnparsable(CouldNotRetrieveTranscript):
    pass


# ── Mock transcript data ──────────────────────────────────────────────


def build_mock_segments() -> list[dict[str, str | float]]:
    """Sample transcript segments for tests."""
    return [
        {"text": "Hello everyone welcome to the video.", "start": 0.0, "duration": 3.5},
        {"text": "Today we are going to talk about", "start": 3.5, "duration": 2.0},
        {"text": "how to build great software.", "start": 5.5, "duration": 3.0},
    ]


class MockTranscript:
    """Simulates youtube_transcript_api's Transcript object (list path)."""

    def __init__(
        self,
        language_code: str,
        segments: list[dict[str, str | float]] | None = None,
        is_generated: bool = False,
    ) -> None:
        self.language_code = language_code
        self.is_generated = is_generated
        self._segments = segments if segments is not None else build_mock_segments()

    def fetch(self) -> list[dict[str, str | float]]:
        return self._segments


class MockFetchedTranscript:
    """Simulates youtube_transcript_api's FetchedTranscript (fetch path)."""

    def __init__(
        self,
        language_code: str = "en",
        segments: list[dict[str, str | float]] | None = None,
        is_generated: bool = False,
    ) -> None:
        self.language_code = language_code
        self.is_generated = is_generated
        self._segments = segments if segments is not None else build_mock_segments()

    def to_raw_data(self) -> list[dict[str, str | float]]:
        return list(self._segments)


# ── Fixtures ──────────────────────────────────────────────────────────


@pytest.fixture
def mock_segments() -> list[dict[str, str | float]]:
    return build_mock_segments()


@pytest.fixture
def mock_yta() -> Any:
    """A mock youtube_transcript_api module namespace.

    Tests mock the _import_api function to return this object so that the
    script code (which expects a real module) operates on mock data.
    """
    yta = types.SimpleNamespace()
    # Mirror the exception classes from youtube_transcript_api.
    yta.CouldNotRetrieveTranscript = CouldNotRetrieveTranscript
    yta.TranscriptsDisabled = TranscriptsDisabled
    yta.NoTranscriptFound = NoTranscriptFound
    yta.VideoUnavailable = VideoUnavailable
    yta.InvalidVideoId = InvalidVideoId
    yta.RequestBlocked = RequestBlocked
    yta.IpBlocked = IpBlocked
    yta.TooManyRequests = TooManyRequests
    yta.YouTubeRequestFailed = YouTubeRequestFailed
    yta.YouTubeDataUnparsable = YouTubeDataUnparsable
    yta.YouTubeTranscriptApi = MagicMock()
    return yta


# ── Mock yt-dlp fallback ──────────────────────────────────────────────


@pytest.fixture
def mock_ytdlp(mocker: Any) -> Any:
    """A mock for the script's yt-dlp fallback entry point.

    The real fallback needs the pinned PEP 723 environment (the dev test
    environment does not install yt-dlp), so in-process tests patch
    `_fetch_captions_via_ytdlp` itself. The default side effect is the
    fixed failure the real fallback emits when it cannot retrieve
    captions; a test sets `return_value` to simulate fallback success.
    Eligibility is observable through `call_count`.
    """
    from youtube_transcript import ProtocolFailure  # noqa: PLC0415

    fallback = mocker.patch.object(
        _yt_module(),
        "_fetch_captions_via_ytdlp",
        side_effect=ProtocolFailure(
            "extraction-failure",
            "the caption fallback could not retrieve captions",
        ),
    )
    return fallback


def _yt_module() -> Any:
    """The already-imported youtube-transcript module (see test_protocol)."""
    import sys  # noqa: PLC0415

    return sys.modules["youtube_transcript"]
