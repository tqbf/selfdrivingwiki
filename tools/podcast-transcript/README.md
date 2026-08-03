# Plan: Podcast Transcript Tool (uv standalone script)

## Summary

Create `tools/podcast-transcript/podcast-transcript` — a standalone uv script
(PEP 723 inline metadata) that fetches podcast transcripts via RSS
`<podcast:transcript>` tags (Podcasting 2.0 spec). No Apple FairPlay dependency.
Mirrors the `tools/pdf2md/pdf2md` pattern.

## Approach (from research)

Apple's AMP transcript API requires FairPlay-signed tokens — ruled out for
cross-platform use. Instead:

1. Parse Apple Podcasts URL → extract show ID (`id1234567890`) + episode ID (`?i=1000123456789`)
2. Call iTunes Lookup API: `https://itunes.apple.com/lookup?id={show_id}&entity=podcast` → get `feedUrl` (RSS URL)
3. Download RSS feed, parse with `xml.etree.ElementTree`
4. Find the episode matching the episode ID (match on `<guid>`, `<link>`, or iTunes episode ID)
5. Check for `<podcast:transcript>` tags (namespace: `https://podcastindex.org/namespace/1.0`)
6. Download transcript file (VTT, SRT, HTML, or plain text)
7. Parse format → extract text → output markdown to stdout

Optional `--transcribe` fallback: download audio from `<enclosure url>` and
transcribe with `faster-whisper`. Heavy — not in default deps.

## Deliverables

### 1. The script: `tools/podcast-transcript/podcast-transcript`

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12,<3.14"
# dependencies = [
#     "requests>=2.31",
#     "webvtt-py>=0.5",
#     "srt>=3.5",
# ]
# ///
```

**CLI interface:**
```
uv run --script podcast-transcript <apple-podcasts-url> [--json] [--output file.md]
uv run --script podcast-transcript <apple-podcasts-url> --transcribe  # Whisper fallback
```

**Input:** Apple Podcasts episode URL:
- `https://podcasts.apple.com/us/podcast/slug/id1234567890?i=1000123456789`
- Extract show ID via regex: `r'/id(\d+)'`
- Extract episode ID via regex: `r'[?&]i=(\d+)'`

**Behavior:**
1. iTunes Lookup API → `feedUrl` (RSS URL). If missing → exit 3.
2. Download RSS, parse with ElementTree.
3. Find episode matching episode ID. Match strategies (in order):
   - `<guid>` containing the episode ID
   - `<link>` containing the episode ID
   - `<itunes:episode>` attribute matching
4. Check for `<podcast:transcript>` tags in the episode item.
5. Download transcript, detect format by `type` attribute or file extension.
6. Parse:
   - `text/vtt` → `webvtt` library → extract text blocks
   - `application/x-subrip` → `srt` library → extract text blocks
   - `text/html` → strip tags, extract text
   - `text/plain` → use directly
7. Output markdown:
   ```markdown
   # Podcast Transcript

   <transcript text here, paragraphs joined by newlines>
   ```
8. If `--json`: `{"show_id": "...", "episode_id": "...", "language": "...", "format": "vtt", "markdown": "..."}`

**Transcription fallback (`--transcribe`):**
- Only if no RSS transcript found
- Download audio from `<enclosure url>`
- Transcribe with `faster-whisper` (base model, CPU, int8)
- Add `faster-whisper` to `--with` flag: `uv run --script podcast-transcript --with faster-whisper <url> --transcribe`
- NOT in default PEP 723 deps (too heavy)

**Error handling:**
- iTunes Lookup fails or no feedUrl → exit 3, stderr "Podcast not found"
- Episode not found in RSS → exit 4, stderr "Episode not found in feed"
- No `<podcast:transcript>` tag and no `--transcribe` → exit 1, stderr "No transcript available (use --transcribe for audio transcription)"
- Network errors → exit 1, stderr with exception message
- Success → exit 0

### 2. Tests: `tools/podcast-transcript/tests/`

- `test_podcast_transcript.py` — unit tests with mocked HTTP (no real network):
  - URL parsing (show ID + episode ID extraction)
  - iTunes Lookup API response parsing
  - RSS `<podcast:transcript>` tag extraction
  - VTT → markdown conversion
  - SRT → markdown conversion
  - HTML → text conversion
  - Episode matching (guid, link, itunes:episode)
  - Error exit codes
- `conftest.py` — fixtures with sample RSS XML, VTT, SRT data
- `test_integration.py` — marked `@pytest.mark.skip` (needs real podcast URL)

### 3. Project config: `tools/podcast-transcript/pyproject.toml`

```toml
[project]
name = "podcast-transcript"
version = "0.1.0"
requires-python = ">=3.12,<3.14"

[dependency-groups]
dev = [
    "pytest>=8",
    "pytest-mock>=3",
    "ruff>=0.11",
    "pyright>=1.1",
]
```

### 4. Docs: `tools/podcast-transcript/README.md`

### 5. `.gitignore`: `tools/podcast-transcript/.gitignore`

## Acceptance criteria

- **AC.1**: URL parsing extracts show ID and episode ID from Apple Podcasts URLs.
- **AC.2**: iTunes Lookup API call returns feedUrl (tested with mock).
- **AC.3**: RSS parsing finds `<podcast:transcript>` tags in the correct episode.
- **AC.4**: VTT transcripts parse to clean text.
- **AC.5**: SRT transcripts parse to clean text.
- **AC.6**: HTML transcripts strip tags to clean text.
- **AC.7**: Markdown output to stdout with exit 0.
- **AC.8**: `--json` outputs structured JSON.
- **AC.9**: Exit codes: 0 success, 1 no transcript, 3 podcast not found, 4 episode not found.
- **AC.10**: `uv run pytest tests/` passes with mocked responses.
- **AC.11**: `uv run ruff check podcast-transcript tests/` clean.
