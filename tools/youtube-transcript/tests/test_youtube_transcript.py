"""Unit tests for the youtube-transcript script.

Run from the tools/youtube-transcript directory:
    uv run pytest tests/test_youtube_transcript.py -v

All YouTube API calls are mocked — no network access required.
"""

from __future__ import annotations

import json
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest
from conftest import (
    MockTranscript,
    NoTranscriptFound,
    TranscriptsDisabled,
    VideoUnavailable,
    build_mock_segments,
)

# ── Import the youtube-transcript module (extensionless script) ────────

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "youtube-transcript"
assert _SCRIPT_PATH.exists(), f"youtube-transcript script not found at {_SCRIPT_PATH}"

_yt = SourceFileLoader("youtube_transcript", str(_SCRIPT_PATH)).load_module()
sys.modules["youtube_transcript"] = _yt


# ── Video ID extraction ────────────────────────────────────────────────


class TestExtractVideoId:
    def test_raw_video_id(self):
        assert _yt.extract_video_id("dQw4w9WgXcQ") == "dQw4w9WgXcQ"

    def test_watch_url(self):
        url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        assert _yt.extract_video_id(url) == "dQw4w9WgXcQ"

    def test_watch_url_no_www(self):
        assert _yt.extract_video_id("https://youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ"

    def test_short_url(self):
        assert _yt.extract_video_id("https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ"

    def test_shorts_url(self):
        assert _yt.extract_video_id("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ"

    def test_embed_url(self):
        assert _yt.extract_video_id("https://www.youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ"

    def test_watch_url_with_extra_params(self):
        url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=120s&feature=share"
        assert _yt.extract_video_id(url) == "dQw4w9WgXcQ"

    def test_url_without_scheme(self):
        assert _yt.extract_video_id("youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ"

    def test_mobile_url(self):
        assert _yt.extract_video_id("https://m.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ"

    def test_strips_whitespace(self):
        assert _yt.extract_video_id("  dQw4w9WgXcQ  ") == "dQw4w9WgXcQ"

    def test_empty_returns_none(self):
        assert _yt.extract_video_id("") is None

    def test_too_short_returns_none(self):
        assert _yt.extract_video_id("short") is None

    def test_non_youtube_url_returns_none(self):
        assert _yt.extract_video_id("https://example.com") is None


# ── Language preference ────────────────────────────────────────────────


class TestBuildLanguageList:
    def test_default_lang_en(self):
        assert _yt._build_language_list("en") == ["en", "en-US", "en-GB"]

    def test_custom_lang_es(self):
        assert _yt._build_language_list("es") == ["es", "en", "en-US", "en-GB"]

    def test_lang_en_US(self):
        assert _yt._build_language_list("en-US") == ["en-US", "en", "en-GB"]

    def test_no_duplicates(self):
        langs = _yt._build_language_list("en")
        assert langs.count("en") == 1


class TestLanguagePreference:
    def test_primary_lookup_passes_language_list(self, mocker, mock_yta):
        """get_transcript receives the full language preference list."""
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = build_mock_segments()

        _yt._fetch_transcript("dQw4w9WgXcQ", "en")

        call_kwargs = mock_yta.YouTubeTranscriptApi.return_value.fetch.call_args.kwargs
        assert call_kwargs["languages"][0] == "en"
        assert "en-US" in call_kwargs["languages"]

    def test_custom_lang_prepended(self, mocker, mock_yta):
        """A custom language is first, English fallbacks follow."""
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = build_mock_segments()

        _yt._fetch_transcript("dQw4w9WgXcQ", "fr")

        call_kwargs = mock_yta.YouTubeTranscriptApi.return_value.fetch.call_args.kwargs
        assert call_kwargs["languages"][0] == "fr"
        assert "en" in call_kwargs["languages"]

    def test_fallback_to_first_available(self, mocker, mock_yta):
        """When get_transcript raises NoTranscriptFound, use list_transcripts."""
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("test")

        fallback_segments = [{"text": "Bonjour tout le monde", "start": 0.0, "duration": 2.0}]
        fallback_transcript = MockTranscript("fr", fallback_segments)
        mock_yta.YouTubeTranscriptApi.return_value.list.return_value = [fallback_transcript]

        segments, language = _yt._fetch_transcript("dQw4w9WgXcQ", "en")

        assert language == "fr"
        assert segments == fallback_segments
        mock_yta.YouTubeTranscriptApi.return_value.list.assert_called_once_with("dQw4w9WgXcQ")


# ── Output formatting ──────────────────────────────────────────────────


class TestFormatTimestamp:
    def test_zero(self):
        assert _yt.format_timestamp(0.0) == "00:00"

    def test_under_minute(self):
        assert _yt.format_timestamp(5.0) == "00:05"

    def test_over_minute(self):
        assert _yt.format_timestamp(65.0) == "01:05"

    def test_over_hour(self):
        assert _yt.format_timestamp(3661.0) == "01:01:01"

    def test_truncates_decimals(self):
        assert _yt.format_timestamp(3.7) == "00:03"


class TestFormatMarkdown:
    def test_no_timestamps(self, mock_segments):
        result = _yt.format_markdown("dQw4w9WgXcQ", mock_segments, "en", timestamps=False)
        assert "# YouTube Transcript: dQw4w9WgXcQ" in result
        assert "Hello everyone welcome to the video." in result
        assert "[00:00]" not in result

    def test_with_timestamps(self, mock_segments):
        result = _yt.format_markdown("dQw4w9WgXcQ", mock_segments, "en", timestamps=True)
        assert "# YouTube Transcript: dQw4w9WgXcQ" in result
        assert "[00:00]" in result
        assert "[00:03]" in result
        assert "[00:05]" in result

    def test_clean_text_joins_segments(self, mock_segments):
        result = _yt.format_markdown("dQw4w9WgXcQ", mock_segments, "en", timestamps=False)
        # Header line, blank line, joined text
        lines = result.rstrip("\n").split("\n")
        assert lines[0] == "# YouTube Transcript: dQw4w9WgXcQ"
        assert lines[1] == ""
        body = lines[2]
        assert "Hello everyone" in body
        assert "how to build great software." in body

    def test_empty_segments(self):
        result = _yt.format_markdown("dQw4w9WgXcQ", [], "en", timestamps=False)
        assert "# YouTube Transcript: dQw4w9WgXcQ" in result
        # Body is empty but header is present
        assert result.endswith("\n")

    def test_ends_with_newline(self, mock_segments):
        result = _yt.format_markdown("dQw4w9WgXcQ", mock_segments, "en")
        assert result.endswith("\n")


class TestFormatJson:
    def test_structured_json(self, mock_segments):
        markdown = _yt.format_markdown("dQw4w9WgXcQ", mock_segments, "en")
        output = _yt.format_json("dQw4w9WgXcQ", mock_segments, "en", markdown)
        data = json.loads(output)

        assert data["video_id"] == "dQw4w9WgXcQ"
        assert data["language"] == "en"
        assert len(data["segments"]) == 3
        assert data["segments"][0]["text"] == "Hello everyone welcome to the video."
        assert data["segments"][0]["start"] == 0.0
        assert "# YouTube Transcript" in data["markdown"]

    def test_json_is_valid(self, mock_segments):
        markdown = _yt.format_markdown("test", mock_segments, "en")
        output = _yt.format_json("test", mock_segments, "en", markdown)
        # Must be valid JSON (no trailing data)
        json.loads(output)


# ── CLI argument parsing ──────────────────────────────────────────────


class TestArgParsing:
    def test_help_exits_zero(self):
        parser = _yt.build_parser()
        with pytest.raises(SystemExit) as exc:
            parser.parse_args(["--help"])
        assert exc.value.code == 0

    def test_default_lang(self):
        parser = _yt.build_parser()
        args = parser.parse_args(["dQw4w9WgXcQ"])
        assert args.lang == "en"

    def test_custom_lang(self):
        parser = _yt.build_parser()
        args = parser.parse_args(["--lang", "es", "dQw4w9WgXcQ"])
        assert args.lang == "es"

    def test_json_flag(self):
        parser = _yt.build_parser()
        args = parser.parse_args(["--json", "dQw4w9WgXcQ"])
        assert args.json is True

    def test_timestamps_flag(self):
        parser = _yt.build_parser()
        args = parser.parse_args(["--timestamps", "dQw4w9WgXcQ"])
        assert args.timestamps is True

    def test_output_short_flag(self):
        parser = _yt.build_parser()
        args = parser.parse_args(["-o", "out.md", "dQw4w9WgXcQ"])
        assert str(args.output) == "out.md"

    def test_output_long_flag(self):
        parser = _yt.build_parser()
        args = parser.parse_args(["--output", "out.md", "dQw4w9WgXcQ"])
        assert str(args.output) == "out.md"

    def test_defaults(self):
        parser = _yt.build_parser()
        args = parser.parse_args(["dQw4w9WgXcQ"])
        assert args.json is False
        assert args.timestamps is False
        assert args.output is None
        assert args.lang == "en"


# ── Main: success path ────────────────────────────────────────────────


class TestMainSuccess:
    def test_markdown_to_stdout(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = build_mock_segments()

        _yt.main(argv=["dQw4w9WgXcQ"])

        out = capsys.readouterr().out
        assert "# YouTube Transcript: dQw4w9WgXcQ" in out
        assert "Hello everyone" in out

    def test_json_to_stdout(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = build_mock_segments()

        _yt.main(argv=["dQw4w9WgXcQ", "--json"])

        out = capsys.readouterr().out
        data = json.loads(out)
        assert data["video_id"] == "dQw4w9WgXcQ"
        assert len(data["segments"]) == 3
        assert "markdown" in data

    def test_markdown_to_file(self, mocker, mock_yta, tmp_path, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = build_mock_segments()

        out_file = tmp_path / "transcript.md"
        _yt.main(argv=["dQw4w9WgXcQ", "--output", str(out_file)])

        captured = capsys.readouterr()
        assert captured.out == ""
        content = out_file.read_text(encoding="utf-8")
        assert "# YouTube Transcript: dQw4w9WgXcQ" in content
        assert "Hello everyone" in content

    def test_timestamps_flag(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = build_mock_segments()

        _yt.main(argv=["dQw4w9WgXcQ", "--timestamps"])

        out = capsys.readouterr().out
        assert "[00:00]" in out
        assert "[00:03]" in out

    def test_url_input(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.return_value = build_mock_segments()

        _yt.main(argv=["https://www.youtube.com/watch?v=dQw4w9WgXcQ"])

        out = capsys.readouterr().out
        assert "# YouTube Transcript: dQw4w9WgXcQ" in out
        call_args = mock_yta.YouTubeTranscriptApi.return_value.fetch.call_args.args
        assert call_args[0] == "dQw4w9WgXcQ"


# ── Main: error exit codes ─────────────────────────────────────────────


class TestExitCodes:
    def test_exit_no_transcript(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = NoTranscriptFound("test")
        mock_yta.YouTubeTranscriptApi.return_value.list.side_effect = NoTranscriptFound("test")

        with pytest.raises(SystemExit) as exc:
            _yt.main(argv=["dQw4w9WgXcQ"])

        assert exc.value.code == 2
        err = capsys.readouterr().err.lower()
        assert "no transcript" in err

    def test_exit_transcripts_disabled(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = TranscriptsDisabled("test")

        with pytest.raises(SystemExit) as exc:
            _yt.main(argv=["dQw4w9WgXcQ"])

        assert exc.value.code == 3
        err = capsys.readouterr().err.lower()
        assert "disabled" in err

    def test_exit_video_unavailable(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = VideoUnavailable("test")

        with pytest.raises(SystemExit) as exc:
            _yt.main(argv=["dQw4w9WgXcQ"])

        assert exc.value.code == 4
        err = capsys.readouterr().err.lower()
        assert "unavailable" in err

    def test_exit_unknown_error(self, mocker, mock_yta, capsys):
        mocker.patch.object(_yt, "_import_api", return_value=mock_yta)
        mock_yta.YouTubeTranscriptApi.return_value.fetch.side_effect = RuntimeError("network failure")

        with pytest.raises(SystemExit) as exc:
            _yt.main(argv=["dQw4w9WgXcQ"])

        assert exc.value.code == 1
        err = capsys.readouterr().err.lower()
        assert "network failure" in err

    def test_exit_invalid_video_id(self, capsys):
        with pytest.raises(SystemExit) as exc:
            _yt.main(argv=["short"])

        assert exc.value.code == 1
        err = capsys.readouterr().err.lower()
        assert "video id" in err
