---
timestamp: 2026-09-07T190500Z
title: Fix new chats not appearing immediately in the Chats sidebar (#1223)
branch: fix/new-chat-sidebar-row-1223
status: complete
---

# Fix new chats not appearing immediately in the Chats sidebar (#1223)

## Progress

The New Chat buttons called `store.openTab(.newChat)`. That opened a draft
tab and nothing else. No `ChatSummary` existed until the daemon created the
`chats` row on the first send, and nothing reloaded `store.chats` in
between, so the Chats sidebar stayed unchanged until a later refresh.

The model now owns an optimistic row per open draft:

- `WikiStoreModel.beginNewChat()` mints the draft's stable chat identity,
  inserts an optimistic `ChatSummary` (empty title — the cell renders "New
  Chat"), stamps it on the new tab as `EditorTab.optimisticChatID`, and
  opens the `.newChat` tab. Nothing is persisted.
- `reloadChats()` merges `pendingDraftChats` into the loaded rows, sorted by
  `(updatedAt, id)` descending. The overlay is applied inside the reload, so
  every refresh path — local writes and the external `reloadFromStore()`
  bridge — keeps the draft row visible and cannot duplicate a committed
  chat.
- The draft→persisted morph (`retargetActiveTabToChat`) now reloads the list
  (the daemon has written the real row before the submit reply returns) and
  requests a sidebar reveal of the committed row.
- Tab close paths (`applyCloseTab`, `closeOtherTabs`, `closeTabsAfter`,
  `closeAllTabs`) and `retargetTab` refresh the overlay, so a closed or
  committed draft never leaves a ghost row.
- All four New Chat entry points (Chats sidebar `+`, address-bar ask,
  wiki detail Add Chat, Cmd+Shift+C) now call `beginNewChat()`.
- `ChatsListView.reconcileHighlight` gained a `draftChatID` parameter: with
  a `.newChat` selection, the draft's optimistic row is highlighted; after
  the morph, the committed row is.

The deferred-commit design is preserved: the daemon still creates the
`chats` row on the first send, and an abandoned draft never persists.

## Verification

- `swift test --filter NewChatSidebarProjectionTests` — 7 tests pass:
  immediate projection without persistence, sort position, first-send
  reconciliation without duplication, draft-tab close cleanup, external
  refresh retention, multiple drafts, and first-message title derivation.
- `WIKIFS_APP_TESTS=1 swift test --filter ChatsListHighlightTests` —
  highlight of the draft row, then the committed row.
- `make build` and `make test` — full default suite passes. One flaky
  failure appeared while testing: `ManagedExtractorProcessExecutorTests.
  runtimeEntryAllowsReadableNonExecutableFile` (a 5 s subprocess timeout).
  It also fails ~1 in 3 runs on clean `main` with no changes, so it is a
  pre-existing load-sensitive flake, not this branch.
