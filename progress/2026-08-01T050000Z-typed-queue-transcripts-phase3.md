---
timestamp: 2026-08-01T050000Z
title: Typed Queue Transcripts Phase 3
branch: feature/typed-queue-transcripts-phase3
status: complete
---

# Typed Queue Transcripts Phase 3

Phase 3 completes the atomic queue transcript cutover above Phase 2. Queue
workers capture an immutable `QueueAttemptID`; raw provider events translate at
that boundary and do not cross `QueueEvent` or XPC. The lock-backed per-attempt
state store reduces typed items, assigns ordered batches, persists first, and
broadcasts only successful durable updates.

## Progress

- Added `QueueTranscriptUpdate`, tagged canonical merge, and typed queue event
  envelope transport.
- Changed queue engine/client/daemon/XPC load APIs and all fakes to return
  `[ChatTranscriptItem]`.
- Changed retry clearing and the v6 migration; v6 drops only
  `queue_item_events`. The raw v4 fixture proves queue items, queue state,
  activity, chat, usage, log, debug, and progress rows are unchanged.
- Replaced tracker and Activity-window queue transcript state with typed items,
  canonical persisted/live merge, typed rendering, queue transcript identity,
  typed copy, and progress fallback.
- Deleted obsolete legacy queue event-store methods. The legacy `ChatWebView`
  event initializer/coordinator remains intentionally deferred to Phase 4.

## Verification

- `make build` passed and signed the development app.
- Focused Swift Testing passed: translator (11), typed store (8), migration
  (2), concurrency (8), envelope (11), client conformance (4), daemon XPC,
  presentation manifest, tracker, canonical merge, and hosted Activity tests.
- `make test` passed after the final concurrency-lock correction.
- `make lint` passed with 0 violations; `make check` passed; `git diff --check`
  passed.

## Review

Concurrency review: the state lock protects only attempt selection,
translation/reduction, batch allocation, and drainer election. SQLite and
broadcasting run unlocked; terminal closing rejects new callbacks and removes
state only after accepted batches drain. The app callback box now snapshots its
handler under a lock before invoking it.

SwiftUI/macOS review: the Activity window retains its native split-view/header
hierarchy. Its value-only presentation input keeps the typed renderer,
queue-item transcript ID, wiki-link intent, render context, blob store, copy,
and progress fallback on one tested path. The `ActivityWindowTypedTranscript`
suite hosts the real production window in an `NSWindow`.
