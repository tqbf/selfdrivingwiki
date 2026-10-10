# On-device speech transcription (STT) for caption-less sources

Status: planned. Revised after independent review (sol model, REQUEST
CHANGES round 1 — all five blockers addressed in this revision).

## Problem

The reviewed caption packages cover only videos YouTube attached tracks
to. A public talk with no captions — e.g. `Wiy2TLAij4s`, "01 Peter
Norvig Keynote" — fails with the typed "no caption track is available
for this video" frame, and there is no path to a transcript. Speech-to-
text closes that gap.

## Policy (operator decision, load-bearing)

- **Caption-based transcription may run automatically at import.** The
  bundled `routeImportTranscription` policy covers the caption routes
  (podcast, Apple Podcasts, YouTube).
- **Speech-to-text is explicit-only, permanently.** STT downloads media
  and burns minutes of compute; it must never run at import, never
  appear in either bundled policy table (`routeImportTranscription` OR
  `routeAutoExtraction`), and never be triggered automatically by
  another route's failure — including a failed captions job. The only
  trigger is a direct user action carrying an explicit persisted
  intent.

Enforcement: the invariant test lands in the SAME change that
introduces the STT kind (no chicken-and-egg), and asserts absence from
BOTH tables, that importing each claimed MIME with the speech package
active enqueues zero speech work, and that a failed captions job never
enqueues a speech-intent item.

## Engine decision (operator decision)

Apple Speech, on device — `SpeechAnalyzer` / `SpeechTranscriber`
(macOS 26 SDK), as a Swift host execution floor (operator-approved).
On-device only: the floor never configures a network recognizer.
Authorization is a RUNTIME VERIFICATION, not an assumption: the
implementation compiles against the macOS 26 SDK, exercises file
transcription inside the signed SwiftPM-built app, and surfaces any
authorization/model-asset failure as a typed readiness state. No
`SFSpeechRecognizer` permission assumptions carry over.

## Architecture

Two parts and one explicit trigger:

1. **Audio acquisition — reviewed extractor package.**
   `org.selfdrivingwiki.audio-acquire`, protocol revision 3 `remote-url`,
   kind `audio-transcript` (a NEW ExtractorKind — see the migration
   checklist), v1 claims `video/youtube` ONLY; podcast feeds are a
   follow-up (a feed URL is not an episode enclosure — enclosure
   resolution and redirect validation are their own work).

   Contract: with the SAME hardening as the caption fallback (pinned
   yt-dlp + ejs, plugins/cookies/proxies/retries disabled, Bun grant),
   select the audio-only M4A stream (`bestaudio[ext=m4a]`, fallback
   format 140) — AAC-LC in an MP4/M4A container. NO transcode and NO
   ffmpeg anywhere: Core Audio (`AVAudioFile`) decodes AAC/M4A natively
   in the Swift floor, which deletes the decode-dependency question.

   Bounds, all enforced by the package before and during download:
   - Pre-download duration check from yt-dlp metadata: reject > 2 h
     (`unsupported-input`, fixed frame).
   - Bounded download: limit-plus-one read against a 120 MiB cap —
     deliberately BELOW the manifest's 128 MiB
     `maximumMarkdownOutputByteCount`, so the existing extractor
     protocol result path carries the file unchanged. The result frame
     is the existing markdown-result shape; its byte count is the
     audio byte count, and the ONLY consumer of the bytes is the
     speech arm. The result is never rendered as markdown.
   - M4A sanity check on the bytes (`ftyp` box present) before
     emitting success.

2. **Transcription — host execution floor (Swift).**
   `SpeechTranscribing` seam wrapping `SpeechAnalyzer`:
   `AVAudioFile` (Core Audio decodes the M4A/AAC) → transcript
   segments + detected locale. The floor owns a typed readiness state
   (authorization, language-asset availability) surfaced as setup
   guidance, per the runtime-verification rule above.

3. **Orchestration — one queue arm with a persisted intent.**
   The extraction queue payload gains a TYPED intent
   (`QueueItemPayload` extension: `.captions` default | `.speech`),
   persisted with the item and validated by BOTH the app and daemon
   providers. Import enqueues the default captions intent; the
   explicit UI action enqueues the speech intent. Worker resolution
   routes on the intent: speech intent → resolve the audio-acquire
   package (normal selection state machine), run it, hand the staged
   audio to the speech floor, then persist — one queue item, one
   terminal persistence, mirroring how the Apple package's
   TTML/RSS choice stays inside one arm. A source-only enqueue always
   means captions; speech can never arise from intent-less dispatch.

