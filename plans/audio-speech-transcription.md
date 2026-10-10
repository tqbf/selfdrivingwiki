# On-device speech transcription (STT) for caption-less sources

Status: planned. Engine decision made (Apple Speech, on-device). Policy
decision made (STT is explicit-only, never automatic). Not started.

## Problem

The reviewed caption packages cover only videos YouTube attached tracks
to. A public talk with no captions — e.g. `Wiy2TLAij4s`, "01 Peter
Norvig Keynote" — fails with the typed "no caption track is available
for this video" frame, and there is no path to a transcript. Speech-to-
text closes that gap for every audio-bearing source: YouTube embeds,
podcast feeds, and later any audio-bearing source type.

## Policy (operator decision, load-bearing)

- **Caption-based transcription may run automatically at import.** The
  bundled `routeImportTranscription` policy covers the caption routes
  (podcast, Apple Podcasts, YouTube).
- **Speech-to-text is explicit-only, permanently.** STT downloads media
  and burns minutes of compute; it must never run at import, never
  appear in `routeImportTranscription`, and never be triggered by
  another route's failure automatically. The only trigger is a direct
  user action on a source.

This policy is a tested invariant: the bundled-policy tests assert the
STT kind has no import-policy entry, so "helpfully" adding one later
fails a gate.

## Engine decision (operator decision)

Apple Speech, on device — `SpeechAnalyzer` / `SpeechTranscriber`
(macOS 26 SDK). Rationale: the app is native Swift, the SDK is already
macOS 26; on-device transcription is free and private, needs no Python
environment, no ffmpeg, and no model zoo (the per-language model
installs on demand through Apple's asset system). Quality on clear
English talks is good. whisper/MLX or a cloud API remain future
alternatives if quality or language coverage demands.

## Architecture

Two moving parts, joined by an explicit user action:

1. **Audio acquisition — reviewed extractor package.**
   `org.selfdrivingwiki.audio-acquire`, protocol revision 3, role
   extractor, kind `audio-transcript`, claiming `video/youtube` and
   `audio/podcast`. Contract: download the AUDIO-ONLY stream for the
   validated source URL (yt-dlp pinned release, same hardening as the
   caption fallback — plugins/cookies/proxies/retries disabled, Bun
   grant if the pinned release requires it), write the decoded audio to
   `outputPath` as 16 kHz mono PCM WAV (decode via the pinned
   release's ffmpeg dependency or ffmpeg-free pure-Python decode — to
   be settled at implementation), bounded duration and byte caps. The
   manifest declares `network` (+ whatever the decode path needs). It
   never transcribes and never runs in the background.

2. **Transcription — host execution floor (Swift).**
   A `SpeechTranscribing` seam wrapping `SpeechAnalyzer`: audio in
   (file), transcript segments + language out. Like the PDF/HTML host
   floors, it is host code, not a package; the package boundary stays
   Python-only. The floor needs microphone-free usage
   (`SFSpeechRecognizer`-era authorization does not apply to file
   transcription on 26; verify at implementation and surface any
   permission prompt as a typed readiness state).

3. **Orchestration — one queue arm, two stages, explicit trigger.**
   A new extraction provider arm `speechTranscribe(sourceID:)`:
   resolve the audio-acquire package through the normal selection
   state machine, run it (network), run the speech floor over the
   staged WAV, then write the transcript through the durable
   `.transcript` provenance path with technique
   `on-device-speech`. The staged audio lives only inside the
   operation root and dies with it. The captions package is untouched.

4. **UX — a distinct explicit action.** Sources whose captions fail
   (or that have no captions) surface "Transcribe (on-device)" as a
   separate affordance from the captions Transcribe button — a menu
   item under the existing Re-transcribe control plus a prominent CTA
   on caption-less sources after a no-track failure. Never fired by
   import, never fired as an automatic fallback of a failed captions
   job.

## Failure and bound rules (same discipline as the caption work)

- Fixed, redacted frames: acquisition failures (blocked, 429, denied)
  and speech failures (model unavailable, unsupported locale, no
  speech detected) map to bounded typed causes; upstream text is
  discarded.
- One attempt; blocked requests never retry.
- Bounds: audio duration capped (2 h), WAV bytes capped (2 h x
  32 kB/s ~= 2 GiB upper bound — tune down), transcript bounded by the
  existing output cap.
- On-device only: the floor never configures a network speech
  recognizer, so no audio leaves the machine even if Apple offers a
  server path.

## Testing strategy

- **Engine seam**: `SpeechTranscribing` is protocol-injected;
  unit tests use a scripted engine.
- **Real-speech fixture**: tests synthesize speech with the macOS `say`
  CLI into a temp audio file at runtime (`say -o fix.aiff "…known
  sentence…"`), then run the REAL floor over it and assert a fuzzy
  match of the sentence — a genuine on-device integration test with no
  network and no bundled audio assets.
- **Policy invariant**: bundled-policy tests assert no
  `routeImportTranscription` entry names the STT kind (permanent gate
  against "helpful" automation).
- **Acquisition**: the package's Python suite with mocked network (the
  caption suite's harness pattern) plus a protocol-smoke fixture; live
  audio download is an operator-approved manual check.
- **Hosted UX scenario**: the explicit action enqueues exactly one STT
  job; import enqueues zero STT jobs (the existing hosted harness).

## Risks

- `SpeechAnalyzer` availability/authorization quirks on specific
  builds; mitigate with a typed readiness probe surfaced as setup
  guidance.
- Long talks: transcribe in chunks with progress reporting through the
  existing queue progress frames.
- yt-dlp audio acquisition can hit the same blocks as caption
  metadata; the same never-retry-after-block rule applies.
- The decode dependency (ffmpeg vs pure-Python WAV decode of a
  pre-muxed format) is the one open implementation question; settle it
  first, since it decides the package's dependency footprint.

## Out of scope

Podcast-feed episode audio reuse from existing caches, speaker
diarization, timestamps in output, and non-Mac platforms.
