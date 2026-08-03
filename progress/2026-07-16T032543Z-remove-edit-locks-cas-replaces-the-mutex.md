---
timestamp: 2026-07-16T032543Z
title: "Remove edit locks — CAS replaces the mutex (2026-07-11)"
branch: null
status: historical
timestamp_source: git-commit
---

# Remove edit locks — CAS replaces the mutex (2026-07-11)

## Progress


**Problem:** Starting a second chat while Chat 1 was running silently failed —
the second chat didn't even display the user's question. The root cause was
`store.isAgentRunning`, a process-wide mutex that blocked `startChat`/
`continueChat` at the preflight guard (`shouldBlockEditStart`), failing before
the chat row was created or the message was shown.

**Why the mutex existed:** Pre-CAS, it prevented last-writer-wins data races —
the in-app autosave could clobber the agent's `wikictl` writes. It paused
autosave, disabled editing UI, and blocked new chat starts.

**Why it's safe to remove now:** W0 (PR #342) introduced page versions + CAS
save (`PageUpsert.upsert` with `expectedHeadVersionID`). `WikiStoreModel.save()`
catches `PageConflictError` and surfaces a "Page Was Updated" dialog. Concurrent
writes are safe — the store detects the version mismatch.

**Changes:**
- **WikiStoreModel:** Replaced `isAgentRunning: Bool` with `agentRunCount: Int`
  (ref-counted). `agentRunStarted()` increments + flushes drafts; `agentRunEnded()`
  decrements + reloads from store when count hits 0. Removed autosave pause guards
  in `scheduleAutosave()` and `systemPromptChanged()` — CAS handles it.
- **AgentOperationRunner:** `shouldBlockEditStart` now only checks
  `isIngestInProgress` (extraction is resource-intensive, not a data-race concern).
  Removed `takeEditLock` parameter entirely. Callbacks now
  `agentRunStarted()`/`agentRunEnded()` (session lifecycle, not mutex).
- **AgentLauncher:** Removed `onTurnBoundary` parameter and handler (was the
  per-turn edit lock toggle). Renamed `releaseEditLock()` → `releaseRunLifecycle()`.
  Kept `isGenerating` (independent — drives ChatView banner + send guard) and
  the generation gate (FIFO, N=1 by default).
- **UI views:** Removed all `.disabled(store.isAgentRunning)`, `.onChange(of:
  store.isAgentRunning)`, and "Agent updating wiki…" labels from PageDetailView,
  SourceDetailView, SystemPromptDetailView, PagesListView, WikiDetailView.
- **Tests:** Updated `Issue235IngestExtractionLockTests` (predicate now 1-arg)
  and `AgentGenerationSlotTests` (ref-count assertions).

**Build/tests:** `swift build` clean; fast tier — 2187 tests pass.

---

## Verification

Historical verification remains in the progress record above.
