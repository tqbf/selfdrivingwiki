# Issue #235: Prevent silent hang when starting Edit/Ask during ingest extraction

**Status:** implemented (2026-07-09).
**Issue:** https://github.com/tqbf/selfdrivingwiki/issues/235

## Problem

Starting an Edit (or Ask) session immediately after kicking off an ingest could
silently hang — no lock message, no error, no visible progress.

### Root cause

`WikiStoreModel.isAgentRunning` (the edit lock) only fires at **spawn commit**
via `onLock` → `beginAgentRun()`. The pdf2md **extraction phase** that precedes
the spawn can take seconds. During that window, `isAgentRunning` is still
`false`, so the Edit-mode preflight guard (`allowWikiEdits &&
store.isAgentRunning`) does not see the ingest and lets the Edit session start.

Once both sessions are live, they serialize via the `GenerationGate`. But the
waiting state (`isAwaitingGenerationSlot = true`) was only surfaced as a hidden
`.help()` tooltip on the send button — invisible to the user. The result: an
unresponsive UI with no explanation.

## Fix

Two independent changes:

### 1. `isIngestInProgress` flag (covers the extraction window)

Added `WikiStoreModel.isIngestInProgress` — set at the top of `runMultiIngest`
via `beginIngest()` (BEFORE extraction), cleared on early exit (via a `defer`
that checks `launcher.isRunning`) or on process termination (via the ingest
run's `onUnlock` callback).

The Edit preflight (`shouldBlockEditStart`) now checks
`isAgentRunning || isIngestInProgress`, so Edit mode blocks cleanly during
extraction. Ask mode is never blocked (read-only, lock-exempt).

**Why a separate flag instead of extending `isAgentRunning`:** The ingest's own
`run()` preflight checks `isAgentRunning` (not `isIngestInProgress`), so there
is no self-deadlock. If we reused `isAgentRunning`, `runMultiIngest` setting it
early would cause `run()` to refuse to start the ingest it was called for.

### 2. Visible waiting caption (not just a tooltip)

Replaced the hidden `.help(sendButtonTitle)` tooltip with visible caption text
below the composer (`composerCaption`). When `isAwaitingGenerationSlot` is true,
the user now sees "Waiting for the other session to finish before sending…"
directly in the UI. Applied to both the `chatSurface` and `emptyState` (draft)
composer areas.

## Files changed

- `Sources/WikiFSCore/WikiStoreModel.swift` — `isIngestInProgress` flag +
  `beginIngest()`/`endIngest()` methods.
- `Sources/WikiFS/AgentOperationRunner.swift` — `beginIngest()` at top of
  `runMultiIngest` + `defer` cleanup; `endIngest()` in ingest `onUnlock`;
  `shouldBlockEditStart` pure predicate; preflight guards use it.
- `Sources/WikiFS/ChatView.swift` — `composerCaptionText` static predicate +
  visible caption in `chatComposer` and `emptyState`.
- `Tests/WikiFSTests/Issue235IngestExtractionLockTests.swift` — new test suite.

## Long-term direction (MVCC)

The edit lock (`isAgentRunning`) could eventually be eliminated entirely via
page versioning (graph-model §14, issue #258). Sources already have append-only
version chains; extending the same model to pages would let the agent and the
user write concurrently without locking. The `GenerationGate` (API cost/rate
limit) and extraction slot (GPU/memory) would remain regardless — they are
resource constraints, not data-consistency concerns. This fix is pragmatic and
independent of that future work.
