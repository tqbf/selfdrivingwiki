---
timestamp: 2026-09-23T175156Z
title: Chat transcripts gain native wiki-link context actions with canonical ID resolution
branch: bugfix/1315-chat-source-menu
status: complete
---

# Chat transcripts gain native wiki-link context actions with canonical ID resolution

## Progress

Right-clicking a source link in a chat transcript offered no wiki actions —
only WebKit's default menu — even though the same link in the reader offers
Open in Background, Add Bookmark, and friends. The reader menu also resolved
every action by display name, ignoring the stable ID in a canonical link, so
an action could silently stop working after a rename (#1315).

Changes:

1. `ChatTranscriptWebView` (new `WKWebView` subclass in `ChatWebView.swift`)
   tracks the hovered `<a>` href through the reader's proven hover-listener
   script and `linkHover` message channel (reused, not duplicated — each web
   view has its own content controller, so there is no collision). For a
   resolved `wiki://` link it inserts "Open in New Tab" and "Open in
   Background" right after WebKit's "Open Link", removes the same unsupported
   WebKit built-ins the reader removes, and collapses separators. External
   and unresolved (`wiki://missing`) links keep the plain WebKit menu. Plain
   clicks and ⌘-clicks still flow through `decidePolicyFor` unchanged.
2. The menu emits typed intents only: `.openWikiLink(url, inNewTab: true)`
   for the foreground tab (⌘-click parity) and a new
   `.openWikiLinkInBackground(url)`. Consumers resolve where the store lives:
   `ChatDetailView` (chat pane + internals pane via a new
   `AgentQueueView.onWikiLinkBackground` seam) and `ActivityWindowView`
   (with the click-handler fallback that stashes and opens a closed wiki
   window). The view never touches the store, matching the documented
   `ChatTranscriptIntent` contract.
3. `WikiLinkMenuNSItems.selection(for:store:)` is the one resolution seam for
   menus: canonical `?id=` wins when it names a loaded row (same discipline
   as `selectPage`/`selectSource`/`selectChat(byID:)`), display-name lookup
   remains only for legacy `?title=`-only links or ids that no longer load.
   The reader's "Open in Background", Add Bookmark, and Share items now route
   through it, so a renamed source still opens from its old link.

## Verification

- `make build` — green.
- `make test` — default graph passes except 10 pre-existing issues in
  `RaceFreeProcessGroupRunnerTests` and `IdentifierBoundaryTypecheckTests`;
  both fail identically on clean `origin/main` in this sandbox. They scan
  `.build` for the deprecated native build system's layout, while this
  toolchain's `swift build`/`swift test` default to swiftbuild (flat
  `Products/Debug`, no `debug/Modules/`). Unrelated to this fix.
- `WIKIFS_APP_TESTS=1 swift test --filter
  "WikiLinkMenuNSItemsTests|WikiReaderRoutingTests|ChatWebViewLinkifyTests"`
  — green, including the new #1315 tests: apostrophe title via a legacy
  `?title=` link, canonical id winning over a stale display alias, chat menu
  insertion + callback routing, and non-wiki links left alone.
- `PageContextMenuHostedTests` — green (reader menu still builds).
