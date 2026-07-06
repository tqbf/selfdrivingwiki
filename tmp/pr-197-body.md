## Summary

Ports PR #106 ("Apple Podcasts episode URLs as transcript sources") onto current `main` by remodeling its transcript pipeline onto the Phase-3a `SourceProvider` protocol. `ApplePodcastProvider` becomes the first real consumer of the protocol.

Paste a `podcasts.apple.com` episode URL into Add-from-URL → the TTML transcript is fetched (via a private-framework FairPlay/Mescal signing helper, isolated in its own ObjC subprocess) and stored as a markdown source. The Origin row shows "Apple Podcast" + a clickable URL.

## What shipped

- **Full transcript pipeline** ported verbatim from PR #106 (recognizer, TTML parser, AMP decoder, orchestration service, `podcast-token-helper` ObjC executable) — all pure/self-contained.
- **`ApplePodcastProvider: SourceProvider`** — materializes the transcript markdown off-main (`Task.detached`) and flows through the existing `storeMaterialized` → `store.addSource(provenance:)` seam, recording real PROV provenance (`apple-podcast` agent, `fetch` activity, `plan` = URL, `externalIdentity` = episode ID).
- **`addURL` routing seam** — recognizes an episode URL and routes to the provider instead of `WebsiteProvider`; a `podcastFetcher:` injection parameter enables CI routing tests with fakes.
- **`FetchOutcome.Kind.podcastTranscript`** + `SourceOrigin.displayLabel` arm (`"apple-podcast"` → `"Apple Podcast"`).
- **Build flag** — `#if PODCAST_TRANSCRIPTS` compiled in by default; `WIKIFS_APP_STORE=1` drops the helper target and compiles the feature out.
- **Security boundary** — an executable architecture test (`agentSurfaceHasNoPodcastReferences`) asserts the agent-surface modules contain no podcast symbols; runs in every config.

## Option-A deferral

The transcript is stored as source content (not as a byteless source + derived alternative per graph-model §11). This is cheap to retire later: Phase 2's `recordMarkdownExtraction` + CAS make the conversion a pointer move. See `plans/podcast-transcripts.md` and `plans/graph-model-and-versioning.md` §11.

## Test plan

- [x] `swift build` (feature-on) — AC.1
- [x] `WIKIFS_APP_STORE=1 swift build` + target-absence check — AC.2
- [x] `PodcastIngestRoutingTests` (episode → `.podcastTranscript`) — AC.3
- [x] `PodcastIngestRoutingTests` (non-podcast → WebsiteProvider) — AC.4
- [x] `SourceProviderTests.applePodcastProviderPersistsProvenance` — AC.5
- [x] `SourceProviderTests.agentSurfaceHasNoPodcastReferences` — AC.6
- [x] `swift test` — 1561 tests pass (1503 baseline + 58 new) — AC.7
- [ ] Manual live click-through (paste a real episode URL)
