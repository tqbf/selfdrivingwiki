---
timestamp: 2026-08-01T112236Z
title: Typed Queue Transcripts Phase 2
branch: feature/typed-queue-transcripts-phase2
status: complete
---

# Typed Queue Transcripts Phase 2

Phase 2 adds durable typed queue transcript storage. It keeps the legacy event
table and all old callers unchanged.

## Progress

- Added `QueueAttemptID` for an item and its immutable retry attempt.
- Added the additive v5 `queue_item_transcript_items` migration.
- Added atomic typed upsert, ordered read, and item-scoped clear APIs.
- Stored a case tag with every message, tool call, notice, and failure ID.
- Rejected stale batches inside the same store transaction as each upsert.
- Added typed storage and migration coverage. The tests cover replacements,
  shared raw IDs across item kinds, reopen order, item-scoped clear, foreign-key
  pruning, stale batches, invalid identities, and malformed stored JSON.

This phase does not change the legacy `queue_item_events` table, queue/XPC
contracts, queue engine callers, Activity-window rendering, or the final
cutover migration. Phase 3 will depend on this branch head for those changes.

## Verification

- `swift test --filter QueueStoreTypedTranscriptTests` passed with 8 tests.
- `swift test --filter QueueStoreTypedTranscriptMigrationTests` passed with 1 test.
- `swift test --filter QueueStoreTests` passed with 31 tests.
- `make build` passed.
- `make test` passed with 2,996 tests in 245 suites.
- `make lint` passed with 0 violations.
- `git diff --check` passed.

## Review

The concurrency review found no new tasks, actors, locks, streams, or mutable
shared state. `DatabaseQueue.write` remains the transaction boundary.

The Swift Testing review found isolated test databases and no test ordering
dependency. The SwiftUI and macOS reviews found no UI code in this phase.
