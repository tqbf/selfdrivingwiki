---
timestamp: 2026-07-23T135509Z
title: "feat: Daemon Phase C4 — ChatDetailView flip to RemoteChatSession"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Daemon Phase C4 — ChatDetailView flip to RemoteChatSession

## Progress


**Goal:** the final slice of daemon Phase C (#861). The app's `ChatDetailView`
(now `RemoteChatSession` + `ChatDaemonCoordinator`) talks to the daemon
instead of a local `AgentLauncher`. After C4 the daemon owns chat sessions
end-to-end; the app no longer constructs a chat `AgentLauncher` at all.

**Plan:** `plans/chat-daemon.md` §"C4".

**Architecture:** a new `ChatDaemonCoordinator` (`@MainActor @Observable`,
`Sources/WikiFS/Chats/ChatDaemonCoordinator.swift`) owns the per-chat
`RemoteChatSession` registry, routes chat envelopes demuxed by
`DaemonQueueEventSink.chatEnvelopes` by chatID, wraps the 6 chat XPC commands
behind typed Swift methods, and rehydrates sessions from the daemon's live
state. It's constructed in `WikiFSApp` over the existing daemon connection +
event sink and injected via a new `\.chatDaemonCoordinator` environment value
(`nil` when the daemon is down). `RemoteChatSession` is the single binding
surface for all chat UI (run state + provider config).

**Full decouple:** the per-wiki chat `AgentLauncher` was removed entirely
(`WikiSession.chatLauncher` + its construction deleted; the ingest/lint
`agentLauncher` is unchanged). Every `chatLauncher`/`launcher` reference in
chat surfaces was replaced with `RemoteChatSession`/coordinator equivalents.

**Files touched:**
- **New:** `Sources/WikiFS/Chats/ChatDaemonCoordinator.swift` (registry +
  event router + command wrappers + rehydration + sidebar liveness aggregate
  `isChatRunning`/`anyChatRunning`; `ChatDaemonCommands` protocol so tests
  inject a stub; `\.chatDaemonCoordinator` environment key),
  `Tests/WikiFSAppTests/ChatDaemonCoordinatorTests.swift` (18 tests).
- **Extended:** `Sources/WikiFS/Chats/RemoteChatSession.swift` — added the
  provider-config surface (`providersConfig`, `setSelectedModelAndDefault`,
  `toggleFavoriteModel`, `selectedModelId`, `resolveSelectedProvider`,
  `resolveProvidersContainerDirectory` — same shared config file the daemon
  reads), `stderr`/`lastActivityAt`/`currentProcessID` mirrors,
  `debugFolderURL(forChat:)`/`logFileURL(forChat:)` instance companions,
  `setThinkingEffort` (optimistic local flip; daemon apply deferred — no
  chat-config XPC method in the Phase C 6-method protocol), `startNewChat`.
  **Fixed the source-of-truth rule:** `hydrate`/`applyStateUpdate` now manage
  `activeChatID` from the run flags (`activeChatID == chatID` while the daemon
  reports the session interactive, else `nil`) so a per-chat mirror flips a
  chat live precisely when the daemon is running it.
- **Flipped:** `Sources/WikiFS/Chats/ChatDetailView.swift` (replaced all 59
  `launcher.*` run-state reads with `remoteSession.*`; commands route through
  `coordinator` — `startChat`/`continueChat`/`sendMessage`/`stop`/
  `resolvePermission`; rehydration `.task` on appear/chat change;
  `PermissionApprovalView` computes `approve` from the chosen option's kind),
  `Sources/WikiFS/Settings/ProviderSelector.swift`,
  `Sources/WikiFS/Chats/ThinkingEffortSelector.swift`,
  `Sources/WikiFS/Queue/AgentQueueView.swift`,
  `Sources/WikiFS/Queue/AgentRunStatusView.swift` — all now bind
  `RemoteChatSession` instead of an `AgentLauncher`.
- **Sidebar live indicator:** `Sources/WikiFS/Chats/ChatsListView.swift` +
  `Sources/WikiFS/Settings/AgentToolsView.swift` — the per-row "responding…"
  badge now reads `coordinator.isChatRunning(id)` (covers chats the daemon is
  running that the app hasn't opened), replacing
  `chatLauncher.activeChatID == id && chatLauncher.isGenerating`. The pure
  `AgentToolsView.isLiveRow` predicate is retained (still unit-tested).
- **Wiring/threading:** `Sources/WikiFS/Window/WikiFSApp.swift` (constructs
  the coordinator over the daemon connection; injects via `appEnvironment`;
  quit-dialog "A chat session" check now reads
  `chatDaemonCoordinator?.anyChatRunning`),
  `Sources/WikiFS/Window/WikiDetailView.swift` (removed `chatLauncher`; reads
  `\.chatDaemonCoordinator`; renders a `chatDaemonUnavailable` state when the
  daemon is down — no local chat fallback),
  `Sources/WikiFS/Window/ContentView.swift`,
  `Sources/WikiFS/Window/RootView.swift`,
  `Sources/WikiFS/Window/SidebarView.swift` (dropped `chatLauncher`
  threading).
- **Removed:** `WikiSession.chatLauncher` (+ its `AgentLauncher` construction);
  updated `Tests/WikiFSTests/WikiSessionTests.swift`.

**Tests:** +24 (18 `ChatDaemonCoordinatorTests`, 6 new `RemoteChatSessionTests`
covering `activeChatID` source-of-truth tracking, `setThinkingEffort`, and
`startNewChat`). Full suite: 3769 tests pass.

**Known limitations (deferred):**
- Mid-session thinking-effort changes flip the chip locally only — applying
  them to the daemon's live session needs a 7th chat XPC method
  (`setChatConfigOption`) not in the Phase C protocol. Provider/model
  selection writes the shared config file the daemon reads at the next
  `startChat`/`continueChat`, so it applies to the next turn.
- `stderr`/`lastActivityAt`/`currentProcessID` stay empty/nil (not carried by
  the chat envelope protocol today); the internals/debug `AgentQueueView` and
  `AgentRunStatusView` degrade gracefully.

**Evidence:**
- `make version prompts keychain && swift build` ✓ (0 errors)
- `swift test` ✓ (3769 tests, 0 failures)
- `swift test --filter 'RemoteChatSessionTests|ChatDaemonCoordinatorTests'` ✓
  (38 tests)

---

## Verification

Historical verification remains in the progress record above.
