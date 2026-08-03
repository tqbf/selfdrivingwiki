# Phase 4b — Byteless external embeds

Makes `![[source:…]]` embeds render **external, byteless media** inline in the WKWebView page reader — provider-player iframes (YouTube, Vimeo, Spotify, SoundCloud), native `<audio>`/`<video>` for direct-remote media URLs (mp3 streams, `.mp4`, `.m3u8` HLS), and the Apple Podcasts embed audio player for existing podcast sources — all through one shared, provider-agnostic mechanism. **No schema change** (`external_identity`/`mime_type`/`thumbnail_hash` columns already existed); every external embed is a byteless source (`blob_hash IS NULL`) carrying `external_identity` + provenance, exactly like the Phase 3b podcast byteless source.

## What shipped

**Shared core (Phase 1):**
- `SourceEmbedDescriptor` (new value type) + a batched store query `embedDescriptors()` joining byteless sources → active version → activity → agent (mirrors `sourceOrigin`, restricted to `blob_hash IS NULL`).
- `ExternalEmbed.target(for:)` — a pure dispatch table (`SourceEmbedDescriptor → EmbedTarget?`).
- `WikiLinkMarkdown.embedInfo` widened from `(id, mimeType)?` to `SourceEmbedInfo { id, mimeType, target }`; `embedHTML` checks the external target **first** (load-bearing ordering: a synthetic mime like `video/youtube` never reaches the `wiki-blob://` branch). `.wiki-embed` reader CSS extended for 16:9 video iframes / fixed-height audio iframes / full-width native audio.

**Consumers (Phases 2–4):** direct-remote media, provider iframes, Apple Podcasts player — each a pure URL recognizer + a dispatch row + an `addURL` routing branch.

**Routing** (`bytelessMediaOutcome`): pure URL parsing, no network; fixed precedence: apple-podcast FIRST → providers → remote-media → website fallthrough. `role: .primary`.

## Key files
- `Sources/WikiFSCore/ExternalEmbed.swift` (new), `MediaEmbedURL.swift` (new)
- `WikiLinkMarkdown.swift`, `SQLiteWikiStore.swift`, `WikiStore.swift`, `WikiStoreModel.swift`, `URLFetchService.swift`
- `Sources/WikiFS/WikiReaderView.swift`, `ReaderMarkdown.swift`

## Testing
1706 tests green. New suites: `ExternalEmbedTests`, `MediaEmbedURLTests`, `BytelessEmbedIntegrationTests` (store/routing/refresh) + embed-target cases in `WikiLinkMarkdownTests`. Covers AC.1–AC.8.

**AC.9 (live WKWebView paint) is manual-only** — same status as Phase 4a. Recipe: paste one URL of each kind to create the byteless sources, then embed each with `![[source:…]]`. Verify ATS/sandbox/WKWebView config allow egress to `youtube-nocookie.com`, `player.vimeo.com`, `open.spotify.com`, `w.soundcloud.com`, `embed.podcasts.apple.com`, and the remote-media hosts (R1 — highest-uncertainty item).

## Review
A `general-purpose` subagent review found no CRITICAL/HIGH issues; all three load-bearing invariants (ordering, routing precedence, SQLite concurrency) hold. One MEDIUM finding (`.m3u8` HLS not rendering) was fixed before this PR.
