---
timestamp: 2026-07-23T014314Z
title: "feat: Persist in-flight chat turn incrementally (#826)"
branch: null
status: historical
timestamp_source: git-commit
---

# feat: Persist in-flight chat turn incrementally (#826)

## Progress


**Goal:** a partial assistant turn survives an app close / crash mid-generation.
Streamed `.assistantText` is checkpointed to SQLite every ~2s during generation
— not only at turn completion — so a hard kill no longer drops the in-flight row.

**Plan:** `plans/inflight-persist.md` (with §13 Plan-Review Corrections C1-C8,
all applied).

**Key design — draft-handle upsert:** a streaming row is checkpointed as a
**draft row** (`is_draft=1`). The first checkpoint INSERTs (next `seq`, new
ULID `id`); subsequent checkpoints UPDATE the same row's `event_json`/`text` in
place (manual SELECT/INSERT/UPDATE inside `mutate()` — C5, matching
`appendChatMessages` style). Finalize at turn-end sets `is_draft=0` and bumps
`chats.updated_at`. The stable identity is a **draft handle** (a ULID generated
by the launcher when the streaming row is created).

**Corrections applied:**
- **C1:** schema migration is v43→v44 (NOT v43 — #830/#849 own v43 for
  `chats.acp_session_id`). `currentSchemaVersion` = 44.
- **C2 (critical):** the checkpoint sink returns `-> Bool`; the launcher
  advances `persistedEventCount` to `streamingRowIndex + 1` ONLY on success
  (not on failure). On failure, `streamingRowDirty` stays `true` so the next
  checkpoint retries — no silent data loss.
- **C3:** multi-block turns (assistant → tool → assistant): when a new streaming
  block starts while `streamingDraftHandle != nil`, the old handle is finalized
  before the new one is assigned (`streamingRowIndex` tracks the draft row even
  when it's not `events.last`).
- **C5:** manual SELECT/INSERT/UPDATE inside `mutate()`, not ON CONFLICT.
- **C6:** draft checkpoints (isDraft=true) do NOT bump `chats.updated_at` —
  only finalize does — so the chat list doesn't re-sort every ~2s.
- **C7:** `.thinkingDelta` scoped OUT for v1 (assistant-only).
- **C8:** `finalizeStaleDrafts(forChat:)` called in `continueChat` to clear
  stale `is_draft=1` rows from an interrupted turn.

**Files touched:**
- **Schema + store:** `Sources/WikiFSCore/Store/GRDBWikiStore.swift`
  (v43→v44 migration ladder step + fresh-schema DDL for `is_draft` +
  `draft_handle` + partial unique index; `checkpointStreamingMessage`
  upsert mutator via `mutate()`; `finalizeStaleDrafts` mutator;
  `chatMessages` read path decodes `is_draft`),
  `Sources/WikiFSCore/Store/WikiStore.swift` (protocol: added
  `checkpointStreamingMessage` + `finalizeStaleDrafts`),
  `Sources/WikiFSCore/Store/WikiStoreModel.swift` (`checkpointStreamingMessage`
  passthrough returning `Bool` + `finalizeStaleDrafts` passthrough),
  `Sources/WikiFSCore/Core/ChatModels.swift` (`ChatMessage.isDraft` field).
- **Launcher:** `Sources/WikiFSEngine/AgentLauncher.swift` (new state:
  `streamingRowDirty` / `streamingDraftHandle` / `streamingRowIndex` /
  `checkpointTimer` / `streamingCheckpointSink`; `mergeOrAppend` sets dirty +
  handle + index in `.assistantTextDelta` and `.assistantText` finalize;
  `scheduleCheckpoint()` ~2s timer rearmed on each fire;
  `checkpointStreamingRow(finalize:)` calls the sink and advances the cursor
  to `streamingRowIndex + 1` only on success; turn-end finalize before
  `flushTranscript`; `finish()` backstop finalize; resets in
  `resetRunArtifacts()` / `startNewChat()` / `finish()`).
- **Wiring:** `Sources/WikiFSEngine/AgentOperationRunner.swift`
  (`onStreamingCheckpoint` sink wired at both `startChat` + `continueChat`
  call sites; `finalizeStaleDrafts` called before `chatMessages` in
  `continueChat`).
- **Tests:**
  `Tests/WikiFSTests/StreamingCheckpointStoreTests.swift` (new — 14 store
  tests: AC.6 insert/update, AC.7 finalize clears draft, idempotency,
  independent handles, C8 finalizeStaleDrafts, AC.1 partial survival, AC.4
  retry, isDraft read path, C6 updated_at),
  `Tests/WikiFSAppTests/ChatPersistenceTests.swift` (5 new cursor tests: AC.3
  checkpoint excludes streamed row from tail, AC.4 failure keeps row in tail,
  AC.5 multi-block, tool-only no-op, in-place growth),
  `Tests/WikiFSTests/StoreEmissionTests.swift` (2 new: `checkpointStreamingMessageEmitsChatUpdated`
  + `finalizeStaleDraftsEmitsChatUpdated`).
- **Pre-existing test updates:** `ChatStoreTests.swift`,
  `SystemPromptTests.swift`, `MessageSummaryTests.swift`,
  `PageVersionTests.swift` — version-43 assertions updated to 44.

**Acceptance criteria:**
- AC.1 partial turn survives simulated hard kill → `partial_checkpoint_row_survives_independently` ✓
- AC.2 finalized turn has is_draft=0 → `finalize_clears_draft_flag` ✓
- AC.3 checkpoint excludes streamed row from turn-end flush → `checkpoint_excludes_streamed_row_from_turn_end_tail` ✓
- AC.4 checkpoint failure does not lose row (C2) → `checkpoint_failure_keeps_row_in_tail` + `re_checkpoint_after_prior_failure_succeeds` ✓
- AC.5 multi-block turn finalizes each streamed row (C3) → `multi_block_turn_finalizes_each_streamed_row` ✓
- AC.6 store upsert insert/update → `first_checkpoint_inserts_draft` + `second_checkpoint_updates_same_row` ✓
- AC.7 finalize clears is_draft → `finalize_clears_draft_flag` ✓
- AC.8 store emits ResourceChangeEvent → `checkpointStreamingMessageEmitsChatUpdated` ✓

**Verified:** `make version prompts && swift build` clean; `swift test` —
3693 tests in 305 suites passed (22.4s). 21 new tests pass via
`swift test --filter 'StreamingCheckpoint|ChatPersistence|StoreEmission.*[Cc]heckpoint|StoreEmission.*[Dd]raft'`.

---

## Verification

Historical verification remains in the progress record above.
