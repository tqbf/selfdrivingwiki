# youtube-transcript

Standalone `uv` script (PEP 723 inline metadata) that fetches the captions
YouTube exposes for one video and outputs Markdown. The script has two
surfaces:

1. A CLI for interactive use.
2. A protocol revision 3 extractor entry point loaded by the reviewed
   `ExtractorPackages/YouTubeTranscript` package. This is the only path the
   app and the daemon use.

## CLI usage

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

Requires [uv](https://docs.astral.sh/uv/). The dependencies are declared in
the PEP 723 inline metadata block — `uv` resolves them automatically on
first run:

- `youtube-transcript-api>=1.0` — the primary retrieval route (MIT).
- `yt-dlp==2026.08.19` — the caption fallback (Unlicense).
- `yt-dlp-ejs==0.8.0` — the pinned release's matched external-JS solver
  components (MIT).

The fallback additionally needs a JavaScript runtime at or above Bun 1.2.11
(the pinned release's documented minimum). Interactive CLI use needs no Bun
— the CLI never invokes the fallback.

## Output formats

### Markdown (default)

```markdown
# YouTube Transcript: dQw4w9WgXcQ

Hello everyone welcome to the video. Today we are going to talk about how to build great software.
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
2. English variants (`en`, `en-US`, `en-GB`)
3. First available track of any language (via the track list)

The library prefers manually created captions over auto-generated ones.

## Exit codes (CLI)

| Code | Meaning                                      |
|------|----------------------------------------------|
| 0    | Success                                      |
| 1    | Network or unknown error                     |
| 2    | No transcript available for this video       |
| 3    | Transcripts disabled for this video          |
| 4    | Video unavailable (deleted, private, etc.)  |

## Extractor package protocol (revision 3)

The reviewed `ExtractorPackages/YouTubeTranscript` package serves ONE
request: a revision-3 `ExtractorProtocolRequest` JSON object on stdin and
JSON Lines frames on stdout, through the generated
`bin/youtube-transcript-extractor` entry point. The request carries one
validated HTTP(S) video URL (`remote-url` transport) and no input bytes.

Package-owned behavior:

- Strict URL normalization (watch, `youtu.be`, Shorts, embed, mobile) to a
  typed 11-character video ID. Non-YouTube hosts and invalid IDs are typed
  failures; the URL is never echoed.
- Named bounds that equal or tighten the manifest limits (request 1 MiB,
  output 32 MiB, 64 progress frames), incremental UTF-8 byte accounting per
  caption segment, and deadline checks before network access and at every
  processing seam.
- Atomic publication: the Markdown is written to a partial file and renamed
  into place; a failure leaves no partial output.
- Exactly one terminal frame. Failure messages are fixed strings that never
  contain the URL, video ID, upstream error text, or paths.
- Reported metadata: stable tool name, selected language, and the
  generated/manual status when the library exposes it.

The package never downloads media and never runs speech-to-text. A video
with no available captions is a typed failure. `youtube-transcript-api`
uses an undocumented YouTube interface that can change without notice, and
YouTube can block requests; both surface as bounded extraction failures.

### Caption fallback (protocol path)

When the primary route reports no caption track, disabled captions, or an
ordinary retrieval failure, the protocol path makes ONE yt-dlp attempt to
fetch the same captions' WebVTT subtitle bytes:

- The yt-dlp metadata call is pinned and reduced: `skip_download` (media is
  never saved), no playlist, no netrc, no cookie files, no browser cookies,
  no proxy inheritance, plugins disabled (`YTDLP_NO_PLUGINS=1`), remote
  components refused, and every retry ceiling at zero — a known 429 or IP
  block is never retried.
- The JS runtime is exactly the host-resolved Bun passed through the
  operation-configuration file (`js_runtimes={'bun': {'path': …}}`); with
  no grant the fallback reports a fixed setup failure and never searches a
  `PATH` (the library's default Deno lookup is disabled with an empty
  runtime table).
- Subtitle bytes are fetched through the package's own bounded opener, not
  `YoutubeDL.urlopen`: HTTPS on port 443 at `www.youtube.com` only,
  automatic redirects disabled with at most two manually re-validated
  hops, `Accept-Encoding: identity` with compressed responses refused, and
  a limit-plus-one read that rejects oversized payloads.
- A listed track is not proof of access. The transcript publishes only
  when actual WebVTT bytes arrive and parse; the result frame's
  `toolName`/`toolVersion` names the route that produced the bytes
  (`youtube-transcript` 1.2.0, or `yt-dlp` at its pinned release).
- Blocked requests, invalid requests, expired deadlines, conversion
  failures, output-limit failures, and publication failures never invoke
  the fallback.

YouTube URL imports auto-transcribe at import like the podcast routes:
the bundled import-transcription policy covers the caption routes
(podcast, Apple Podcasts, YouTube). Speech-to-text transcription for
caption-less videos is a separate, explicit-only feature — see
`plans/audio-speech-transcription.md`.

See `docs/architecture/extractor-script-protocol.md` and
`plans/youtube-transcript-extractor-package.md`.

## Testing

```bash
cd tools/youtube-transcript
mise exec -- uv run pytest tests/ -v        # all tests (mocked — no YouTube calls)
mise exec -- uv run ruff format --check .
mise exec -- uv run ruff check .
mise exec -- uv run pyright
```

The package under `ExtractorPackages/YouTubeTranscript/` is generated by
`scripts/sync-extractor-packages.sh` from this script — never edit the
generated bytes by hand.
