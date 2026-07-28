---
timestamp: 2026-07-11T190836Z
title: "2026-07-11 — W4: Concurrency at scale (PR #312)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — W4: Concurrency at scale (PR #312)

## Progress


**What shipped.** Phase W4 (final) of the multi-writer concurrency plan:
configurable N-throttle + workspace reaper.

**Configurable N-throttle** (`GenerationGate`):
- `maxConcurrent` parameter (default 1, backward-compatible). When N > 1,
  up to N generations run simultaneously. This is a resource-management
  concern, not a correctness concern (workspaces handle correctness).
- Replaced the single-slot `held` bool with `activeCount` + `maxConcurrent`.
  `acquire()` checks `activeCount < maxConcurrent`; `release()` decrements
  `activeCount` on no-waiter path, hands off (keeps count) on waiter path.

**Workspace reaper** (`SQLiteWikiStore` + `WikiStore` protocol):
- `reapStaleWorkspaces(ttl:)` — mark any workspace with status `open`
  whose `updated_at` is older than the TTL as `abandoned` (crashed/abandoned
  runs). Deletes workspace_refs + workspace_conflicts for each reaped ws.
  Returns the count reaped.
- `wikictl workspace reap [--ttl <seconds>]` (default 3600s).

**Tests:** 3 `GenerationGateThrottleTests` (single-slot blocks, two-slot
allows concurrent, release frees for waiter) + 2 new `WorkspaceTests`
(reap abandons stale, reap doesn't touch active). Fast tier: 2189 tests.

**What's deferred (stretch goals):** Read-set PROV recording + "cites
since-changed content" lint, merge-queue fairness (rebase-don't-abort),
SwiftUI conflict-review panel, edit lock retirement behind capability flag
in `AgentOperationRunner`, `wiki_index` line-set merge (D12),
slug-collision unification (D13). The core multi-writer concurrency arc
(W0–W4) is complete.

## Verification

Historical verification remains in the progress record above.
