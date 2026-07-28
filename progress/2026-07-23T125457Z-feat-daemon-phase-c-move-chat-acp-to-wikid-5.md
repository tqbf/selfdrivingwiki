---
timestamp: 2026-07-23T125457Z
title: "feat: Daemon Phase C — move chat/ACP to wikid (#5)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Daemon Phase C — move chat/ACP to wikid (#5)

## Progress


**Goal:** the daemon owns interactive chat sessions end-to-end and can run
headless. The app (`ChatDetailView`), `wikictl`, and future MCP adapters are
thin clients.

**Plan:** `plans/daemon-phase-c.md` (with §11 Plan-Review Corrections RC1-RC9,
all applied where they conflict with earlier sections).

**Slices implemented:**

- **C1 (Protocol + types):** `ChatXPCRequests.swift` (Codable request/response
  types), `QueueEventEnvelope` extended with 4 chat kinds, 6 `WikiDaemonProtocol`
  chat methods, `DaemonWorkloadClient` wrappers, `WikiDaemonExporter` exporters.
- **C2 (DaemonChatHost):** daemon-native chat host with long-lived per-chat
  `AgentLauncher`s, shared `GenerationGate` (RC3), store-sink wiring,
  event streaming, state-change polling. RC1 (dead-session re-route), RC2
  (`getSystemPrompt()`), RC4 (per-chat takeover), RC5 (summarizer for
  `GRDBWikiStore`) all applied.
- **C3 (RemoteChatSession):** `@Observable` mirror of daemon launcher state,
  `DaemonQueueEventSink` chat-envelope demux.
- **C5 (wikictl chat):** `chat new`/`send`/`stop` subcommands via daemon XPC.

**Tests:** 29 new tests (15 daemon-side, 14 client-side). Full suite: 3747
tests pass.

**Next step (C4):** Flip `ChatDetailView` from `AgentLauncher` to
`RemoteChatSession` + `DaemonWorkloadClient`. This is a mechanical but invasive
UI change (1698 lines, 59 launcher bindings) that requires app-session-level
daemon wiring (event sink subscription, `RemoteChatSession` lifecycle). See
`plans/chat-daemon.md` §"What's next: C4".

**Evidence:**
- `swift build` ✓ (0 errors)
- `swift test` ✓ (3747 tests, 0 failures)
- `swift test --filter "DaemonChatHostTests|RemoteChatSessionTests"` ✓ (29 tests)

---

## Verification

Historical verification remains in the progress record above.
