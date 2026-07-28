---
timestamp: 2026-07-14T142116Z
title: "2026-07-13 — wikictl author provenance (issue #397)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-13 — wikictl author provenance (issue #397)

## Progress


**Implemented.** `wikictl page upsert` now records agent/chat provenance on
every write — `created_by`/`last_edited_by` are no longer `nil` for
agent-written pages.

- **`--author <who>` flag** on `wikictl page upsert`, threaded through
  `PageCommand.Action.upsert` → `PageUpsert.upsert(author:)` →
  `createPage(createdBy:)` / `updatePage(lastEditedBy:)`.
- **`WIKI_AUTHOR` env var** auto-applies when `--author` isn't passed (mirrors
  the existing `WIKI_WORKSPACE` injection). The launcher sets it "for free" so
  agents never have to remember: chat-driven writes get `chat:<chatID>`,
  one-shot runs get `agent:<kind>` (ingest/lint/query). Explicit `--author`
  always wins. Moved `applyEnv` from `wikictl/main.swift` into
  `ArgumentParser.applyEnv` (now `public`, testable).
- **`AgentLauncher`** injects `env.WIKI_AUTHOR` into `providerHints` at both
  spawn paths (`run` one-shot, `startInteractiveQuery` chat).

**Tests added** (105 in WikiCtlCommandTests + AgentCASTests all green):
`--author` parsing; `WIKI_AUTHOR` env routing (stamps when absent, explicit
flag wins, ignored when env empty); end-to-end provenance on create + update
(create sets both, update sets only `last_edited_by`).

**Scope notes.** Workspace writes (`--workspace`) stage to `page_versions`
without `last_edited_by` (provenance flows to `pages` on merge — deferred).
Source-ingestion provenance is out of scope (#397's "consider" item). The 9
`user_version == 36` failures in the fast tier pre-exist (schema was bumped to
36 by the chat-summary #411 commit; those test expectations weren't updated) —
unrelated to this change.

See [`plans/wikictl-author-provenance.md`](plans/wikictl-author-provenance.md).

A persistent, app-wide extraction and ingestion work queue backed by a new
`queue.sqlite` in the App Group container. Items survive relaunch, schedule
across wikis with per-provider concurrency limits, and keep running when no
window is open.
Design plan: `plans/queue-engine.md`.

**What's done:** Durable queue store with crash recovery (running items reset to
queued on launch), event-driven dispatch with per-provider concurrency limits and
per-wiki ingestion invariant (one ingest per wiki at a time), pause/resume/halt/
cancel/retry controls, a JSONL audit trail (daily-rotated, 30-day retention), and
all PDF extraction now routed through the engine. The `QueueActivityTracker`
replaces the launcher's extraction slot machinery — extraction status and control
live in the UI via the tracker, not internal launcher state.

**Phase 2 — QueueEngine actor (`WikiFSEngine`):** event-driven dispatch,
per-provider concurrency limits, per-wiki ingestion invariant, local/remote
extraction limits, pause/resume/halt/cancel/retry, write-through to `QueueStore`,
`AsyncStream<QueueEvent>`, launch rehydration. 16 tests.

**Phase 3 — QueueEventLog (`WikiFSEngine`):** JSONL audit trail. Daily-rotated
`queue-YYYY-MM-DD.jsonl` under `Logs/queue/`, 30-day bounded retention, appends
across relaunches. 16 tests.

**Phase 4 — Extraction through the queue (`WikiFSEngine`):** `QueueExtractionProvider`
protocol bridges `@MainActor ExtractionCoordinator` into the headless engine.
`QueueExtractionWorker` calls `resolveExtraction` → `readiness()` → `convert()` →
`persistExtraction`. `QueueIngestSignaling` protocol for `isIngestInProgress` timing
(issue #235). `waitForCompletion(of:)` on the engine for inline-caller awaits.
`.progress` event for live extraction log. 13 tests.

**Files (1 new + 1 test):**
- `Sources/WikiFSEngine/QueueEventLog.swift` (new)
- `Tests/WikiFSTests/QueueEventLogTests.swift` (new, 16 tests)

## Verification

Historical verification remains in the progress record above.
