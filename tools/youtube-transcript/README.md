# youtube-transcript

Standalone `uv` script (PEP 723 inline metadata) that fetches YouTube video
transcripts and outputs markdown to stdout. Mirrors the `tools/pdf2md/pdf2md`
pattern.

The Swift `YouTubeTranscriptService` spawns it as a subprocess, replacing the
fragile `ytInitialPlayerResponse` watch-page scrape (#584).

## Usage

```bash
uv run --script youtube-transcript <video-id-or-url> [--lang en] [--json] [--output file.md] [--timestamps]
```

Accepts a video ID (`dQw4w9WgXcQ`) or a URL:

- `youtube.com/watch?v=...`
- `youtu.be/...`
- `youtube.com/shorts/...`
- `youtube.com/embed/...`

### Examples

```bash
# Raw video ID, markdown to stdout
uv run --script youtube-transcript dQw4w9WgXcQ

# URL input, with timestamps
uv run --script youtube-transcript https://youtu.be/dQw4w9WgXcQ --timestamps

# JSON output with segments
uv run --script youtube-transcript dQw4w9WgXcQ --json

# Write to file
uv run --script youtube-transcript dQw4w9WgXcQ -o transcript.md

# Preferred language
uv run --script youtube-transcript dQw4w9WgXcQ --lang es
```

## Installation

Requires [uv](https://docs.astral.sh/uv/):

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

The `youtube-transcript-api` dependency is declared in the PEP 723 inline
metadata block — `uv` resolves it automatically on first run.

## Output formats

### Markdown (default)

```markdown
# YouTube Transcript: dQw4w9WgXcQ

Hello everyone welcome to the video. Today we are going to talk about how to build great software.
```

With `--timestamps`:

```markdown
# YouTube Transcript: dQw4w9WgXcQ

[00:00] Hello everyone welcome to the video.
[00:03] Today we are going to talk about
[00:05] how to build great software.
```

### JSON (`--json`)

```json
{
  "video_id": "dQw4w9WgXcQ",
  "language": "en",
  "segments": [
    {"text": "Hello everyone welcome to the video.", "start": 0.0, "duration": 3.5},
    {"text": "Today we are going to talk about", "start": 3.5, "duration": 2.0}
  ],
  "markdown": "# YouTube Transcript: dQw4w9WgXcQ\n\n..."
}
```

## Language preference

The script tries, in order:

1. Requested language (default `en`)
2. English manual captions (`en`, `en-GB`)
3. English ASR (`en-US` generated)
4. First available track of any language (via `list_transcripts`)

## Exit codes

| Code | Meaning                                      |
|------|----------------------------------------------|
| 0    | Success                                      |
| 1    | Network or unknown error                     |
| 2    | No transcript available for this video       |
| 3    | Transcripts disabled for this video          |
| 4    | Video unavailable (deleted, private, etc.)  |

## Testing

```bash
uv run pytest tests/ -v          # all tests (mocked — no YouTube calls)
uv run ruff check youtube-transcript tests/
uv run pyright youtube-transcript tests/
```

## Swift integration

After this tool lands, `YouTubeTranscriptService` spawns the script as a
subprocess instead of scraping the watch page. The generalization PR (#809)
already routes YouTube through `transcribe(sourceID:)` — this tool just swaps
the fetch backend. See plans/youtube-transcript-tool.md for details.

## Plan

### Summary

Create `tools/youtube-transcript/youtube-transcript` — a standalone uv script
(PEP 723 inline metadata) that fetches YouTube video transcripts and outputs
markdown to stdout. Mirrors the `tools/pdf2md/pdf2md` pattern exactly.

The Swift `YouTubeTranscriptService` will spawn it as a subprocess, replacing
the fragile `ytInitialPlayerResponse` watch-page scrape (#584).

### Reference code

- **pdf2md pattern** (`tools/pdf2md/pdf2md`): `#!/usr/bin/env -S uv run --script`
  with `# /// script` inline metadata block. Takes file input, outputs markdown
  to stdout, exit codes for error types.
- **groundedllm** (`hayhooks/components/youtube_transcript.py`): video ID
  extraction, `youtube_transcript_api` usage, language preference logic, error
  handling for `NoTranscriptFound` / `TranscriptsDisabled` / `VideoUnavailable`.
- **groundedllm** (`hayhooks/components/content_extraction.py`): URL routing
  patterns, content fetching, resolver patterns.

### Deliverables

1. **The script:** `tools/youtube-transcript/youtube-transcript` — PEP 723
   inline metadata, `youtube-transcript-api>=1.0` dependency.
2. **Tests:** `tools/youtube-transcript/tests/` — unit tests with mocked
   `YouTubeTranscriptApi` (no real YouTube calls in CI).
3. **Project config:** `tools/youtube-transcript/pyproject.toml` — dev
   dependencies only (runtime deps in PEP 723 inline block).
4. **Docs:** `tools/youtube-transcript/README.md`.
5. **Gitignore:** `tools/youtube-transcript/.gitignore`.

### Acceptance criteria

- **AC.1**: `uv run --script youtube-transcript dQw4w9WgXcQ` outputs markdown to
  stdout with exit 0 (tested with mock, not real network).
- **AC.2**: URL inputs are parsed to video IDs (watch, shorts, youtu.be, embed).
- **AC.3**: Language preference tries manual -> ASR -> first available.
- **AC.4**: `--json` outputs structured JSON with segments.
- **AC.5**: Exit codes: 0 success, 1 unknown, 2 no transcript, 3 disabled,
  4 unavailable.
- **AC.6**: `uv run pytest tests/` passes with mocked YouTube API.
- **AC.7**: `uv run ruff check youtube-transcript tests/` clean.
- **AC.8**: `uv run pyright youtube-transcript tests/` clean.
