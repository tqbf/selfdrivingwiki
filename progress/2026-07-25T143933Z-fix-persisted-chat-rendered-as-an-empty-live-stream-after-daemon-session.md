---
timestamp: 2026-07-25T143933Z
title: "fix: Persisted chat rendered as an empty live stream after daemon session eviction"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Persisted chat rendered as an empty live stream after daemon session eviction

## Progress


**Goal:** a chat with a full persisted transcript opened to the empty-composer
state ("Ask a question to start a chat.") instead of its messages. Reproduced on
the "Fun Stuff" wiki with chat `01KYBG3AWRCKBKDPTWEFDY4PP0` — 8 rows present in
`chat_messages`, none rendered.

**Root cause:** `ChatDetailView.isLiveChat` selects between the streaming mirror
and the persisted rows purely on `remoteSession.activeChatID == chatID`.
`RemoteChatSession.init` was seeding `activeChatID = chatID` unconditionally, so
**every freshly-created mirror claimed to be the live session** with an empty
`events` array — violating the invariant its own doc comment states
("Managed by `hydrate`/`applyStateUpdate` from the daemon's run flags").
`rehydrate` normally corrects the claim, but `DaemonChatHost.chatSessionState`
throws `noSession` for any chat whose launcher the daemon has evicted (i.e. every
chat from a previous app run) → `WikiDaemon` returns empty `Data()` → the client
throws `unexpectedReply`. The catch block's comment promised "the persisted rows
remain the source of truth" but never actually dropped the stale liveness claim,
so the view rendered the empty live stream forever.

**What changed:** `RemoteChatSession.init` now leaves `activeChatID` nil — a
fresh mirror knows nothing about the daemon and must not claim liveness. New
`markNotLive()` clears both `activeChatID` and `isInteractiveSession`;
`ChatDaemonCoordinator.rehydrate`'s catch calls it and drops the chat from
`runningChatIDs`, so a failed rehydrate genuinely falls back to the persisted
transcript. Related to #904 (event-sink blackout) but independent: this path
fails even with a healthy event sink.

**Files:** `Sources/WikiFS/Chats/RemoteChatSession.swift`,
`Sources/WikiFS/Chats/ChatDaemonCoordinator.swift`;
`Tests/WikiFSAppTests/{RemoteChatSessionTests,ChatDaemonCoordinatorTests}.swift`.

**Evidence:** root cause confirmed against the running app —
`ChatDaemonCoordinator.rehydrate failed for 01KYBG3AWRCKBKDPTWEFDY4PP0:
unexpectedReply` in the unified log, with the 8 rows verified present via
`sqlite3`. 6 new regression tests (fresh session doesn't claim liveness,
`markNotLive`, rehydrate-failure clears liveness, idle rehydrate stays
not-live). `swift build` ✓; full `WikiFSAppTests` run 1428 tests / 141 suites,
the only failure a pre-existing `MiniLMEmbedder` GPU-latency threshold
(median 21.68 ms vs 20 ms) unrelated to this change.

---

## Verification

Historical verification remains in the progress record above.
