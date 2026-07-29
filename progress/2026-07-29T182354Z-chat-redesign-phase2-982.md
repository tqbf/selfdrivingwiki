---
timestamp: 2026-07-29T182354Z
title: Chat redesign Phase 2 persistence and schema v46
branch: chat-redesign-phase2
status: complete
---

# Chat redesign Phase 2 persistence and schema v46

## Progress

Implemented Phase 2 of issue #982 in this worktree.

The store schema moved to v46 and now treats the chat subsystem as
destructively rebuildable without touching non-chat wiki data. The migration
drops and recreates chat-owned tables only, then marks Tantivy for rebuild so
stale chat search state cannot survive the reset.

Durable queued turns now have typed persistence instead of launcher-era
best-effort state. `chat_turns` stores queue order, editability, claim
ownership, provider-submission state, terminal outcomes, and the typed
context-reference payload needed by the Phase 1 domain model. The public store
surface exposes enqueue, edit, remove, claim, provider-submitted, and terminal
completion operations with explicit illegal-transition failures and idempotent
duplicate handling where the Phase 2 contract requires it.

Typed transcript persistence now lives in `chat_transcript_items`, with
cursor-based paging and a checkpoint read API. The current renderer remains on
the existing `AgentEvent` shape through a compatibility projection, so Phase 2
did not require UI or File Provider format changes.

This phase deliberately stops at the persistence/search seam. It does not
implement Phase 3 daemon controllers, Phase 4 XPC/client sync replacement,
Phase 5 UI decomposition, or Phase 6 compatibility cleanup.

## Verification

Focused verification passed after fixing the v46 migration assumption for
legacy fixtures without `wiki_metadata`:

```sh
swift test --filter 'ChatPhase2PersistenceTests|ChatStoreTests|ChatIDPersistenceTests|StoreEmissionTests|PageVersionTests'
```

Result: 108 tests passed in 5 suites.

The new coverage added in this phase includes:

- fresh-schema parity for `chat_turns` and `chat_transcript_items`
- destructive migration preservation/deletion boundaries
- durable turn ordering, idempotent enqueue, claims, provider-submission, and
  terminal transitions
- typed transcript round trips and `AgentEvent` compatibility projection
- cursor paging and transcript checkpoints
- `mutate(event:)` emission coverage for the new public chat mutators
- Tantivy rebuild-marker invalidation after destructive reset

Repository-wide verification was then rerun through the required `make` entry
points to catch stale schema-version assumptions outside the chat tests.
