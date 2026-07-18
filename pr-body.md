## Make wiki links clickable in the agent/activity transcript view

### Problem

The Activity window renders lint/ingest transcripts as HTML in a `ChatWebView`
(WKWebView) with `[[wiki-links]]` linkified to `wiki://page?title=…` URLs — but
clicking them did nothing. The `ChatWebView` navigation delegate already
intercepted `wiki://` clicks and called `onWikiLink?(url, openInNewTab)`, but
`ActivityWindowView.transcriptContent(for:)` constructed the `ChatWebView`
**without** passing an `onWikiLink` handler, so the call was an inert no-op.

(The in-wiki chat transcript and `AgentQueueView` already wired the handler via
`WikiReaderView.onWikiLinkHandler(for: store)` — the gap was exclusive to the
Activity window, which spans transcripts across many wikis.)

### Fix

Wired an `onWikiLink` handler into the Activity window transcript that handles
both same-wiki and cross-wiki navigation:

1. **Same-wiki (window open):** The item's `wikiID` resolves to a live
   `WikiSession`; route the click directly through
   `WikiReaderView.onWikiLinkHandler(for: store)` — the exact handler the
   in-wiki chat transcript uses. Navigation is immediate
   (`selectPage`/`selectSource`/`selectChat` load drafts synchronously).
2. **Cross-wiki (window closed):** A new deferred-navigation mechanism stashes
   the `wiki://` URL + `openInNewTab` flag on `SessionManager.pendingWikiLinks`
   keyed by wiki ID, then `openWindowBridge.openWiki(wikiID)` opens (or
   focuses) the wiki window. `session(for:descriptor:)` transfers the stash
   onto the new session, and `RootView.onAppear` consumes it after the store is
   ready.

Also wired `renderContext` + `blobStore` into the Activity transcript's
`ChatWebView` (from the item's wiki store) so ghost-link coloring and
`wiki-blob://` image serving work the same as the in-wiki feed. A closed wiki
degrades gracefully (links render, no resolution-based styling).

### Layering

The `pendingWikiLink` slot holds raw `URL` + `Bool` (Foundation types only) —
the Engine layer (`WikiSession`/`SessionManager`) never references the
app-layer `WikiLinkRoute`. The routing decision stays in `RootView`, which calls
`WikiReaderView.onWikiLinkHandler`.

### Files changed

- `Sources/WikiFSEngine/WikiSession.swift` — new `pendingWikiLink` slot.
- `Sources/WikiFSEngine/SessionManager.swift` — `pendingWikiLinks` stash map,
  `stashPendingWikiLink`/`consumePendingWikiLink`, session-creation transfer.
- `Sources/WikiFS/Window/RootView.swift` — `.onAppear` consumes the stashed
  link via `WikiReaderView.onWikiLinkHandler`.
- `Sources/WikiFS/Queue/ActivityWindowView.swift` — passes `onWikiLink`,
  `renderContext`, `blobStore` to the transcript `ChatWebView`; new
  `wikiLinkHandler(for:)` router.
- `Tests/WikiFSTests/SessionManagerTests.swift` — 4 new tests.

### Verification

- `make version prompts` ✓
- `swift build` clean ✓
- Fast test tier: **2577 tests / 218 suites pass** (4 new)
- `SessionManagerTests`: 12/12 pass
