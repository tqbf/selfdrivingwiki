# Plan: ACP Session Lifecycle for Chat (Issue #830)

**Status:** Ready for implementation
**Prerequisite for:** Daemon Phase C (chat survives ⌘Q)
**Depends on:** Nothing new (builds on shipped #813 Phase 3 queue-side resume)
**Branch:** `feat/chat-acp-resume`

---

## 0. Summary

Today every chat continuation (`continueChat`) spawns a **fresh** ACP session
and re-seeds context via `continuationPreamble` (a condensed transcript window
pasted into the first prompt). This works but is the degraded path: it costs a
full subprocess spawn + loses tool-call history the agent can't replay from
text.

This plan makes **ACP session resume the primary path** for chat continuation,
with seeded-preamble demoted to the fallback. It mirrors the queue/ingestion
resume path shipped in #813 Phase 3 (`AgentLauncher.swift:1177-1211`,
`AgentLauncher.swift:1339-1355`), adapted for the chat lifecycle.

The work is **primarily wiring** — `ACPBackend.resume()` already exists
(`ACPBackend.swift:1188`) and handles the full `resumeSession` → `loadSession`
→ give-up cascade. What's missing is: (1) a schema column to persist the session
ID, (2) capturing it at chat spawn, (3) attempting resume on continue, and
(4) clearing it on terminal teardown.

---

## 1. Schema Migration: v42 → v43

### 1.1. Why a new column

The `chats` table currently has no place to store the ACP session ID. Queue
items store it on `QueueItemPayload.acpSessionId` (`QueueTypes.swift:86`), a
field on the codable payload. Chats need the same durability — the session ID
must survive app restart so a reopened chat can attempt resume.

### 1.2. The ALTER TABLE

```sql
ALTER TABLE chats ADD COLUMN acp_session_id TEXT;
```

Nullable: `NULL` for all existing rows (pre-migration chats have no session to
resume) and for chats where resume permanently failed (cleared — see §5).

### 1.3. Migration ladder step

**File:** `Sources/WikiFSCore/Store/GRDBWikiStore.swift`

**Step 1 — bump the constant** (`:61`):
```swift
private static let currentSchemaVersion = 43   // was 42
```

**Step 2 — add the v42→v43 migration block** after the existing v41→v42 block
ends at `:1200` (before the catch-all at `:1226`):

```swift
if version < 43 {
    if !(try Self.hasColumn("acp_session_id", on: "chats", in: db)) {
        try db.execute(sql: "ALTER TABLE chats ADD COLUMN acp_session_id TEXT;")
    }
    try db.execute(sql: "PRAGMA user_version = 43;")
    version = 43
}
```

### 1.4. Fresh-schema path

Per C1: add `acp_session_id TEXT` to BOTH:
1. `createChatTablesV23` at `:1438` (migration path)
2. `createFreshSchema` inline CREATE TABLE at `:2467` (fresh-DB path)

Both must produce identical schemas.

---

## 2. Model: `ChatSummary.acpSessionId`

### 2.1. Add the field

**File:** `Sources/WikiFSCore/Core/ChatModels.swift`

Add to `ChatSummary` (after `summaryAt`):

```swift
public var acpSessionId: String?
```

Update the `init` to accept `acpSessionId: String? = nil`.

### 2.2. Update all `ChatSummary` construction sites

Per C4, there are FIVE read paths:

| Site | File:Line | Change |
|------|-----------|--------|
| `readChatSummary` mapper | `:6545` | Read `row["acp_session_id"]`, pass to init |
| `listChats` SELECT | `:6079` | Add `c.acp_session_id` to SELECT list |
| `getChat` SELECT | `:7481` | Add `c.acp_session_id` to SELECT list |
| `listAllChatsOrderedByID` SELECT | `:6215` | Add `c.acp_session_id` to SELECT list |
| `searchSimilarChats` SELECT | `:6313` | Add or document nil acceptable |

All call `readChatSummary` which centralizes the mapping.

### 2.3. New store method: `updateChatAcpSessionId`

Routes through `mutate()` and emits a `.chat .updated` event.

### 2.4. Protocol + model wrappers