4. **Lifecycle, deadlines, cancellation.**
   - Acquisition runs inside the package process under the manifest's
     30-minute process limit.
   - The speech stage runs host-side with its OWN deadline and
     cooperative-cancellation propagation into both yt-dlp (acquisition
     cancel) and the analyzer; queue wait-policy and UI waiting use the
     speech deadline, not the 35-minute caption default.
   - The staged audio file is written to a speech-stage directory the
     HOST owns (not the package operation root, whose `deinit` bounds
     package lifetime) and is removed in a `defer` on every terminal
     path: success, error, cancel, and crash recovery sweep.
   - Disk preflight before download: free space ≥ 2× the expected
     audio size; download and decoded-AAC caps are independent.

5. **UX — a distinct explicit action.** "Transcribe (on-device)" as a
   separate affordance (Re-transcribe menu item + prominent CTA on a
   source whose captions attempt ended in the no-track failure). Never
   fired by import, never fired as an automatic fallback.

## New-kind migration checklist (finding 3)

Adding `ExtractorKind.audioTranscript` is a contract change, not just a
manifest row. The implementation must enumerate and touch:

- `ExtractorContractTypes` kind allowlist; `ContentTypeRegistry` kind +
  capabilities — with `shouldAutoIngest`-style automatic ingest
  deliberately FALSE, and no `routeAutoExtraction` /
  `routeImportTranscription` entry (the policy invariant).
- `ExtractorPackagePluginDefinitionFactory`: backendKind mapping +
  adapter switch arm; typed `prepareAudioAcquire` API on the provider.
- Registry presentation, route selection + bundled default for
  `video/youtube` pointing at the new package.
- App AND daemon queue routing on the persisted intent.
- `ExtractorKindNeutralityContractTests` coverage for the new kind, and
  the speech-eligibility logic carried by the intent + registration
  data — never a `kind == .audioTranscript` production branch.

## Provenance (finding 9)

The speech transcript does NOT use the `.installedPackage` producer
mode — that would misattribute host-engine work to the acquisition
package. A typed speech producer records: technique `on-device-speech`,
the host engine/locale (where Speech exposes them), and the acquiring
package's exact revision identity separately. No `wantsAgentCleanup`
claim in v1 (STT output is already normalized text; cleanup is a later
decision).

## Failure and bound rules

Same discipline as the caption package: fixed redacted frames; one
attempt; blocked requests never retried; upstream text discarded.
Typed causes: blocked/429 (acquisition), over-duration, over-size,
malformed container (no `ftyp`), speech model unavailable, locale
unsupported, no speech detected, disk preflight failure.

## Testing strategy

- **Engine seam**: `SpeechTranscribing` is protocol-injected;
  deterministic unit tests use a scripted engine.
- **Real-speech integration (gated)**: synthesize speech at runtime
  with the macOS `say` CLI (`say -o fix.aiff "…known sentence…"`,
  non-blocking subprocess pattern with a timeout) and run the REAL
  floor over it — `AVAudioFile` reads AIFF directly, so no conversion
  is needed; assert a fuzzy match. Availability-checked (voice/locale/
  speech assets), and explicitly NOT network-free on first run (the
  language asset may download). Deterministic injected-engine tests
  remain the CI gate; the `say` test is a gated integration suite.
- **Policy invariant**: same-change test — no STT record in either
  policy table; import per claimed MIME with the package active
  enqueues zero speech work; failed captions never enqueue speech
  intent.
- **Intent + resolution**: payload intent round-trip; both providers
  route by intent; source-only enqueue always means captions.
- **Acquisition**: Python suite with mocked network + protocol-smoke
  fixture; live audio download is an operator-approved manual check.

## Risks

- `SpeechAnalyzer` authorization/asset quirks on specific builds —
  typed readiness probe, surfaced as setup guidance.
- Long talks: chunked transcription with progress through the existing
  queue progress frames.
- yt-dlp audio acquisition can hit the same blocks as caption
  metadata; never-retry-after-block applies.
- Disk pressure: preflight + caps above; concurrency capped at one
  speech job.

## Out of scope

Podcast-feed enclosures (v2 — needs enclosure resolution), speaker
diarization, timestamps in output, non-Mac platforms, and any network
speech path.
