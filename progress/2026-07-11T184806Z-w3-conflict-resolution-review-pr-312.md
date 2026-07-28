---
timestamp: 2026-07-11T184806Z
title: "2026-07-11 — W3: Conflict resolution & review (PR #312)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — W3: Conflict resolution & review (PR #312)

## Progress


**What shipped.** Phase W3 of the multi-writer concurrency plan: parked
conflicts are now persisted, queryable, and resolvable.

**Schema v32:**
- `workspace_conflicts` table (workspace_id, page_id, base_version_id,
  main_version_id, ws_version_id, created_at). When `workspaceMerge` or
  `workspaceRefresh` parks as `conflicted`, the per-page conflict details
  are persisted so they can be queried and resolved.

**Store layer** (`SQLiteWikiStore` + `WikiStore` protocol):
- `workspaceConflicts(workspaceID:)` — query persisted conflict details.
- `workspaceResolveConflict(workspaceID:pageID:body:)` — write a resolved
  body as a new workspace version + update the workspace_ref's
  `base_version_id` to current main head (so retry merge sees no
  divergence) + delete the conflict row.
- `workspaceRetryMerge(workspaceID:)` — set status back to `open`,
  then call `workspaceMerge` again. If all conflicts were resolved,
  the merge succeeds; if some remain, it parks again.

New type: `WorkspaceConflict`.

**wikictl:**
- `workspace conflicts --id W` — list per-page conflict details.
- `workspace resolve --id W --page P --body-file <path|->` — resolve.
- `workspace retry --id W` — re-open + re-merge.

**Tests:** 17 `WorkspaceTests` (3 new: conflicts persisted/queryable,
resolve+retry succeeds, second workspace merges while first parked).
Fast tier: 2184 tests pass.

**What's deferred:** Edit lock retirement behind capability flag,
`wiki_index` line-set merge (D12), slug-collision unification (D13),
workspace TTL/reaper (W4), SwiftUI conflict-review panel.

## Verification

Historical verification remains in the progress record above.