Add `updateChatAcpSessionId` to the `WikiStore` protocol and an `@MainActor`
wrapper on `WikiStoreModel`. Also add `getChat(id:)` to the protocol if missing
(it's currently only on `GRDBWikiStore`).

---

## 3. Persist at Spawn Time

### 3.1. Where to capture

After `backend.start` returns a session handle (mirroring queue-side pattern
at `AgentLauncher.swift:1339-1355`), call `onAcpSessionId?(sessionId.value)`.

Per C5: use the `onAcpSessionId` closure, NOT `chatStore?.updateChatAcpSessionId`
(the launcher has no `chatStore` property).

### 3.2. Threading the store reference

Add an optional `onAcpSessionId: (@MainActor (String?) -> Void)? = nil` parameter
to `startInteractiveQuery`. Callers wire it to the model wrapper.

---

## 4. Resume on Continue

### 4.1. The resume attempt

Before `backend.start`, if `priorAcpSessionId` is set AND the backend is
`ACPBackend`, attempt `acpBackend.resume(sessionID:profile:)`. If it returns
a handle, use it as the session instead of calling `backend.start`.

### 4.2. Threading the prior session ID

Add `priorAcpSessionId: String? = nil` to `startInteractiveQuery`.
`continueChat` passes the chat row's `acpSessionId`; `startChat` passes nil.

### 4.3. When resume succeeds — skip the preamble

On resume success, send only the user's raw message (the display text), not
the composed task prompt + preamble.

### 4.4. The flow (state machine)

```
continueChat(chatID, message)
  → read chatSummary = store.getChat(chatID)
  → read history = store.chatMessages(chatID)
  → compose firstMessage = continuationPreamble(history, message)
  → startInteractiveQuery(firstMessage, priorAcpSessionId: chatSummary.acpSessionId)
       → if priorAcpSessionId != nil:
            attempt acpBackend.resume(sessionID, profile)
            success → session = handle; first turn = raw user message
            fail/nil → session = backend.start(...); first turn = taskPrompt + preamble
```

---

## 5. Clearing the Session ID

### 5.1. When to clear

| Case | Where | Action |
|------|-------|--------|
| Chat deleted | `deleteChat` | Cascade handles it |
| `finish(status: 0)` | `AgentLauncher.finish()` | Do NOT clear for interactive sessions |
| `finish(status: -1)` | `AgentLauncher.finish()` | Do NOT clear for interactive sessions |
| Resume permanently failed | `startInteractiveQuery` | Clear via `onAcpSessionId?(nil)` |
| `startNewChat` | `AgentLauncher.startNewChat()` | Clear via ChatDetailView caller (C8) |

### 5.2. Decision: do not clear on `finish` for interactive sessions

Only clear when resume is **attempted and fails**. The queue side only clears
for one-shot runs; interactive sessions can be continued.

### 5.3. Implementation: clear on resume failure

After the resume attempt, if resume failed AND we had a prior session ID:
`onAcpSessionId?(nil)`.

### 5.4. Implementation: clear on `startNewChat`

Per C8: the `ChatDetailView` caller calls
`store.updateChatAcpSessionId(chatID: oldChatID, acpSessionId: nil)` before
transitioning to a new chat.

---

## 6. Single Source of Truth Invariant

When a chat session is live, the live ACP session is the single source of
truth for the in-progress turn. SQLite is the **durable record**, flushed at
turn boundaries. The two must never both claim authority.

---

## 7. Relationship to Existing Issues

| Issue | Relationship |
|-------|-------------|
| #825 (smarter preamble) | Complementary — preamble becomes fallback |
| #826 (persist in-flight turn) | Orthogonal — will use v44 |
| Daemon Phase C | Hard prerequisite for this |
| #813 Phase 3 (queue resume) | Reference implementation |

---

## 8. Implementation Order

### Slice 1: Schema + model (no behavior change)
### Slice 2: Persist at spawn (no behavior change)
### Slice 3: Resume on continue (behavior change)
### Slice 4: Cleanup

---

## 9. Tests

### AC.1: Migration v42→v43 adds the column
### AC.2: Fresh schema has the column
### AC.3: Round-trip write + read acpSessionId
### AC.4: listChats includes acpSessionId
### AC.5: Store emission test for updateChatAcpSessionId
### AC.6: Persist at spawn (requires FakeACPBackend — C2)
### AC.7: Resume success — preamble skipped
### AC.8: Resume failure — fallback to preamble + stale ID cleared
### AC.9: Clear on new chat

**C2 — FakeACPBackend:** FakeAgentBackend won't work because the persist block
does `backend as? ACPBackend` and `currentResumableSessionId()` is ACPBackend-
specific. Build a `FakeACPBackend` actor before writing AC.6-AC.8 tests.

**C3 — StoreEmissionExhaustivenessTests does NOT exist:** Add a per-method
`@Test` to `StoreEmissionTests.swift` instead.

---

## §13. Plan-Review Corrections (AUTHORITATIVE)

### SCHEMA VERSION COORDINATION

This plan owns v43. Issue #826 will use v44 — do NOT use v44.

### C1 [high] — Fresh-schema CREATE TABLE is in createFreshSchema

Add `acp_session_id TEXT` to BOTH `createChatTablesV23` AND `createFreshSchema`.

### C2 [high] — Need FakeACPBackend for launcher tests

FakeAgentBackend can't test the `as? ACPBackend` / `currentResumableSessionId()`
paths. Build FakeACPBackend BEFORE writing AC.6-AC.8 tests.

### C3 [medium] — StoreEmissionExhaustivenessTests does NOT exist

Add per-method `@Test` to `StoreEmissionTests.swift`.

### C4 [medium] — FIVE SELECT read paths

Update all five: readChatSummary, listChats, getChat, listAllChatsOrderedByID,
searchSimilarChats.

### C5 [medium] — Use onAcpSessionId closure, not chatStore

AgentLauncher has no `chatStore` property. Use the closure.

### C6 [medium] — Add AC.* + Acceptance Criteria

Listed in §9 above.

### C7 [low] — §4.3 sends firstMessage on resume success

For v1, sending the preamble on resume success is wasteful but not harmful.
Override to send raw user message when resumed.

### C8 [low] — §5.4 clearing on startNewChat

ChatDetailView caller calls store.updateChatAcpSessionId before transitioning.
