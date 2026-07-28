---
timestamp: 2026-07-18T204442Z
title: "2026-07-18 — Persist queue activity (usage, log/debug paths, progress) across app restart (branch `fix/queue-activity-persistence`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Persist queue activity (usage, log/debug paths, progress) across app restart (branch `fix/queue-activity-persistence`)

## Progress


**Problem:** In the Activity window (Queue / agent view), per-item info about
**ingestion + lint** runs — the usage summary line ("2:32 PM · 1m 3s · Claude ·
797 tokens in · …"), the "Reveal Log"/"Reveal Debug Folder" buttons, and the
extraction progress text — was shown while the app ran but **lost on restart**.
Quit + relaunch and all that activity info vanished.

**Root cause confirmed:** `QueueActivityTracker` (a `@MainActor @Observable`
class) holds ALL per-item activity in in-memory dictionaries
(`itemUsage`, `itemLogURLs`, `itemDebugURLs`, `progressLogs`, `transcripts`)
that are cleared on `stop()` and never rehydrated on launch. The transcripts
were the **partial exception**: write-through already existed
(`QueueEngine.makeEmitTranscript` → `QueueStore.appendItemEvent`) and the
detail view already lazy-loaded them via `engine.loadTranscript(for:)` on
open. But **usage, log/debug URLs, and progress logs were neither written to
the DB nor rehydrated** — so they evaporated with the process. (`todayUsage`
already persisted via UserDefaults; the transient running-state sets
`extractingSourceIDs`/`ingestingSourceIDs`/`lintingItemIDs`/… are correctly
not persisted — they rebuild from live `.started` events after
`resetRunningToQueued()`.)

**Fix:** made the engine write those three streams through to `QueueStore`
as they arrive, and rehydrate them into the tracker at launch.

- **v4 GRDB migration (`v4_add_item_activity`)** — new `queue_item_activity`
  table keyed by `item_id` (FK → `queue_items(id) ON DELETE CASCADE`, so rows
  vanish with their item on `pruneHistory` — mirrors `queue_item_events`):
  `usage_json TEXT`, `log_url TEXT`, `debug_url TEXT`, `progress_log TEXT`,
  `updated_at INTEGER`.
- **Module boundary:** `SessionUsage` lives in `WikiFSEngine`; `QueueStore`
  lives in `WikiFSCore` (which `WikiFSEngine` depends on, not vice-versa). So
  the store stores `usage_json` as an opaque `String` (a new
  `QueueStore.QueueItemActivity` DTO of raw `String?`s); the engine
  encodes/decodes `SessionUsage` ↔ JSON (`SessionUsage` gained `Codable`).
- **Write-through seams (engine emit closures):**
  - `makeEmitUsage` → `upsertItemActivity(usageJSON:)` (final cumulative usage).
  - `makeEmitLogPaths` → `upsertItemActivity(logURL:debugURL:)` (absoluteString).
  - `makeEmitProgress` → `appendItemProgress(line:)` (newline-appended, mirrors
    the tracker's in-memory accumulation).
  - The upsert is COALESCE-partial — each field is set by a different event
    (usage fires once on `.usage`, paths once on `.runPaths`), so updating one
    never clobbers the others.
- **Rehydrate seam:** `QueueActivityTracker.rehydrate(from:)` (called at launch
  in `WikiFSApp` right after `attach`, in a `Task`) calls
  `QueueEngine.loadAllActivitySnapshots()` (which reads
  `store.loadAllActivity()` and decodes usage JSON / reconstructs URLs) and
  repopulates `itemUsage`/`itemLogURLs`/`itemDebugURLs`/`progressLogs`. The
  tracker stays the single owner of observable UI state. Typed **transcripts**
  are deliberately NOT bulk-loaded — the detail view already lazy-loads each
  item's transcript via `engine.loadTranscript(for:)`, avoiding pulling
  `recentLimit × maxTranscriptEvents` events into memory at launch.

**Concurrency:** `rehydrate` is `@MainActor async` — it awaits the engine actor
for the read (returns a `[ID: ActivitySnapshot]` of `Sendable` values), then
mutates MainActor dicts. The emit closures capture `store` (`@unchecked
Sendable`, GRDB-serialized) and write from worker Tasks — the same pattern
`makeEmitTranscript` already used. Errors are `do/catch` → `DebugLog.store`
(no bare `try?`).

**Known limitation (pre-existing, not introduced):** on `retryItem`, old
activity (and old transcript events) are not cleared, so a retried run's
summary/progress can show stale-then-new data. Matches the existing transcript
behavior; clearing on retry is a separate follow-up.

**Tests added:**
- `QueueStoreTests` (+5): activity survives close+reopen; COALESCE preserves
  existing fields; progress appends with newline; activity cascades on prune
  (`maxPerQueue: 0`); `loadAllActivity` returns all rows.
- `QueueActivityTrackerRehydrateTests` (+2): a fresh engine+tracker over the
  SAME `queue.sqlite` rehydrates usage (JSON→`SessionUsage` round-trip),
  log/debug URLs (`absoluteString`→`URL`), and progress; empty DB leaves the
  tracker empty.

**Build/Tests:** `make version prompts` ✓; `swift build` clean (181s); targeted
QueueStore/tracker suites 31/31 pass; fast tier **2603 tests / 222 suites**
pass; full `swift test` **2789 tests / 235 suites pass** (incl. the 13
integration suites — 0 failures).

## Verification

Historical verification remains in the progress record above.
