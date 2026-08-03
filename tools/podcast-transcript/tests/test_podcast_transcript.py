"""Unit tests for podcast-transcript.

Run from the tools/podcast-transcript directory:
    uv run pytest tests/test_podcast_transcript.py -v
"""

from __future__ import annotations

import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

import pytest
from pytest_mock import MockerFixture

# ── Import the podcast-transcript module (extensionless file) ────────────────

_SCRIPT_PATH = Path(__file__).resolve().parent.parent / "podcast-transcript"
assert _SCRIPT_PATH.exists(), f"podcast-transcript script not found at {_SCRIPT_PATH}"

_podcast_transcript = SourceFileLoader("podcast_transcript", str(_SCRIPT_PATH)).load_module()
sys.modules["podcast_transcript"] = _podcast_transcript

# ── URL parsing tests ────────────────────────────────────────────────────────


class TestParseApplePodcastsURL:
    def test_extracts_show_and_episode_ids(self) -> None:
        url = "https://podcasts.apple.com/us/podcast/test-podcast/id1234567890?i=1000123456789"
        show_id, episode_id = _podcast_transcript.parse_apple_podcasts_url(url)
        assert show_id == "1234567890"
        assert episode_id == "1000123456789"

    def test_handles_different_country_codes(self) -> None:
        url = "https://podcasts.apple.com/gb/podcast/test/id9876543210?i=1000987654321"
        show_id, episode_id = _podcast_transcript.parse_apple_podcasts_url(url)
        assert show_id == "9876543210"
        assert episode_id == "1000987654321"

    def test_handles_show_name_with_hyphens(self) -> None:
        url = "https://podcasts.apple.com/us/podcast/my-test-podcast-show/id1111111111?i=1000111111111"
        show_id, episode_id = _podcast_transcript.parse_apple_podcasts_url(url)
        assert show_id == "1111111111"
        assert episode_id == "1000111111111"

    def test_raises_error_when_show_id_missing(self) -> None:
        url = "https://podcasts.apple.com/us/podcast/test-podcast?i=1000123456789"
        with pytest.raises(ValueError, match="Cannot extract show ID"):
            _podcast_transcript.parse_apple_podcasts_url(url)

    def test_raises_error_when_episode_id_missing(self) -> None:
        url = "https://podcasts.apple.com/us/podcast/test-podcast/id1234567890"
        with pytest.raises(ValueError, match="Cannot extract episode ID"):
            _podcast_transcript.parse_apple_podcasts_url(url)


# ── iTunes Lookup API tests ───────────────────────────────────────────────────


