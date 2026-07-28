---
timestamp: 2026-07-18T193049Z
title: "2026-07-18 — Add \"Reveal Debug Folder\" + \"Reveal Log\" UI to the Activity window (branch `feature/reveal-debug-folder-ui`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Add "Reveal Debug Folder" + "Reveal Log" UI to the Activity window (branch `feature/reveal-debug-folder-ui`)

## Progress


**Problem:** PR #580 added `DebugRunLogger` (a verbose ACP wire-trace under
`<scratch>/debug/`), and `ChatView` already had "Reveal Log" / "Reveal Debug
Folder" buttons in its activity menu. But the standalone **Activity window**
(`ActivityWindowView`) — where users view ingestion/lint transcripts across all
wikis — had no way to reveal either the lightweight `run.jsonl` log or the
verbose `debug/` folder. The launcher's `logFileURL` / `debugFolderURL` existed
(`public private(set)`) but were only reachable from the chat view's direct
launcher reference; the Activity window works with `QueueItem` objects and the
`QueueActivityTracker`, with no per-item log-path state.

**Fix:** Threaded the run's `logFileURL` + `debugFolderURL` through the queue
event system — mirroring the existing `.usage` / `.liveUsage` event plumbing —
so the tracker stores per-item paths that the Activity window can reveal.

**Data flow:** `AppQueueIngestionProvider` → `onLogPaths` callback →
`QueueIngestionWorker` → `emitLogPaths` (via `LogPathsEmitBox`) →
`QueueEngine.makeEmitLogPaths()` → `.runPaths(QueueItem.ID, logURL:, debugURL:)`
event → `QueueActivityTracker` → `ActivityWindowView`.

**New `QueueEvent.runPaths`** case (Sendable, NOT logged to JSONL — URLs are
runtime-only, not Codable audit data). Added `runPaths` to `QueueEventType`,
`QueueLogRecord.init` (all nil fields), and the `write()` skip list — same
treatment as `.usage`.

**`QueueActivityTracker`** gained `itemLogURLs` / `itemDebugURLs` dictionaries
+ `logURL(for:)` / `debugURL(for:)` accessors. Paths persist after terminal
state (same as transcripts) so users can reveal them for recently-completed
items; cleared on prune / stop.

**`ActivityWindowView`** gained two affordances:
1. A compact `ellipsis.circle` menu (`revealMenu`) in the detail header —
   "Reveal Log" (`doc.text.magnifyingglass`) + "Reveal Debug Folder"
   (`folder.badge.gearshape`). Only shown when at least one path exists.
2. The same two items in the row context menu (after "Copy Transcript",
   behind a divider).

Both use `NSWorkspace.shared.activateFileViewerSelecting([url])` — matching
`ChatView`'s existing behavior exactly.

**Tests:** 4 new `QueueActivityTrackerRunPathsTests` (stored per-item, survive
terminal state, cleared on prune, nil paths produce nil accessors). Updated all
8 `QueueIngestionWorkerFactory` / `QueueIngestionWorker` constructor call sites
+ the `FakeIngestionProvider` mock in `QueueIngestionTests.swift`.

**Build/Tests:** `make version prompts` ✓; `swift build` clean (16s);
fast test tier **2581 tests / 219 suites pass** (4 new).

## Verification

Historical verification remains in the progress record above.
