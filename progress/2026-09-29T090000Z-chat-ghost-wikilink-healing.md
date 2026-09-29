---
timestamp: 2026-09-29T090000Z
title: Ghost wiki-links in chat transcripts — heal on render-generation advance, resolve live in menus and clicks
branch: bugfix/chat-ghost-wikilink-healing
status: complete
---

# Ghost wiki-links in chat transcripts — heal on render-generation advance, resolve live in menus and clicks

## Progress

A chat cited a just-imported Zotero source as `[[source:Name]]` (chat
`01M3K7KN8WRC78WPQT6D0XVAED`). The import ran through the agent's `wikictl`
subprocess; the app learned of it through the Darwin-notification bridge
(~250 ms coalesce + store reload). The final message rendered inside that
window, so the link baked as `wiki://missing` (ghost). Two defects followed:

- The transcript renderer never healed the ghost: the render planner only
  re-rendered rows whose VALUE changed, and the render-context generation was
  not an input. The row kept its dead href until a full transcript reload.
- The right-click menu degraded by design for unresolved links: only
  "Suggest…", no "Open in New Tab" / "Open in Background" / "Add Bookmark…".
  Clicking the ghost was inert.

Fix, two layers:

- **Heal pass (root fix).** `WikiRenderContext` now carries the store's
  `renderContextGeneration`; `ChatWebView` stamps it into every desired
  snapshot. `ChatTranscriptRenderContext` gained `renderGeneration` —
  deliberately excluded from transcript identity, so a generation change
  alone never reloads. When the generation advances, the planner re-renders
  exactly the wiki-link-bearing rows (`ChatDisplayRow.wikiLinkBearing`) last
  rendered under an older generation. The executor stamps each acknowledged
  row with the generation it rendered at (`renderedRowGenerations` on the
  snapshot), which terminates the heal under its plan-one-run-one loop.
- **Live resolution (menu + click).** `WikiLinkMenuNSItems.selection` now
  resolves a `wiki://missing?title=…` URL against the store by title (page →
  source → chat — the ghost URL lost its kind) before declaring it dead. The
  chat link menu treats a live-resolvable ghost exactly like a resolved link,
  and `WikiReaderView.onWikiLinkHandler` routes a click on a live-resolvable
  ghost instead of no-op. This covers the window before the heal re-render
  lands.

## Verification

- `make build` clean; `make test` (default graph) passes; full
  `WIKIFS_APP_TESTS=1 swift test` app graph passes.
- `ChatTranscriptRenderPlannerTests` (9 tests): generation advance replaces
  only link-bearing rows; stamped rows are not replaced again; no heal
  without link-bearing rows; value replaces are not duplicated; identity and
  resetToken changes still reload.
- `GhostLinkResolutionTests` (5 tests): ghost source/page links resolve once
  the target exists; dead ghosts stay nil; non-wiki URLs never take the ghost
  path; an external write + `reloadFromStore()` advances
  `renderContext().generation` (the chain the heal depends on).