class TestGetFeedURL:
    def test_returns_feed_url_from_successful_lookup(
        self, mocker: MockerFixture, itunes_lookup_response: dict
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_response
        mock_get.return_value = mock_response

        feed_url = _podcast_transcript.get_feed_url("1234567890")
        assert feed_url == "https://example.com/feed.rss"

    def test_raises_value_error_when_no_results(
        self, mocker: MockerFixture, itunes_lookup_no_results: dict
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_no_results
        mock_get.return_value = mock_response

        with pytest.raises(ValueError, match="Podcast not found"):
            _podcast_transcript.get_feed_url("1234567890")

    def test_raises_value_error_when_no_feed_url(
        self, mocker: MockerFixture, itunes_lookup_no_feed_url: dict
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_no_feed_url
        mock_get.return_value = mock_response

        with pytest.raises(ValueError, match="no feedUrl available"):
            _podcast_transcript.get_feed_url("1234567890")

    def test_propagates_network_errors(self, mocker: MockerFixture) -> None:
        mock_get = mocker.patch("requests.get")
        mock_get.side_effect = Exception("Network error")

        with pytest.raises(Exception, match="Network error"):
            _podcast_transcript.get_feed_url("1234567890")


# ── RSS parsing tests ────────────────────────────────────────────────────────


class TestFindEpisodeInFeed:
    def test_finds_episode_by_guid(self, sample_rss_feed: str, mocker: MockerFixture) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = sample_rss_feed
        mock_get.return_value = mock_response

        result = _podcast_transcript.find_episode_in_feed(
            "https://example.com/feed.rss", "1000123456789"
        )
        assert result is not None
        episode_item, transcript_tags = result
        assert len(transcript_tags) == 1
        assert transcript_tags[0].get("url") == "https://example.com/transcript1.vtt"

    def test_finds_episode_by_link(self, sample_rss_feed: str, mocker: MockerFixture) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = sample_rss_feed
        mock_get.return_value = mock_response

        result = _podcast_transcript.find_episode_in_feed(
            "https://example.com/feed.rss", "1000123456790"
        )
        assert result is not None
        episode_item, transcript_tags = result
        assert len(transcript_tags) == 1

    def test_finds_episode_by_itunes_episode(
        self, sample_rss_feed: str, mocker: MockerFixture
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = sample_rss_feed
        mock_get.return_value = mock_response

        result = _podcast_transcript.find_episode_in_feed(
            "https://example.com/feed.rss", "1000123456791"
        )
        assert result is not None
        episode_item, transcript_tags = result
        assert len(transcript_tags) == 1

    def test_returns_none_when_episode_not_found(
        self, sample_rss_feed: str, mocker: MockerFixture
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = sample_rss_feed
        mock_get.return_value = mock_response

        result = _podcast_transcript.find_episode_in_feed(
            "https://example.com/feed.rss", "9999999999"
        )
        assert result is None

    def test_returns_empty_transcript_list_when_no_transcript(
        self, sample_rss_feed: str, mocker: MockerFixture
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = sample_rss_feed
        mock_get.return_value = mock_response

        result = _podcast_transcript.find_episode_in_feed(
            "https://example.com/feed.rss", "1000123456793"
        )
        assert result is not None
        episode_item, transcript_tags = result
        assert len(transcript_tags) == 0


# ── Transcript parsing tests ──────────────────────────────────────────────────


class TestParseVTT:
    def test_extracts_text_from_vtt(self, sample_vtt: str) -> None:
        text = _podcast_transcript._parse_vtt(sample_vtt)
        assert "This is the first caption." in text
        assert "This is the second caption." in text
        assert "This is the third caption with multiple lines." in text

    def test_joins_captions_with_paragraph_breaks(self, sample_vtt: str) -> None:
        text = _podcast_transcript._parse_vtt(sample_vtt)
        assert "\n\n" in text


class TestParseSRT:
    def test_extracts_text_from_srt(self, sample_srt: str) -> None:
        text = _podcast_transcript._parse_srt(sample_srt)
        assert "This is the first subtitle." in text
        assert "This is the second subtitle." in text
        assert "This is the third subtitle." in text

    def test_joins_subtitles_with_paragraph_breaks(self, sample_srt: str) -> None:
        text = _podcast_transcript._parse_srt(sample_srt)
        assert "\n\n" in text


class TestParseHTML:
    def test_extracts_plain_text_from_html(self, sample_html: str) -> None:
        text = _podcast_transcript._parse_html(sample_html)
        assert "This is the first paragraph of the transcript." in text
        assert "This is the second paragraph." in text
        assert "This is the third paragraph with some bold text." in text

    def test_strips_script_and_style_tags(self, sample_html: str) -> None:
        text = _podcast_transcript._parse_html(sample_html)
        assert "console.log" not in text
        assert "color: black" not in text

    def test_removes_html_tags(self, sample_html: str) -> None:
        text = _podcast_transcript._parse_html(sample_html)
        assert "<h1>" not in text
        assert "</p>" not in text
        assert "<strong>" not in text


class TestParsePlain:
    def test_normalizes_plain_text(self, sample_plain: str) -> None:
        text = _podcast_transcript._parse_plain(sample_plain)
        assert "This is the first paragraph of the transcript." in text
        assert "This is the second paragraph." in text
        assert "This is the third paragraph." in text

    def test_joins_paragraphs_with_breaks(self, sample_plain: str) -> None:
        text = _podcast_transcript._parse_plain(sample_plain)
        assert "\n\n" in text


class TestParseTranscript:
    def test_detects_vtt_from_content_type(self, sample_vtt: str) -> None:
        text, format = _podcast_transcript.parse_transcript(sample_vtt, content_type="text/vtt")
        assert format == "vtt"
        assert "first caption" in text

    def test_detects_srt_from_content_type(self, sample_srt: str) -> None:
        text, format = _podcast_transcript.parse_transcript(
            sample_srt, content_type="application/x-subrip"
        )
        assert format == "srt"
        assert "first subtitle" in text

    def test_detects_html_from_content_type(self, sample_html: str) -> None:
        text, format = _podcast_transcript.parse_transcript(sample_html, content_type="text/html")
        assert format == "html"
        assert "first paragraph" in text

    def test_detects_plain_from_content_type(self, sample_plain: str) -> None:
        text, format = _podcast_transcript.parse_transcript(sample_plain, content_type="text/plain")
        assert format == "plain"
        assert "first paragraph" in text

    def test_detects_vtt_from_url_extension(self, sample_vtt: str) -> None:
        text, format = _podcast_transcript.parse_transcript(sample_vtt, url="https://example.com/transcript.vtt")
        assert format == "vtt"
        assert "first caption" in text

    def test_detects_srt_from_url_extension(self, sample_srt: str) -> None:
        text, format = _podcast_transcript.parse_transcript(sample_srt, url="https://example.com/transcript.srt")
        assert format == "srt"
        assert "first subtitle" in text

    def test_detects_html_from_url_extension(self, sample_html: str) -> None:
        text, format = _podcast_transcript.parse_transcript(sample_html, url="https://example.com/transcript.html")
        assert format == "html"
        assert "first paragraph" in text

    def test_defaults_to_vtt_when_unknown_format(self, sample_vtt: str) -> None:
        text, format = _podcast_transcript.parse_transcript(sample_vtt)
        assert format == "vtt"


# ── Download transcript tests ─────────────────────────────────────────────────


class TestDownloadTranscript:
    def test_downloads_and_parses_vtt_transcript(
        self, mocker: MockerFixture, sample_vtt: str
    ) -> None:
        mock_element = mocker.Mock()
        mock_element.get.side_effect = lambda k: {
            "url": "https://example.com/transcript.vtt",
            "type": "text/vtt",
            "lang": "en",
        }.get(k)

        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = sample_vtt
        mock_get.return_value = mock_response

        text, format, language = _podcast_transcript.download_transcript(mock_element)
        assert format == "vtt"
        assert language == "en"
        assert "first caption" in text

    def test_raises_error_when_url_missing(self, mocker: MockerFixture) -> None:
        mock_element = mocker.Mock()
        mock_element.get.return_value = None

        with pytest.raises(ValueError, match="missing required 'url' attribute"):
            _podcast_transcript.download_transcript(mock_element)


# ── Get episode audio URL tests ───────────────────────────────────────────────


class TestGetEpisodeAudioURL:
    def test_extracts_audio_url_from_enclosure(self, sample_rss_feed: str) -> None:
        import xml.etree.ElementTree as ET

        root = ET.fromstring(sample_rss_feed)
        item = root.find(".//item")
        assert item is not None

        enclosure = ET.SubElement(item, "enclosure")
        enclosure.set("url", "https://example.com/audio.mp3")

        audio_url = _podcast_transcript.get_episode_audio_url(item)
        assert audio_url == "https://example.com/audio.mp3"

    def test_returns_none_when_no_enclosure(self, sample_rss_feed: str) -> None:
        import xml.etree.ElementTree as ET

        root = ET.fromstring(sample_rss_feed)
        item = root.find(".//item")
        assert item is not None

        audio_url = _podcast_transcript.get_episode_audio_url(item)
        assert audio_url is None


# ── CLI argument parsing tests ────────────────────────────────────────────────


class TestArgParsing:
    def test_url_argument_required(self) -> None:
        parser = _podcast_transcript.build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args([])

    def test_accepts_json_flag(self) -> None:
        parser = _podcast_transcript.build_parser()
        args = parser.parse_args(["--json", "https://example.com/podcast"])
        assert args.json is True

    def test_accepts_output_flag(self) -> None:
        parser = _podcast_transcript.build_parser()
        args = parser.parse_args(["--output", "out.md", "https://example.com/podcast"])
        assert args.output.name == "out.md"

    def test_accepts_transcribe_flag(self) -> None:
        parser = _podcast_transcript.build_parser()
        args = parser.parse_args(["--transcribe", "https://example.com/podcast"])
        assert args.transcribe is True


# ── Main fetch_transcript tests ───────────────────────────────────────────────


class TestFetchTranscript:
    def test_full_workflow_success(
        self,
        mocker: MockerFixture,
        sample_rss_feed: str,
        sample_vtt: str,
        itunes_lookup_response: dict,
    ) -> None:
        mock_get = mocker.patch("requests.get")

        # Create different responses for different calls
        def mock_get_side_effect(url, **kwargs):
            response = mocker.Mock()
            if "itunes.apple.com" in url:
                response.json.return_value = itunes_lookup_response
            elif "feed.rss" in url:
                response.text = sample_rss_feed
            elif "transcript" in url:
                response.text = sample_vtt
            response.raise_for_status = mocker.Mock()
            return response

        mock_get.side_effect = mock_get_side_effect

        result = _podcast_transcript.fetch_transcript(
            "https://podcasts.apple.com/us/podcast/test/id1234567890?i=1000123456789"
        )

        assert result["show_id"] == "1234567890"
        assert result["episode_id"] == "1000123456789"
        assert result["format"] == "vtt"
        assert result["language"] == "en"
        assert "first caption" in result["markdown"]

    def test_raises_value_error_when_podcast_not_found(
        self, mocker: MockerFixture, itunes_lookup_no_results: dict
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_no_results
        mock_get.return_value = mock_response

        with pytest.raises(ValueError, match="Podcast not found"):
            _podcast_transcript.fetch_transcript(
                "https://podcasts.apple.com/us/podcast/test/id1234567890?i=1000123456789"
            )

    def test_raises_value_error_when_episode_not_found(
        self,
        mocker: MockerFixture,
        sample_rss_feed: str,
        itunes_lookup_response: dict,
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_response
        mock_get.return_value = mock_response
        mock_response.text = sample_rss_feed

        with pytest.raises(ValueError, match="Episode not found in feed"):
            _podcast_transcript.fetch_transcript(
                "https://podcasts.apple.com/us/podcast/test/id1234567890?i=9999999999"
            )

    def test_raises_value_error_when_no_transcript(
        self,
        mocker: MockerFixture,
        sample_rss_feed: str,
        itunes_lookup_response: dict,
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_response
        mock_get.return_value = mock_response
        mock_response.text = sample_rss_feed

        with pytest.raises(ValueError, match="No transcript available"):
            _podcast_transcript.fetch_transcript(
                "https://podcasts.apple.com/us/podcast/test/id1234567890?i=1000123456793"
            )


# ── Main function exit code tests ─────────────────────────────────────────────


class TestMainExitCodes:
    def test_exits_3_when_podcast_not_found(
        self,
        mocker: MockerFixture,
        itunes_lookup_no_results: dict,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_no_results
        mock_get.return_value = mock_response

        with pytest.raises(SystemExit) as exc:
            _podcast_transcript.main(
                ["https://podcasts.apple.com/us/podcast/test/id1234567890?i=1000123456789"]
            )
        assert exc.value.code == 3

    def test_exits_4_when_episode_not_found(
        self,
        mocker: MockerFixture,
        sample_rss_feed: str,
        itunes_lookup_response: dict,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_response
        mock_get.return_value = mock_response
        mock_response.text = sample_rss_feed

        with pytest.raises(SystemExit) as exc:
            _podcast_transcript.main(
                ["https://podcasts.apple.com/us/podcast/test/id1234567890?i=9999999999"]
            )
        assert exc.value.code == 4

    def test_exits_1_when_no_transcript(
        self,
        mocker: MockerFixture,
        sample_rss_feed: str,
        itunes_lookup_response: dict,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.json.return_value = itunes_lookup_response
        mock_get.return_value = mock_response
        mock_response.text = sample_rss_feed

        with pytest.raises(SystemExit) as exc:
            _podcast_transcript.main(
                ["https://podcasts.apple.com/us/podcast/test/id1234567890?i=1000123456793"]
            )
        assert exc.value.code == 1


# ── Generic-RSS-feed tests (direct feed URL, no iTunes Lookup) ───────────────


class TestIsApplePodcastsURL:
    def test_true_for_apple_host(self) -> None:
        assert _podcast_transcript._is_apple_podcasts_url(
            "https://podcasts.apple.com/us/podcast/slug/id123?i=456"
        ) is True

    def test_true_for_subdomain(self) -> None:
        assert _podcast_transcript._is_apple_podcasts_url(
            "https://podcasts.apple.com/podcast/slug/id123"
        ) is True

    def test_false_for_rss_feed(self) -> None:
        assert _podcast_transcript._is_apple_podcasts_url(
            "https://example.com/feed.rss"
        ) is False

    def test_false_for_other_host(self) -> None:
        assert _podcast_transcript._is_apple_podcasts_url(
            "https://shows.acast.com/shows/foo/episodes/bar"
        ) is False

    def test_false_for_plain_http(self) -> None:
        assert _podcast_transcript._is_apple_podcasts_url(
            "https://example.com/ep42"
        ) is False


class TestFindEpisodeLatest:
    def test_returns_most_recent_by_pubdate(
        self, multi_item_feed: str, mocker: MockerFixture
    ) -> None:
        """episode_id=None → most recent <item> by <pubDate>, NOT document order.

        H4 lock: the feed's newest item is 2nd in document order, so a naive
        first-match implementation would return the wrong episode.
        """
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = multi_item_feed
        mock_get.return_value = mock_response

        result = _podcast_transcript.find_episode_in_feed(
            "https://example.com/feed.rss", None
        )
        assert result is not None
        episode_item, transcript_tags = result
        # The newest episode is "Newest Episode" (2nd in document order).
        title = episode_item.find("title")
        assert title is not None and title.text == "Newest Episode"
        assert len(transcript_tags) == 1
        assert transcript_tags[0].get("url") == "https://example.com/new.vtt"


class TestFindEpisodeSingleItem:
    def test_single_item_feed_returns_that_item(
        self, single_item_feed: str, mocker: MockerFixture
    ) -> None:
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = single_item_feed
        mock_get.return_value = mock_response

        result = _podcast_transcript.find_episode_in_feed(
            "https://example.com/single.rss", None
        )
        assert result is not None
        episode_item, transcript_tags = result
        title = episode_item.find("title")
        assert title is not None and title.text == "Only Episode"
        assert len(transcript_tags) == 1


class TestFetchTranscriptRSSFeed:
    def test_direct_feed_url_skips_itunes_lookup(
        self,
        mocker: MockerFixture,
        multi_item_feed: str,
        sample_vtt: str,
    ) -> None:
        """A direct RSS feed URL fetches the feed + transcript, never iTunes Lookup."""
        mock_get = mocker.patch("requests.get")

        def mock_get_side_effect(url, **kwargs):
            response = mocker.Mock()
            if "feed.rss" in url:
                response.text = multi_item_feed
            elif "new.vtt" in url:
                response.text = sample_vtt
            response.raise_for_status = mocker.Mock()
            return response

        mock_get.side_effect = mock_get_side_effect

        result = _podcast_transcript.fetch_transcript("https://example.com/feed.rss")

        # Generic-RSS path: no Apple IDs.
        assert result["show_id"] is None
        assert result["episode_id"] is None
        # No iTunes Lookup call was made.
        assert not any(
            "itunes.apple.com" in str(call)
            for call in mock_get.call_args_list
        )
        assert result["format"] == "vtt"
        assert "first caption" in result["markdown"]

    def test_direct_feed_no_transcript_raises(
        self,
        mocker: MockerFixture,
    ) -> None:
        """A feed whose latest item has no <podcast:transcript> → ValueError."""
        no_transcript_feed = """<?xml version="1.0"?>
<rss version="2.0">
  <channel>
    <title>No Transcript Podcast</title>
    <item>
      <title>Ep</title>
      <guid>x</guid>
      <pubDate>Wed, 03 Jul 2025 12:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>
"""
        mock_get = mocker.patch("requests.get")
        mock_response = mocker.Mock()
        mock_response.text = no_transcript_feed
        mock_get.return_value = mock_response

        with pytest.raises(ValueError, match="No transcript available"):
            _podcast_transcript.fetch_transcript("https://example.com/feed.rss")
