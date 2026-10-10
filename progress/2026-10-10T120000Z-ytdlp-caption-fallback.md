---
timestamp: 2026-10-10T120000Z
title: yt-dlp caption fallback for the reviewed YouTube package
branch: feature/youtube-auto-transcript-cleanup
status: complete
---

# yt-dlp caption fallback for the reviewed YouTube package

## Progress

The reviewed YouTube transcript package (now 1.2.0) gained a caption
fallback: when the primary `youtube-transcript-api` route fails with an
ELIGIBLE failure — no advertised track, disabled captions, or an ordinary
retrieval error — the package makes ONE yt-dlp attempt to fetch the same
captions' WebVTT subtitle bytes. A listed track is never success; the
transcript publishes only when actual bytes arrive and parse. The result
frame's `toolName`/`toolVersion` names the route that produced the bytes
(`youtube-transcript` 1.2.0, or `yt-dlp` 2026.08.19).

Fallback hardening, all pinned against the tagged release source:

- `yt-dlp==2026.08.19` + `yt-dlp-ejs==0.8.0` in the PEP 723 block; the
  offline contract test runs the REAL library under exactly those pins.
- `YTDLP_NO_PLUGINS=1` (verified against the release's `load_plugins`),
  remote components refused, no netrc/cookies, no proxy inheritance, every
  retry ceiling at zero — a known 429 or IP block is never retried, and
  blocked primaries never reach the fallback at all.
- Subtitle bytes go through the package's own bounded opener, never
  `YoutubeDL.urlopen`: HTTPS port 443 at `www.youtube.com` only, automatic
  redirects disabled with at most two manually re-validated hops,
  `Accept-Encoding: identity`, a limit-plus-one read, and a WebVTT parser
  that collapses rolling auto-caption lines to their delta.

The host side grants the pinned release's JavaScript runtime requirement
(Bun ≥ 1.2.11, matching `BunJsRuntime.MIN_SUPPORTED_VERSION`) to the exact
reviewed revision only. A new typed operation-configuration case
(`reviewed-youtube-bun-runtime`) carries one absolute, login-shell-resolved
Bun path; preparation resolves and version-probes it once, execute
rechecks the identity, and a missing or unsupported runtime is a retained
failure that blocks only the fallback — never readiness or the primary
route.

Import policy flipped to explicit-only for YouTube: a new bundled
`routeImportTranscription` table (separate from HTML's
`routeAutoExtraction`) covers the two podcast routes and deliberately not
`youtube-transcript`, and the store's import signal now requires BOTH the
active registration claim and the route entry. A YouTube URL import
enqueues zero extraction jobs; the Transcribe action enqueues exactly one.

## Verification

- `tools/youtube-transcript`: 176 pytest tests pass, including
  `test_ytdlp_fallback_success`, `test_ytdlp_fallback_eligibility`,
  `test_ytdlp_failure_matrix`, `test_ytdlp_redaction_and_bounds`,
  `test_real_ytdlp_offline_contract` and the real-library plugin guard
  (both run the pinned PEP 723 environment under `uv run --script`);
  `ruff format --check`, `ruff check`, and `pyright` are clean.
- `swift test` filtered suites: route policy, auxiliary runtime (real
  `--version` probes accept 1.2.11 and reject 1.2.10/1.0.31), operation
  support envelope round-trips, YouTube provider arms (primary + yt-dlp
  provenance, app and daemon), reviewed-package goldens, and the hosted
  Add-URL-vs-Transcribe scenario all pass.
- Regenerated `ExtractorPackages/YouTubeTranscript` at 1.2.0 with the
  `extractor-package-tool validate` digest pinned in
  `ReviewedExtractorPackages` and the protocol-smoke fixtures replayed.

## Limitations

The first live validation ran against a real queue job (video
`Wiy2TLAij4s`, "01 Peter Norvig Keynote", public, 20:12). The full chain
worked in production — the host granted Bun, the package read the
operation configuration, the pinned yt-dlp returned metadata, and the
selection found no tracks — and the queue item failed with exactly the
typed frame "no caption track is available for this video". The video
genuinely has no captions: four player clients across two yt-dlp
releases (the pinned 2026.08.19 and the system 2026.07.04) all report
zero subtitle and zero automatic-caption tracks. So the live run
validated the grant → metadata → selection → typed-failure path; the
byte-fetch leg is still only covered by the offline contract fixture
until a caption-bearing video is transcribed. Caption-less videos are a
correct typed outcome for this package: the boundary is captions-only —
no media download, no speech-to-text — so a video YouTube offers no
tracks for has nothing this package can fetch.

