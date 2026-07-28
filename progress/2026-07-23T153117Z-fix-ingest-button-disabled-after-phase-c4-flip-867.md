---
timestamp: 2026-07-23T153117Z
title: "fix: Ingest button disabled after Phase C4 flip (#867)"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Ingest button disabled after Phase C4 flip (#867)

## Progress


**Goal:** the Ingest button in `SourceDetailView` was permanently disabled
after the Phase C4 flip (#862) because its `.disabled()` still gated on
`launcher.isRunning` — a flag on the local in-process `agentLauncher` that,
post-C4, is no longer on the ingest/lint path (both are enqueued to the daemon
queue). A stale/stuck `isRunning` therefore wedged the button with no path to
clear it.

**Root cause:** `SourceDetailView.ingestButton` computed
`.disabled((isRunning && !isAnySourceIngesting) || isEditLockedExternally ||
!canIngest)`, where `isRunning` is a snapshot of `launcher.isRunning` captured
in `WikiDetailView.swift:177`. The gate pre-dated the queue architecture: it
existed to avoid a launcher preflight refusal when a lint was mid-run
in-process. After C4, ingest **and** lint go through the daemon (or local
`QueueEngine` fallback), so the local launcher's `isRunning` is disconnected
from ingest/lint state. The queue engine already serializes ingestion/
extraction and `enqueueIngestion` dedupes a source already active in the
queue — so the launcher gate is obsolete in both the daemon and fallback paths.

**Fix:** dropped the `isRunning`-based gate. Extracted the predicate into a
pure, `internal static` seam — `SourceDetailView.ingestButtonDisabled(
isEditLockedExternally:canIngest:)` (mirrors the existing
`extractionAffordance` seam) — so the regression is pinnable. The button now
disables only on `isEditLockedExternally || !canIngest`.

**Files touched:**
- `Sources/WikiFS/Sources/SourceDetailView.swift` — new
  `ingestButtonDisabled(...)` seam; `ingestButton` calls it (dropping the
  `isRunning && !isAnySourceIngesting` term); updated comment with the #867
  rationale.
- **New:** `Tests/WikiFSAppTests/IngestButtonDisabledTests.swift` — 5 tests
  pinning the decision table + the structural #867 guarantee that no launcher
  `isRunning` flag can reach the predicate.

**Verification:** `swift build` clean (after `make prompts version
keychain`); `swift test` green — 3786 tests pass, incl. the new suite.

## Verification

Historical verification remains in the progress record above.
