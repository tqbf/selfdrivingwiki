---
timestamp: 2026-10-10T120000Z
title: On-device speech transcription lands with fetcher-role audio acquisition
branch: feature/audio-speech-transcription
status: implemented-deterministic-gates-green
---

## Progress

# On-device speech transcription (fetcher role) — 2026-10-10

Branch `feature/audio-speech-transcription`. Explicit-only speech for
YouTube sources, per the approved plan.

## What landed

- **Fetcher-role correction.** The committed `audioTranscript` extractor
  kind is gone (kind case, backend kind, adapter case, prepare seam, MIME
  fallback arm, and the error case). The speech acquisition is the reviewed
  `org.selfdrivingwiki.audio-acquire` fetcher: manifest revision 4,
  protocol revision 5, no kinds, the synthetic
  `audio/x-wiki-audio-acquire` route, and a `source-bytes` result declaring
  `audio/mp4`. `ExtractorKindNeutralityContractTests.audioAcquireIsFetcherRoleData`
  keeps it that way.
- **Reviewed package from source.** `tools/audio-acquire/` (script, tests,
  README) generates `ExtractorPackages/AudioAcquire` via
  `scripts/sync-extractor-packages.sh` with lock and `--check` parity.
  yt-dlp 2026.08.19 + yt-dlp-ejs 0.8.0 pinned to the caption package's
  reviewed versions; metadata-only extraction under a socket-layer
  connection guard (watch host only for metadata, `.googlevideo.com`-suffix
  only for media, global-routable DNS validation, validated-IP connects
  with no second lookup, redirects/proxies/retries refused), one audio-only
  M4A format, 120 MiB + 1 read cap, 2-hour duration cap, `ftyp` check,
  atomic publication, fixed redacted failures. The pinned-library offline
  contract (`tests/_ytdlp_offline_contract.py`) runs plugin-guard and
  network-policy arms against the real tagged release.
- **Host speech floor.** `SpeechTranscribing` + `SystemSpeechTranscriber`
  over `SpeechAnalyzer`/`SpeechTranscriber` file input (macOS 26 target),
  typed readiness guidance, `AssetInventory` installation reachable only
  through the confirmed setup seam.
- **One queue item end to end.** The payload intent flows from both
  `providerID(for:)` and `execute(_:)`; both hosts dispatch the speech arm
  first (YouTube scope gate, active synthetic fetcher selection, engine
  readiness), then acquire → stage (0700/0600, flock lease, disk
  preflight) → analyze (injected engine, 45-minute analysis deadline) →
  persist ONE `.transcript` version with the typed host producer
  (`on-device-speech` technique, engine, locale, exact fetcher revision).
  One-job speech capacity bucket, 2 h 45 m speech wait bound (captions
  unchanged), transient bytes only — no blob, no follow-on format item.
- **Explicit UI action.** `Transcribe (on-device)` appears only on eligible
  YouTube sources, states its consequences in a confirmation dialog, and
  enqueues `.onDeviceSpeech` only after confirmation. Caption Transcribe
  stays caption-only; import paths never enqueue speech.
- **Gated real-engine checks.** `RealSpeechAnalyzerIntegrationTests`
  (gated by `WIKIFS_REAL_SPEECH=1`, `say` fixture, nonblocking subprocess)
  and `scripts/test-signed-speech.sh` (packaged app + bundled daemon,
  signature-verified, bounded typed result only).

## Verification

A live transcription on real hardware: the gated SwiftPM suite and the
signed-bundle script need a macOS 26 machine with the en-US model
installed, and a live YouTube download needs operator-approved network
access. The deterministic suites are the CI gate.
