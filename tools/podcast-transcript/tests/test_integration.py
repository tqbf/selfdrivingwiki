"""Integration tests for podcast-transcript (requires real network).

Run from the tools/podcast-transcript directory:
    uv run pytest tests/test_integration.py -v --skip-glob='*test_vlm*'

These tests are skipped by default. Run them explicitly with:
    uv run pytest tests/test_integration.py -v
"""

from __future__ import annotations

import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest

# ── Import the podcast-transcript module (extensionless file) ────────────────

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "podcast-transcript"
assert _SCRIPT_PATH.exists(), f"podcast-transcript script not found at {_SCRIPT_PATH}"

_podcast_transcript = SourceFileLoader("podcast_transcript", str(_SCRIPT_PATH)).load_module()
sys.modules["podcast_transcript"] = _podcast_transcript


# ── Integration tests (require real network and real podcast URLs) ───────────

# These tests are skipped by default because they require:
# 1. Real network access
# 2. A real Apple Podcasts URL with <podcast:transcript> tags
# 3. May be slow and flaky due to external dependencies


@pytest.mark.skip(reason="Integration test - requires real network and podcast URL")
class TestRealPodcastTranscript:
    """Test with real Apple Podcasts URLs that have <podcast:transcript> tags.

    To run these tests, you need to provide a real podcast URL that:
    1. Is publicly accessible
    2. Has <podcast:transcript> tags in its RSS feed
    3. The transcript files are accessible

    Example usage:
        pytest tests/test_integration.py::TestRealPodcastTranscript -v
    """

    def test_fetch_transcript_from_real_podcast(self) -> None:
        """Test fetching a transcript from a real podcast.

        Replace this URL with a real podcast that has transcripts.
        """
        url = "https://podcasts.apple.com/us/podcast/example/id1234567890?i=1000123456789"

        result = _podcast_transcript.fetch_transcript(url)

        assert result["show_id"]
        assert result["episode_id"]
        assert result["format"] in ("vtt", "srt", "html", "plain")
        assert result["markdown"]
        assert len(result["markdown"]) > 0

    def test_fetch_transcript_json_output(self) -> None:
        """Test JSON output format with real podcast."""
        url = "https://podcasts.apple.com/us/podcast/example/id1234567890?i=1000123456789"

        result = _podcast_transcript.fetch_transcript(url)

        assert "show_id" in result
        assert "episode_id" in result
        assert "language" in result
        assert "format" in result
        assert "markdown" in result

    def test_cli_with_real_podcast(self, capsys: pytest.CaptureFixture[str]) -> None:
        """Test the CLI with a real podcast URL."""
        url = "https://podcasts.apple.com/us/podcast/example/id1234567890?i=1000123456789"

        _podcast_transcript.main([url])

        captured = capsys.readouterr()
        assert "# Podcast Transcript" in captured.out
        assert len(captured.out) > 20  # More than just the header

    def test_cli_json_output_with_real_podcast(self, capsys: pytest.CaptureFixture[str]) -> None:
        """Test CLI JSON output with real podcast."""
        url = "https://podcasts.apple.com/us/podcast/example/id1234567890?i=1000123456789"

        _podcast_transcript.main(["--json", url])

        captured = capsys.readouterr()
        import json

        result = json.loads(captured.out)
        assert "show_id" in result
        assert "episode_id" in result
        assert "markdown" in result
