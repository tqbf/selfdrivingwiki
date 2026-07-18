## Summary

Pasting a YouTube/Vimeo URL now shows the real video title as the source display name and renders the embed player + transcript in the source detail view (issue #572).

## What changed

### 1. Video title via oEmbed (display name)

New `MediaTitleFetcher` builds each provider's oEmbed endpoint URL (YouTube/Vimeo/Spotify/SoundCloud) and fetches the JSON title off-main via the injected `URLResourceFetcher` seam. Never throws — a network/decode failure returns `nil` so the synthetic `youtube-<id>` name stays in place (mirrors the `YouTubeTranscriptService` best-effort discipline).

Wired into both byteless ingest paths in `WikiStoreModel`:
- `bytelessMediaOutcome` (Vimeo/Spotify/SoundCloud/remote-media)
- `youtubeEmbedAndTranscriptOutcome` (YouTube embed + caption transcript)

Both now call `fetchMediaTitle` (a detached `Task`) and `setSourceDisplayName` on success, threading the resolved title to every `openTab` call.

### 2. Embed start-time for YouTube

`ExternalEmbed.youTubeStartTime(from:)` parses YouTube's `&t=` / `?start=` (integer + clock form `1m30s` / `1h2m30s`) into integer seconds and stamps `&start=` onto the embed URL so the player resumes at the pasted timestamp. E.g. `https://www.youtube.com/watch?v=-mwLAjsdgVM&t=569s` -> `&start=569`.

### 3. Embed player + transcript in source detail view

New `MediaEmbedPlayerView` — a self-contained `WKWebView` (`NSViewRepresentable`) that renders one provider iframe, loaded under `WikiReaderOrigin` (the same synthetic https origin the reader uses) so YouTube's parent-origin check passes (no 153-error). The iframe attributes mirror `WikiLinkMarkdown.embedHTML` exactly (YouTube eager-loads + forwards the referrer; others lazy-load). A pure `MediaEmbedPlayerHTML.document(for:)` builds the HTML so it is unit-testable without a WKWebView.

`SourceDetailView` gains `embedDescriptor`/`embedTarget` computed from the loaded `origin` + the source mime, branches `contentArea` to a new `embedContent(target:)` layout:

```
+-----------------------------------------+
|  [YouTube Embed Player]                 |  iframe (16:9, ~360pt)
+-----------------------------------------+
|  # Transcript                           |
|  Hello everyone, welcome to this talk. |  rendered markdown (WikiReaderView)
|  Today I want to discuss...             |
+-----------------------------------------+
```

When no derived markdown exists (video with no captions, or a Spotify track), a "No Transcript Available" placeholder sits beneath the player.

## Test plan

- [x] `make version prompts && swift build` — clean
- [x] Fast test tier: 2,559 tests in 217 suites pass (+17 new)
- [x] New `MediaEmbedPlayerTests` — 17 pure tests covering: YouTube start-time parsing (integer/clock/garbage/absent), oEmbed URL building + title JSON parsing, embed player HTML element/document (iframe attributes, audio vs video size class, attribute escaping)
- [x] `BytelessEmbedIntegrationTests` updated — `ExplodingFetcher` + `YouTubeFixtureFetcher` now serve canned oEmbed JSON (reflects new expected behavior); all 10 tests pass
- [ ] Manual: paste a YouTube URL with `&t=569s`, verify the title shows as the video name and the embed starts at 569s
- [ ] Manual: paste a Vimeo URL, verify the title + embed player render

## Notes

- The oEmbed fetch runs off-main and never blocks ingest (a missing/unreached oEmbed leaves the synthetic name in place).
- `remote-media` sources (mp3/mp4/HLS) have no oEmbed — they keep their filename as the display name (unchanged behavior).
- Does NOT merge to main — leaving for review.

Closes #572.
