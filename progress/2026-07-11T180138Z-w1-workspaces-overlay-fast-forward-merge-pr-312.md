---
timestamp: 2026-07-11T180138Z
title: "2026-07-11 — W1: Workspaces, overlay, fast-forward merge (PR #312)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — W1: Workspaces, overlay, fast-forward merge (PR #312)

## Progress


**What shipped.** Phase W1 of the multi-writer concurrency plan: durable
workspaces for speculative ingestion branches + fast-forward-only merge.

**Schema v31:**
- `workspaces` table (id, name, status, activity_id, index_body,
  index_base_version, timestamps). Status: open → merging → merged |
  conflicted | abandoned.
- `workspace_refs` table (workspace_id, kind, owner_id, base_version_id,
  version_id, updated_at). Per-page overlay: the workspace's current head
  + the base version observed at first write (the three-way-merge base).
  `base_version_id = NULL` means the page was created in the workspace.

**Store layer** (`SQLiteWikiStore` + `WikiStore` protocol):
- `createWorkspace` — creates a durable, named workspace (status=open).
- `workspaceSummary` — read status + metadata.
- `workspaceRefs` — list all page-overlay refs.
- `workspaceWritePage` — append version + UPSERT workspace_refs. Does NOT
  touch `pages.body_markdown` or main `refs` — main is untouched until
  merge. Creates a placeholder `pages` row (empty body) for FK safety on
  workspace-created pages.
- `workspacePageVersion` — overlay read (the workspace's head for a page).
- `workspaceMerge` — fast-forward-only: for each workspace_ref, if
  `main_head == base_version_id` → fast-forward (repoint main ref + update
  mirror). If divergence → roll back the partial fast-forwards, park as
  `conflicted` in a follow-up transaction. Page-created-in-workspace
  (base=nil, no main ref) → fast-forward (update mirror + create ref).
- `abandonWorkspace` — set status=abandoned + delete workspace_refs.

New types: `WorkspaceStatus`, `WorkspaceSummary`, `WorkspaceRef`.

**wikictl:**
- `workspace create [--name N]` — creates a workspace, prints its ID.
- `workspace status --id W` — shows status + touched pages.
- `workspace abandon --id W` — abandons (GCs refs).
- `workspace merge --id W` — attempts fast-forward merge.

**Tests:** 9 `WorkspaceTests` (create, write-doesn't-touch-main, overlay
read, fast-forward merge, conflict park, abandon, page-created-in-workspace,
multi-page merge). `FreshSchemaParityTests` — fresh path matches ladder.
`StoreEmissionExhaustivenessTests` — workspace mutators in NO-EMIT
partition (invisible to FP token). Fast tier: 2167 tests pass.

**What's deferred:** diff3 merge (W2), conflict resolution UI (W3),
edit lock retirement behind capability flag (the `workspacesEnabled`
plumbing is designed but not yet wired into `AgentOperationRunner`),
`wiki_index` line-set merge (W2), workspace TTL/reaper (W4).

## Verification

Historical verification remains in the progress record above.
