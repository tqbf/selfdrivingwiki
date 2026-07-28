---
timestamp: 2026-07-10T031052Z
title: "2026-07-09 — #235: Prevent silent hang when starting Edit/Ask during ingest extraction"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #235: Prevent silent hang when starting Edit/Ask during ingest extraction

## Progress


**Problem:** Starting an Edit (or Ask) session immediately after kicking off an
ingest could silently hang — the edit lock (`isAgentRunning`) only fires at
spawn commit (via `onLock`/`beginAgentRun`), which is AFTER the multi-second
pdf2md extraction phase. During extraction, the Edit preflight guard didn't see
the ingest, so Edit started — then silently queued on the generation gate with
no visible feedback (the "Waiting…" text was only a hidden `.help()` tooltip).

**Fix (two parts):**

1. **`isIngestInProgress` flag** (`WikiStoreModel`): set at the top of
   `runMultiIngest` via `beginIngest()` (BEFORE extraction), cleared on early
   exit (via `defer { if !launcher.isRunning { store.endIngest() } }`) or on
   process termination (via the ingest run's `onUnlock` callback). The Edit
   preflight (`shouldBlockEditStart`) now checks `isAgentRunning ||
   isIngestInProgress`. Ask mode is never blocked (read-only, lock-exempt).
   A separate flag avoids the self-deadlock that reusing `isAgentRunning` would
   cause (the ingest's own `run()` preflight checks `isAgentRunning`).

2. **Visible waiting caption** (`ChatView`): replaced the hidden
   `.help(sendButtonTitle)` tooltip with visible `composerCaption` text below
   the composer. When `isAwaitingGenerationSlot` is true, the user now sees
   "Waiting for the other session to finish before sending…" directly in the
   UI. Applied to both `chatSurface` and `emptyState` (draft) composer areas.

Both predicates (`shouldBlockEditStart`, `composerCaptionText`) are extracted as
static functions for unit testability. New test suite
`Issue235IngestExtractionLockTests` (11 tests) covers the full state matrix.
See [`plans/issue-235-ingest-extraction-lock.md`](plans/issue-235-ingest-extraction-lock.md).

**Tests:** `swift test --filter 'Issue235'` — 11/11 pass. Full fast-tier run:
1972/1973 pass (1 pre-existing flaky `PdfExtractionServiceTests` pipe-draining
test, unrelated, passes in isolation).

## Verification

Historical verification remains in the progress record above.
