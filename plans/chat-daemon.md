# Chat Daemon (Phase C) — Architecture

> **Status:** Complete. Daemon infrastructure (C1-C3, C5) + the ChatDetailView
> flip (C4) are merged. The daemon owns chat sessions end-to-end; the app,
> `wikictl`, and future MCP adapters are thin clients.

## Overview

Phase C moves interactive chat (ACP sessions, streaming, resume) from the app
to the `wikid` daemon. After Phase C, the daemon owns chat sessions end-to-end
and can run headless. The app, `wikictl`, and future MCP adapters are thin
clients.

## What's implemented

### C1: Protocol + types
- **`ChatXPCRequests.swift`** (WikiFSEngine): `ChatStartRequest`,
  `ChatContinueRequest`, `ChatSessionState`, `ChatPermissionResolveRequest`,
  `ChatStartReply`, `ChatErrorReply` — all `Codable, Sendable`.
- **`QueueEventEnvelope`** (WikiFSEngine): extended with 4 chat kinds
  (`chatEvent`, `chatState`, `chatAcpSessionId`, `chatPendingPermission`)
  + `chatID`/`acpSessionId`/`chatStateData` fields + static constructors.
- **`WikiDaemonProtocol`** (WikiFSCore): 6 new chat methods.
- **`DaemonWorkloadClient`** (WikiCtlCore): typed async wrappers for all 6.
- **`WikiDaemonExporter`** (wikid): chat method exporters bridging to
  `WikiDaemon.startChatData`/etc.

### C2: DaemonChatHost
- **`DaemonChatHost.swift`** (wikid): `@unchecked Sendable` host owning a
  `[chatID → ChatSession]` registry of long-lived `AgentLauncher`s.
- **RC3:** single shared `GenerationGate` across all chat launchers.
- **RC1:** `sendChatMessage` detects dead session, re-routes to `continueChat`.
- **RC2:** reads `GRDBWikiStore.getSystemPrompt()` (not hardcoded defaultBody).
- **RC4:** per-chat takeover — only `.refused` retained.
- **RC5:** `summarizePendingMessages` generalized for `GRDBWikiStore`.
- Store sinks wired directly to `GRDBWikiStore` (onTranscript →
  `appendChatMessages`, onSummary → `updateChatSummary`, etc.).
- `DarwinNotifier.postChange(forWikiID:)` on `onUnlock` (same as ingestion).
- Event streaming via `onAgentEvent` + 150ms state-change poll.

### C3: RemoteChatSession + demux
- **`RemoteChatSession.swift`** (WikiFS): `@MainActor @Observable` mirror of
  the daemon's launcher state. Full binding surface for ChatDetailView (RC9).
- **`DaemonQueueEventSink.swift`** (WikiFS): now demuxes chat envelopes
  alongside queue events via a parallel `AsyncStream`.

### C5: wikictl chat
- `wikictl chat new "<message>"` → daemon `startChat`
- `wikictl chat send <chatID> "<message>"` → daemon `continueChat`
- `wikictl chat stop <chatID>` → daemon `stopChat`

## What's next: C4 (ChatDetailView flip)

> **Shipped.** The UI flip replaced `@Bindable var launcher: AgentLauncher`
> with `var remoteSession: RemoteChatSession` + `var coordinator:
> ChatDaemonCoordinator` across `ChatDetailView` and every chat surface. The
> app no longer constructs a local `AgentLauncher` for chat — it creates a
> `RemoteChatSession` connected to the daemon. The chat `AgentLauncher` was
> removed from `WikiSession` entirely (the ingest/lint `agentLauncher`
> remains). Key changes that landed:

1. **App session wiring:** Create `RemoteChatSession` instances per chat tab,
   subscribe to `DaemonQueueEventSink.chatEnvelopes`, route envelopes by chatID.
2. **ChatDetailView bindings:** Replace 59 `launcher.X` references with
   `remoteSession.X` (mechanical, gated by compile errors).
3. **Command calls:**
   - `AgentOperationRunner.startChat(...)` → `client.startChat(...)`
   - `AgentOperationRunner.continueChat(...)` → `client.continueChat(...)`
   - `launcher.sendInteractiveMessage(...)` → `client.sendChatMessage(...)`
   - `launcher.stopAgent()` → `client.stopChat(...)`
   - `launcher.resolvePendingPermission(...)` → `client.resolveChatPermission(...)`
4. **Rehydration:** On view appear / activeChatID change, call
   `client.chatSessionState(chatID)` to hydrate from the daemon's live state.

## RC corrections status

| RC | Status | Test |
|----|--------|------|
| RC1 | Implemented | `sendChatMessage` dead-session detection + re-route |
| RC2 | Implemented | `getSystemPrompt()` call |
| RC3 | Implemented | Shared `GenerationGate` |
| RC4 | Implemented | Per-chat takeover (`.refused` only) |
| RC5 | Implemented | `summarizePendingMessages` for `GRDBWikiStore` |
| RC6 | Implemented | AC.4a automated XPC round-trip test |
| RC7 | Done | This doc + PLAN.md + PROGRESS.md |
| RC8 | Confirmed | 6 XPC methods |
| RC9 | Implemented | `resolvePendingPermission`, `availableThinkingOptions`, `logFileURL`, `runTotalUsage` |

## File map

| File | Role |
|------|------|
| `Sources/WikiFSEngine/ChatXPCRequests.swift` | Codable chat XPC types |
| `Sources/WikiFSEngine/QueueEventEnvelope.swift` | Extended with chat kinds |
| `Sources/WikiFSCore/Core/WikiDaemonProtocol.swift` | 6 chat XPC methods |
| `Sources/WikiCtlCore/DaemonWorkloadClient.swift` | Chat client wrappers |
| `Sources/wikid/DaemonChatHost.swift` | Daemon chat host (core) |
| `Sources/wikid/DaemonWikiState.swift` | Shared state-markdown helper |
| `Sources/wikid/WikiDaemon.swift` | Chat host lifecycle + event push |
| `Sources/wikid/main.swift` | Chat exporter methods |
| `Sources/WikiFS/Chats/RemoteChatSession.swift` | App-side @Observable mirror |
| `Sources/WikiFS/Queue/DaemonQueueEventSink.swift` | Chat envelope demux |
| `Sources/wikictl/main.swift` | `chat new/send/stop` commands |
| `Tests/.../DaemonChatHostTests.swift` | 15 daemon-side tests |
| `Tests/.../RemoteChatSessionTests.swift` | 14 client-side tests |
