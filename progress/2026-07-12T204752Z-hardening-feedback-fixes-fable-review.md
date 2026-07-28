---
timestamp: 2026-07-12T204752Z
title: "2026-07-12 — Hardening Feedback Fixes (Fable Review)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-12 — Hardening Feedback Fixes (Fable Review)

## Progress


Addressed 3 failing tests + 2 latent Phase-7 defects from the Fable review of
the multi-writer hardening commit (`de539d7`).

**3 failing tests (all CI-skipped `SQLiteWikiStoreTests`):**
1. `changeTokenAdvancesOnEveryMutation` — test expected `refsGenSum` unchanged
   after `deletePage`, but the hardening commit correctly cascades the page's
   `page-content` ref on delete. Fixed the test literal + comment.
2. `migrateV28ToV29RewritesAskChatsToEdit` — v29→v30 refs rebuild queried a
   `refs` table absent from the chats-only fixture. Added table-existence guard
   (create fresh if missing), matching the v30 `hasPages` convention.
3. `migrateV19ToV20_hashesContentIntoBlobsAndDropsContentColumn` — v32→v33's
   `tableColumnInfo("pages")` and v33→v34's backfill against a sources-only
   fixture. Added `sqlite_master` existence guards on both steps.

**Latent defect 1 (Phase 7): `workspaceWritePage` status guard.** Writes to a
`merged`/`conflicted`/`abandoned` workspace succeeded silently. Added a
`status == 'open'` guard (one query) at the top of the transaction. Two tests
added to `WorkspaceStagingTests`.

**Latent defect 2 (Phase 7): `WIKI_WORKSPACE` global `setenv`.** The env var
was process-global, leaking to chat-edit agents spawned mid-ingest via the
interactive lane. Replaced `setenv`/`unsetenv` in `AgentOperationRunner` with
per-spawn environment injection: `workspaceID` threaded through
`AgentLauncher.run()` → `providerHints["env.WIKI_WORKSPACE"]` →
`ACPBackend.start` (already handled `env.*` prefix) +
`ClaudeCLIBackend.start` (added `env.*` expansion). `OperationCommand.environment`
changed `let` → `var` to enable post-construction injection. This also fixes
the cancelled-while-queued stale-env-var case (no global state to leave stale).

All 55 `SQLiteWikiStoreTests` + `WorkspaceStagingTests` pass. Full fast-tier
CI (2349 tests) passes.

## Verification

Historical verification remains in the progress record above.
