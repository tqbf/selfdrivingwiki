# W2 Implementation Plan — Real merge (diff3)

**PR:** [#312](https://github.com/tqbf/selfdrivingwiki/pull/312)
**Gate:** Two overlapping ingestions (shared touched page + both touching the
index) both merge cleanly; merged page shows two-parent history.

## Implementation steps

### Step 1 — Pure diff3 engine (`Diff3.swift`)

A line-based three-way merge. Input: base, ours (main), theirs (workspace).
Output: `.clean(merged: String)` or `.conflict`. Pure, Sendable, unit-testable.

Algorithm: compute LCS between base↔ours and base↔theirs, walk the merged
sequence. Where ours and theirs both differ from base:
- If ours == theirs → take it (both made the same change).
- If only one differs → take the differing one.
- If both differ → conflict.

### Step 2 — Store layer: diff3 merge in `workspaceMerge`

When `main_head != base` (W1 parks; W2 does diff3):
1. Fetch three blobs: base (from base_version_id), ours (from main_head),
   theirs (from workspace version_id).
2. Run `Diff3.merge(base:ours:theirs:)`.
3. If clean → create a merge version: `parent_id = main_head`,
   `merge_parent_id = workspace version`, blob = merged text.
   Update pages mirror + repoint ref.
4. If conflict → park as `conflicted` (same as W1).

### Step 3 — Merge PROV activity

The merge version's activity is kind="merge" with the agent that did the
workspace work. Records `wasGeneratedBy`.

### Step 4 — Derived-data regeneration

After a successful merge, for each merged page:
- `replaceLinks` (re-parse `[[wiki-links]]` from the merged body)
- FTS triggers fire automatically (the `pages` UPDATE triggers them)
- Embeddings: `storePageChunks` (best-effort, non-fatal)

### Step 5 — `wikictl workspace refresh --id W`

Re-base the workspace against current main: for each workspace_ref, run
diff3 with the new main_head. If clean, update `base_version_id` to
current main_head and store the merged version as the workspace's new
version. If conflict, park.

### Step 6 — Tests

- `Diff3Tests`: clean merge (both changed different regions), clean merge
  (both made same change), conflict (both changed same region differently).
- `WorkspaceMergeTests` additions: diff3 merge produces two-parent version,
  two overlapping ingestions both merge, slug collision, refresh.
