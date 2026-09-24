---
timestamp: 2026-09-24T010854Z
title: Chat link menus reach reader parity through the WikiLinkMenuCapabilities seam
branch: bugfix/1315-chat-source-menu
status: complete
---

# Chat link menus reach reader parity through the WikiLinkMenuCapabilities seam

## Progress

The #1318 chat context menu offered only the two URL-only tab actions; the
reader's menu also offers Add Bookmark…, Add as Source, Suggest…, Find
Similar…, and Share…, all of which need the store or the File Provider facade
— authorities the chat view layer does not hold.

Implemented the advisor-approved capability-seam plan in four commits:

1. `refactor(menus)` — `WikiLinkMenuCapabilities` (optional-closure struct);
   `items(for:actions:capabilities:)` replaces the four dependency parameters.
   `.full(store:fileProvider:…)` is the only store-meeting site. Reader output
   pinned byte-identical by golden per-URL-kind titles, an omission matrix,
   and payload-routing tests built with stub closures (no store in scope).
2. `feat(chats)` — chat transcript menu parity. `ChatTranscriptWebView` gains
   `linkMenuCapabilities`, refreshed on every `updateNSView` (the
   Activity-window store appears and disappears with its wiki window).
   `ChatDetailView` supplies `.full` to the chat pane and the internals pane;
   `ActivityWindowView` supplies per-row `.full`/`.none`; `AgentQueueView`
   defaults to `.none`.
3. `refactor(menus)` — Share… extracted into the builder as a `.share`
   action. Fixes two reader defects: File Provider resolution no longer runs
   on every right-click, and unresolved/anchor links no longer grow a dead
   Share… item. Chat-kind Share clicks no-op (reader parity; chat-share
   wiring is future work).
4. `fix(menus)` — Open in Background re-resolves at click time, so a target
   deleted between right-click and click no-ops instead of opening a dead
   tab. `ChatTranscriptIntent`'s authority rule reworded to the clarified
   invariant (no authority; host-supplied closures are the sanctioned
   carrier; omit, never inert).

Decision record: `plans/chat-link-menu-capabilities.md` (indexed in PLAN.md).

## Verification

- `make build` green.
- `make test` (default graph): all suites pass except the documented
  pre-existing sandbox set — `RaceFreeProcessGroupRunnerTests` and
  `IdentifierBoundaryTypecheckTests` (build-system layout scanners), now
  joined by the flaky `historyEnablesBackThenForward`, which was proven to
  fail identically on the branch base `716995bd` with this work stashed.
- `WIKIFS_APP_TESTS=1 swift test --filter
  "WikiLinkMenuNSItemsTests|WikiLinkMenuBuilderTests|PageContextMenuTests|
  ChatWebViewLinkifyTests|WikiReaderRoutingTests|
  ChatPresentationAPIManifestTests"` — green (35 menu tests + 44 chat/reader
  suites).
- Manual check still worth doing in the running app: right-click a resolved
  source link and an external link in a chat transcript, and confirm the
  menu renders and each action navigates; menu-item presence and action
  routing are covered headlessly, on-screen rendering is not.
