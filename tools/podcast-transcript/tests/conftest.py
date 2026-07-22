"""Shared fixtures for podcast-transcript tests."""

from __future__ import annotations

import pytest

# ── Sample RSS feed with podcast:transcript tags ────────────────────────────

_SAMPLE_RSS_FEED = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <channel>
    <title>Test Podcast</title>
    <item>
      <title>Episode 1</title>
      <guid>https://example.com/episode/1000123456789</guid>
      <link>https://example.com/episode/1000123456789</link>
      <itunes:episode>1000123456789</itunes:episode>
      <podcast:transcript url="https://example.com/transcript1.vtt" type="text/vtt" lang="en"/>
    </item>
    <item>
      <title>Episode 2</title>
      <guid>https://example.com/episode/1000123456790</guid>
      <link>https://example.com/episode/1000123456790</link>
      <itunes:episode>1000123456790</itunes:episode>
      <podcast:transcript url="https://example.com/transcript2.srt"
                        type="application/x-subrip" lang="en"/>
    </item>
    <item>
      <title>Episode 3</title>
      <guid>https://example.com/episode/1000123456791</guid>
      <link>https://example.com/episode/1000123456791</link>
      <itunes:episode>1000123456791</itunes:episode>
      <podcast:transcript url="https://example.com/transcript3.html" type="text/html" lang="en"/>
    </item>
    <item>
      <title>Episode 4</title>
      <guid>https://example.com/episode/1000123456792</guid>
      <link>https://example.com/episode/1000123456792</link>
      <itunes:episode>1000123456792</itunes:episode>
      <podcast:transcript url="https://example.com/transcript4.txt" type="text/plain" lang="en"/>
    </item>
    <item>
      <title>Episode 5 - No Transcript</title>
      <guid>https://example.com/episode/1000123456793</guid>
      <link>https://example.com/episode/1000123456793</link>
      <itunes:episode>1000123456793</itunes:episode>
    </item>
  </channel>
</rss>
"""

# ── Sample VTT transcript ─────────────────────────────────────────────────────

_SAMPLE_VTT = """WEBVTT

00:00:00.000 --> 00:00:05.000
This is the first caption.

00:00:05.000 --> 00:00:10.000
This is the second caption.

00:00:10.000 --> 00:00:15.000
This is the third caption with multiple lines.
"""

# ── Sample SRT transcript ─────────────────────────────────────────────────────

_SAMPLE_SRT = """1
00:00:00,000 --> 00:00:05,000
This is the first subtitle.

2
00:00:05,000 --> 00:00:10,000
This is the second subtitle.

3
00:00:10,000 --> 00:00:15,000
This is the third subtitle.
"""

# ── Sample HTML transcript ────────────────────────────────────────────────────

_SAMPLE_HTML = """<!DOCTYPE html>
<html>
<body>
<h1>Transcript</h1>
<p>This is the first paragraph of the transcript.</p>
<p>This is the second paragraph.</p>
<p>This is the third paragraph with some <strong>bold</strong> text.</p>
<script>console.log('ignore this');</script>
<style>body { color: black; }</style>
</body>
</html>
"""

# ── Sample plain text transcript ─────────────────────────────────────────────

_SAMPLE_PLAIN = """This is the first paragraph of the transcript.

This is the second paragraph.

This is the third paragraph.
"""

# ── iTunes Lookup API response ───────────────────────────────────────────────

_ITUNES_LOOKUP_RESPONSE = {
    "resultCount": 1,
    "results": [
        {
            "collectionId": 1234567890,
            "collectionName": "Test Podcast",
            "feedUrl": "https://example.com/feed.rss",
        }
    ],
}

_ITUNES_LOOKUP_NO_RESULTS = {
    "resultCount": 0,
    "results": [],
}

_ITUNES_LOOKUP_NO_FEED_URL = {
    "resultCount": 1,
    "results": [
        {
            "collectionId": 1234567890,
            "collectionName": "Test Podcast",
        }
    ],
}


@pytest.fixture
def sample_rss_feed() -> str:
    """Sample RSS feed with podcast:transcript tags."""
    return _SAMPLE_RSS_FEED


@pytest.fixture
def sample_vtt() -> str:
    """Sample VTT transcript."""
    return _SAMPLE_VTT


@pytest.fixture
def sample_srt() -> str:
    """Sample SRT transcript."""
    return _SAMPLE_SRT


@pytest.fixture
def sample_html() -> str:
    """Sample HTML transcript."""
    return _SAMPLE_HTML


@pytest.fixture
def sample_plain() -> str:
    """Sample plain text transcript."""
    return _SAMPLE_PLAIN


@pytest.fixture
def itunes_lookup_response() -> dict:
    """Successful iTunes Lookup API response."""
    return _ITUNES_LOOKUP_RESPONSE


@pytest.fixture
def itunes_lookup_no_results() -> dict:
    """iTunes Lookup API response with no results."""
    return _ITUNES_LOOKUP_NO_RESULTS


@pytest.fixture
def itunes_lookup_no_feed_url() -> dict:
    """iTunes Lookup API response without feedUrl."""
    return _ITUNES_LOOKUP_NO_FEED_URL
