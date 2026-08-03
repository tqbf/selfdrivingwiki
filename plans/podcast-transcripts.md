# Apple Podcasts transcripts as sources

**Goal.** Pasting an Apple Podcasts *episode* URL (e.g.
`https://podcasts.apple.com/us/podcast/chinatalk/id1289062927?i=1000774368453`)
into Add from URL recognizes it as a podcast episode and ingests the episode's
Apple-hosted transcript as a markdown source — instead of fetching the URL's
HTML (which is just the web player, no transcript).

Feature input: `~/Downloads/transcript-feature-plan.md` (the URL → transcript
pipeline design). Reference implementation:
[`dado3212/apple-podcast-transcript-downloader`](https://github.com/dado3212/apple-podcast-transcript-downloader)
(`FetchTranscript.m`), vendored verbatim at
`docs/vendor/apple-podcast-transcript-downloader/` and adapted into the
`podcast-token-helper` target.

## Why this is non-trivial

Apple does not expose a static transcript URL. Reaching the TTML (timed-text
XML) transcript takes two authenticated calls:

1. **Bearer token** — `GET sf-api-token-service.itunes.apple.com/apiToken?…`
   must carry an `X-Apple-ActionSignature` header, a FairPlay/Mescal signature
   only producible by Apple's private `PodcastsFoundation` framework on-device
   (`AMSMescal _signedActionDataFromRequest:policy:` +
   `AMSMescalSession signData:bag:`). The public web-player token does NOT have
   transcript permissions (AMP returns `40012 Insufficient Permissions`).
2. **AMP transcripts** —
   `GET amp-api.podcasts.apple.com/v1/catalog/us/podcast-episodes/{id}/transcripts?…`
   with `Authorization: Bearer {token}` returns JSON whose
   `data[0].attributes.ttmlAssetUrls.ttml` is a per-request access-key'd TTML
   URL. Downloading that URL needs no auth. Parse TTML → text.

**Verified on this machine (macOS Darwin 25.5, 2026-07-03):** the vendored
reference compiled with
`clang -Wno-objc-method-access -framework Foundation -F/System/Library/PrivateFrameworks -framework AppleMediaServices`
produced a valid `ey…` JWT, the AMP call returned the TTML URL, and the full
927 KB `transcript_1000774368453.ttml` downloaded — all three legs work.

## Build flag — `WIKIFS_APP_STORE`

The whole feature is gated so an App Store build can drop it (it uses private
API and isn't shippable). It is **included by default**; set `WIKIFS_APP_STORE=1`
at build time to exclude it:

- `Package.swift` reads the env var. Default → defines the `PODCAST_TRANSCRIPTS`
  compilation condition on `WikiFSCore`, `WikiFS`, and the test target, and keeps
  the `podcast-token-helper` executable target. With `WIKIFS_APP_STORE=1` → the
  define is dropped and the helper target is `.filter`ed out of the manifest, so
  the private-API code is never compiled.
- Every podcast source and test file is wrapped in
  `#if PODCAST_TRANSCRIPTS … #endif`. `WikiStoreModel.ingestURL` has two
  overloads under the flag (the default build's takes a `podcastFetcher`; the
  App Store build's doesn't and just calls the shared `ingestWebURL`).
- `build.sh` bundles/signs the helper only when the target produced it (guarded
  by `[ -x ]`), so an App Store build simply omits it.

Verify both configs: default → `swift build && swift test`; App Store →
`WIKIFS_APP_STORE=1 swift build` (helper target absent, feature compiled out).

## Architecture

```
pasted URL
  └─▶ PodcastEpisodeURL.parse            (pure; WikiFSCore)      — recognizer
        └─▶ ApplePodcastTranscriptService (WikiFSCore)            — orchestrator
              ├─▶ token: PodcastTokenProviding
              │     └─ HelperTokenProvider → Process(podcast-token-helper)
              │        + 30-day on-disk cache (Application Support)
              ├─▶ AMP request  (PodcastHTTPClient seam → URLSession)
              ├─▶ TTML download (same seam)
              └─▶ TTMLTranscript.parse    (pure; XMLParser)       — cues → markdown
```

- **`podcast-token-helper`** (new ObjC executable target,
  `Sources/PodcastTokenHelper/`) — the *only* unsafe code. Adapted from the
  vendored `FetchTranscript.m`: dlopens `PodcastsFoundation`, signs the
  apiToken request, prints the bearer JWT to stdout. Keeps the reference's
  fork/pipe isolation (the private call can segfault during promise cleanup;
  in a helper CLI, fork is safe — unlike in the threaded app process). The app
  invokes it via `Process`, so a crash costs one failed fetch, never the app.
  Bundled at `Contents/Helpers/podcast-token-helper` (signed like `wikictl`);
  dev/test runs find it next to the built products.
- **`PodcastEpisodeURL`** (pure) — recognizes `podcasts.apple.com` episode
  links: host suffix `podcasts.apple.com`, numeric `i` query param = episode
  ID; the `/podcast/<slug>/` path segment provides the filename slug. A show
  link without `i=` is NOT an episode (falls through to normal HTML ingest).
- **`TTMLTranscript`** (pure) — `XMLParser` over the TTML. Real Apple TTML
  nests `<span podcasts:unit="word">` inside sentence spans with **no
  whitespace between words**, so the parser joins word-unit spans with spaces
  (naive character concatenation yields "WelcometoWarTalk."). Falls back to raw
  `<p>` text when no word spans exist. Keeps `begin`/`end`/`ttm:agent` per
  `<p>` as `Cue`s; renders markdown with `SPEAKER_N:` paragraph prefixes when
  agents are present.
- **`ApplePodcastTranscriptService`** — orchestrates token → AMP → TTML →
  parse. On AMP `40012` it force-refreshes the token once and retries; a 404 /
  missing asset URL maps to `.noTranscriptAvailable`. Token cached on disk 30
  days (`~/Library/Application Support/SelfDrivingWiki/podcast-bearer-token.json`),
  so most fetches are two plain HTTPS GETs.
- **Wiring** — `URLIngestService.ingest` and `WikiStoreModel.ingestURL` check
  `PodcastEpisodeURL.parse` FIRST; on a hit they call the (injected)
  `PodcastTranscriptFetching` and store
  `<slug>-<episodeID>-transcript.md` via the same store path as every other
  ingest. New `IngestOutcome.Kind.podcastTranscript`.

## Testing

- **Pure, no network:** `PodcastEpisodeURL` (the ChinaTalk URL + edge cases);
  `TTMLTranscript` against a fixture trimmed from the real captured TTML
  (word-span joining, clock parsing, speakers); AMP JSON decoding against the
  real captured response shape; service orchestration with fake token/HTTP
  (including the 40012 refresh-retry rule); ingest routing with fakes.
- **Live integration (gated):** full URL → transcript for the ChinaTalk
  episode, enabled only with `WIKIFS_LIVE_PODCAST_TESTS=1` — hits Apple
  endpoints and needs the private framework + built helper.

## Risks

1. **Signature fragility** — private selectors can change across macOS
   releases (reference repo confirms broken on 14.4.1, works 15.5+). All
   unsafe code is in the helper; failure surfaces as
   `.signatureUnavailable` with stderr detail, never a crash.
2. **ToS/legality** — pulls Apple-hosted transcripts via private API. Personal
   use only; not App Store shippable, do not distribute.
3. **No transcript** — some episodes have none; `.noTranscriptAvailable` lets
   the sheet show a clear message.
