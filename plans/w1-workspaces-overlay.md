# W1 Implementation Plan — Workspaces, overlay, fast-forward merge

**PR:** [#312](https://github.com/tqbf/selfdrivingwiki/pull/312) — `plans/page-versions-and-workspaces.md`
**Schema:** v31 (W0 was v30)

**Gate:** Edit a page while an ingestion runs — both land. A
deliberately-conflicting ingestion parks without corrupting main. Abandoned
workspace GCs clean.

## Codebase findings

### What exists (from W0)

- **`page_versions` (v30):** Append-only, blob-backed, ULID-ordered chain.
  `appendPageVersion` writes a new version + the denormalized `pages.body_markdown`
  mirror + a `page-content` ref (so main tracks head explicitly after the first
  versioned save; migrated root versions use MAX(id) default-active).
- **`refs` (v30):** `CHECK(kind IN ('source-content','source-derived','page-content'))`,
  no FK on `owner_id`.
- **`pageHeadVersionID`:** Ref → version_id, or MAX(id) fallback.
- **`PageUpsert.upsert`:** Shared write seam with `expectedHeadVersionID` CAS.
  Both app (`WikiStoreModel.save`) and `wikictl` go through this.
- **`PageConflictError`:** Thrown when CAS fails.

### The edit lock

- `WikiStoreModel.isAgentRunning` (line 204) — the single mutation point.
  `beginAgentRun()` / `endAgentRun()` set/clear it. The `onLock`/`onUnlock`
  callbacks on `AgentLauncher.run` / `startInteractiveQuery` wire into it.
- `shouldBlockEditStart(isAgentRunning:isIngestInProgress:)` (line 319) —
  gates both `startChat` and `continueChat`: refuses if either flag is true.
- The plan says: retire the edit lock **behind a capability flag**. W1 ships
  the workspace substrate; the flag controls whether ingestion uses it.

### How ingestion works today

- `AgentOperationRunner.runMultiIngest` → extraction (optional) → `run()` →
  `launcher.run(request:onLock:onUnlock:)`. The agent spawns and writes via
  `wikictl page upsert` (the shared `PageUpsert.upsert` seam). The edit lock
  is held for the *entire* agent run (minutes).

### What W1 changes

1. **Schema:** `workspaces` + `workspace_refs` tables (v31). Plus
   `index_body`/`index_base_version` columns on `workspaces` for the
   wiki_index singleton.
2. **Store overlay resolution:** When a workspace is active, page reads
   resolve through `workspace_refs` first (the workspace's version), falling
   back to main. This is a STORE-LEVEL concern, not a UI concern.
3. **`wikictl --workspace`:** Create / status / abandon verbs. The agent's
   `page upsert` writes go to the workspace (append version + UPSERT
   `workspace_refs`), NOT to main's `pages.body_markdown` mirror.
4. **Merge = fast-forward only:** For each `workspace_refs` row, if
   `main_head == base_version_id` → fast-forward (repoint main ref + update
   mirror). Any divergence → park `conflicted`. No diff3 yet (that's W2).
5. **Edit lock retired behind flag:** When the workspace capability is on,
   `shouldBlockEditStart` returns false (human edits go to main, agent writes
   go to the workspace). When off, the lock behavior is unchanged.

## Implementation steps

### Step 1 — Schema: `workspaces` + `workspace_refs` (v31)

```sql
CREATE TABLE IF NOT EXISTS workspaces (
    id           TEXT PRIMARY KEY,
    name         TEXT,
    status       TEXT NOT NULL DEFAULT 'open',
    activity_id  TEXT REFERENCES activities(id),
    index_body   TEXT,
    index_base_version TEXT,
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS workspace_refs (
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    kind         TEXT NOT NULL CHECK (kind = 'page-content'),
    owner_id     TEXT NOT NULL,
    base_version_id TEXT,
    version_id   TEXT NOT NULL,
    updated_at   REAL NOT NULL,
    PRIMARY KEY (workspace_id, kind, owner_id)
);
```

Fresh path + v30→v31 migration (purely additive — `IF NOT EXISTS`, no data
to backfill).

### Step 2 — Store layer: workspace CRUD + overlay reads

New `SQLiteWikiStore` methods (+ `WikiStore` protocol):

- `createWorkspace(name:activityID:) throws -> String` (returns workspace ID).
- `workspaceStatus(id:) throws -> WorkspaceStatus`.
- `abandonWorkspace(id:) throws` — set status='abandoned' + delete workspace_refs.
- `workspaceWritePage(workspaceID:pageID:title:body:) throws -> String` —
  append version + UPSERT workspace_refs (recording `base_version_id` on
  first touch = main head at that moment). Does NOT touch `pages` or main
  `refs`. Milliseconds.
- `workspaceMerge(workspaceID:) throws` — the fast-forward-only merge:
  for each `workspace_refs` row, resolve main head. If `main_head ==
  base_version_id` (or base is nil = page created in workspace) → fast-forward
  (repoint main ref + update `pages` mirror + replaceLinks/FTS). If diverged →
  park `conflicted`, abort the transaction. On success, set status='merged'.
- `workspacePageVersion(workspaceID:pageID:) throws -> String?` — resolve
  the workspace's current head for a page (overlay read).

New types:
- `WorkspaceStatus` enum: `open`, `merging`, `merged`, `conflicted`, `abandoned`.
- `WorkspaceRef` value type (workspace_id, owner_id, base_version_id, version_id).

### Step 3 — `wikictl --workspace` verbs

New `wikictl` command surface:
- `wikictl workspace create [--name X]` → creates a workspace, prints its ID.
- `wikictl workspace status --id W` → prints status + list of touched pages.
- `wikictl workspace abandon --id W` → abandons.
- `wikictl workspace merge --id W` → attempts fast-forward merge.
- `wikictl --workspace W page upsert ...` → writes to the workspace instead
  of main. The `--workspace` flag on `page upsert` routes through
  `workspaceWritePage` instead of `appendPageVersion`.
- `wikictl --workspace W page get ...` → reads from the workspace overlay
  (workspace version if touched, else main).

### Step 4 — Overlay resolution in the store

When a workspace is active (threaded as a `workspaceID: String?` parameter
through the relevant store reads), `getPage` resolves the body from the
workspace's version if a `workspace_refs` row exists, otherwise from main.
This is the mechanism that lets the agent read its own speculative writes.

The mirror: `pages.body_markdown` always reflects MAIN. Workspace writes
don't touch it. The overlay read fetches the blob from the workspace's
version_id instead.

### Step 5 — Edit lock retirement behind a capability flag

- New `WikiStoreModel.workspacesEnabled: Bool` (default false in W1; will
  flip to true after validation).
- When `workspacesEnabled`, `shouldBlockEditStart` returns false (human edits
  go to main via CAS; agent writes go to the workspace).
- When ingestion starts with workspaces enabled, `runMultiIngest` creates a
  workspace and passes `--workspace W` to the agent's `wikictl` invocations.
  After the agent finishes, the merge runs automatically (fast-forward only).
- When `workspacesEnabled` is false, behavior is unchanged (the edit lock
  still gates).

### Step 6 — Tests

- **`FreshSchemaParityTests`** — `workspaces` + `workspace_refs` exist on
  fresh DB.
- **`StoreEmissionExhaustivenessTests`** — new mutators in EMIT.
- **`WorkspaceTests`** (new):
  - Create workspace, write a page, verify main is untouched.
  - Fast-forward merge: base == main head → merges cleanly.
  - Conflict: main moved since base → parks `conflicted`.
  - Abandon: workspace_refs deleted, workspace = 'abandoned'.
  - Overlay read: workspace version seen, not main.
  - Page created in workspace (base = nil) → merges by creating the page.

### Step 7 — PROGRESS.md + PLAN.md updates

## What's NOT in W1 (deferred)

- diff3 merge (that's W2 — W1 only fast-forwards or parks).
- Conflict resolution UI (W3).
- Multiple simultaneous ingestions at scale (W4 — W1 proves the mechanism
  with one workspace at a time).
- `wiki_index` line-set three-way merge (W2).
- Workspace TTL/reaper (W4).
- The `index_body`/`index_base_version` columns are created in W1 but the
  merge logic for them is W2.
