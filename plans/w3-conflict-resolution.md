# W3 Implementation Plan — Conflict resolution & review

**PR:** [#312](https://github.com/tqbf/selfdrivingwiki/pull/312)
**Gate:** A conflicted workspace is reviewable as a diff; a resolution
path writes into the workspace and the merge completes; a second
workspace merges while the first sits parked (no head-of-line block).

## Implementation steps

### Step 1 — Persist conflict details

Add a `workspace_conflicts` table (or columns on `workspace_refs`) to
store per-page conflict info when a workspace is parked. The conflict
data (pageID, base_version_id, main_version_id, ws_version_id) is
recorded when `workspaceMerge` parks as `conflicted`.

### Step 2 — Store layer: conflict read + resolve

- `workspaceConflicts(workspaceID:) throws -> [WorkspaceConflict]` —
  query the persisted conflict details.
- `workspaceResolveConflict(workspaceID:pageID:body:) throws` — write a
  new version into the workspace's overlay (the resolved text), then
  update the workspace_ref. After resolving all conflicts, the workspace
  can be re-merged (status → open, then call `workspaceMerge` again).

### Step 3 — wikictl conflict verbs

- `workspace conflicts --id W` — list conflict details (per-page
  base/ours/theirs version ids).
- `workspace resolve --id W --page P --body-file <path|->` — write the
  resolved body for a conflicted page.
- `workspace retry --id W` — set status back to `open` and attempt merge
  again.

### Step 4 — Tests

- `WorkspaceConflictTests`: persist conflicts, read them back, resolve
  a conflict, re-merge after resolution, second workspace merges while
  first is parked.
