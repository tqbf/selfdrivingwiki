---
timestamp: 2026-09-11T120000Z
title: Durable chat identity from creation
branch: bugfix/chat-optimistic-echo
status: complete
---

# Durable chat identity from creation

## Progress

New chats were model-only drafts until the first send. `beginNewChat()` minted
a `ChatSummary`, stamped it on the tab as `optimisticChatID`, and merged an
optimistic row into the sidebar through `pendingDraftChats`. Nothing was
persisted. The daemon created the real row on the first send, and the tab
morphed through `retargetActiveTabToChat`. A page-switch round trip before the
first send showed "Chat Deleted", because no row existed to resolve.

`beginNewChat()` now writes an empty-title `.edit` row through
`WikiStore.createChat` first, inserts the summary into the `chats` cache, opens
`.chat(chat.id)`, and requests a sidebar reveal. The row, the tab, the sidebar
highlight, the first send, and later navigation share one stored `ChatID`. On a
store failure the model sets its `storeError` alert ("Could Not Create Chat")
and touches no tab, row, reveal, or selection state.

The overlay is gone: `EditorTab.optimisticChatID`, `pendingDraftChats`, the
`reloadChats()` merge, and the close-path overlay refreshes. The durable path
has no retarget effect; the authoritative turn replaces the echo through the
turnID filter. The compatibility `.newChat` surface keeps an optional
`chatCreated` hook so a nil-ID send still follows the daemon-created chat.
`.newChat`
stays a compatibility navigation intent, and `retargetTab` /
`retargetActiveTabToChat` stay for the legacy `AgentOperationRunner` path.
Closing an empty chat tab keeps the row. Empty titles render as "New Chat" in
the sidebar and "Chat" on the tab.

The first send titles an untouched empty chat through a new store operation,
`setChatTitleIfEmpty(chatID:title:)`. It runs one conditional UPDATE
(`WHERE id = ? AND title = ''`) inside `mutate(event:_:)` and shares the
`chat_search` refresh helper with `renameChat`. A written title emits one
`.chat .updated` event. An already-titled chat returns false and emits nothing.
A missing chat throws `.chatNotFound` with no event. The exhaustiveness test
pins the `mutate()` routing. `DaemonChatHost.submitTurn` calls the operation
before `makeOrGetController`, so a manual rename always wins and the nil-ID
compatibility path keeps its creation-time title. A failed send keeps an
app-created row; the rollback stays limited to nil-ID daemon-created chats.

## Verification

- `make build` passed.
- `make test` passed (4300 tests, 466 suites).
- Bare `swift build` and bare `swift test` passed after the prerequisites
  (4300 tests).
- `WIKIFS_APP_TESTS=1 xcrun swift test --parallel --num-workers 1 --filter
  'ChatPresentationAPIManifestTests|DaemonChatUsageTests|
  DaemonChatControllerMetadataTests|DaemonChatControllerTests|
  ChatOutgoingMessagesControllerTests|DaemonChatHostTests|
  DurableNewChatHostedTests'` passed (119 tests).
- New or rewritten suites: `NewChatSidebarProjectionTests` (durable identity,
  failure alert, navigation, close/reopen, multi-chat), `ChatsListHighlightTests`,
  `ChatOutgoingMessagesControllerTests` (`firstSendKeepsCreationIdentity`),
  `ChatStoreTests` (title-if-empty store contract plus a two-handle rename
  race), `StoreEmissionTests` (emit once / emit nothing / missing throws),
  `StoreEmissionExhaustivenessTests` (`setChatTitleIfEmpty` routes through
  `mutate`), `DaemonChatHostTests` (first-send title, failed-send keeps row,
  nil-ID creates and starts and returns the id), `DaemonChatControllerTests`
  (cold first turn receives the four persisted selection values),
  `DurableNewChatHostedTests` (hosted navigation round trip keeps the chat
  surface).
- Two review rounds fixed three findings: the compatibility `.newChat` surface
  follows a daemon-created chat through an optional `chatCreated` hook;
  `beginNewChat(prefill:)` installs the omnibox question only after the store
  write succeeds; and `updateChatModelAndThinkingSelection` refreshes the
  `chats` cache synchronously so back-to-back composer picks cannot clobber
  one another through a stale projection.
- One unrelated flake under full-parallel load
  (`ExtractorPackageStoreTests/concurrentReadersSeeOnlyCompleteGenerations`,
  `.corruptCatalog`) reproduces only at high worker counts. It passes in
  isolation and in the supported single-worker runs. Unrelated to this branch.
