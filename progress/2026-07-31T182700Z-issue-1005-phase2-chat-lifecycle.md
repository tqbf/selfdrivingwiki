---
timestamp: 2026-07-31T182700Z
title: Issue #1005 Phase 2 chat lifecycle persistence
branch: issue-1005-phase-2-chat-lifecycle
status: complete
---

# Issue #1005 Phase 2 chat lifecycle persistence

## Progress

`DaemonChatController` now owns persistent lifecycle writes for active chat
turns. It claims a turn with the provider/model from the exact runtime start
request, records the injected claim time, persists cumulative usage deltas only
for its active claim, and finishes the row with final usage in the terminal
transaction.

`ChatTurnUsageAccumulator` converts provider-session totals to one turn's
usage. It preserves the greatest valid token evidence, does not erase absent
fields, rejects resets, and clears cost when a currency changes. A warm runtime
uses the last accepted session snapshot as the next turn's baseline.

Terminal events pass through `finishTurnIfCurrent`. It checks generation, turn,
claim, and the in-memory terminal state before the conditional store winner.
Late completion, failure, cancellation, usage, and stale-generation events do
not replace the winning row. Bootstrap recovery finishes active rows with the
injected clock and their last persisted usage; queued rows remain queued.

## Scope

This phase changes chat lifecycle persistence only. It does not add page-source
writers, extraction canonicalization, inspector UI, or metadata hydration.

## Verification

- Focused accumulator tests passed: `DaemonChatUsageTests` (10 tests).
- Focused lifecycle tests passed: `DaemonChatControllerMetadataTests` (10 tests).
- Direct store transition tests passed: `ChatTurnMetadataStoreTransitionTests`
  (14 tests).
- `make build`, `make test`, `swift build`, and `swift test` passed. The full
  Swift test gate ran 2,825 tests in 227 suites.
- `git diff --check`, the typed-ID/raw-string audit, lifecycle-writer audit,
  and changed-file scope review passed.
