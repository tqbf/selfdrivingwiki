---
timestamp: 2026-07-12T193701Z
title: "2026-07-12 — Multi-Writer Hardening: All 7 Phases Complete"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-12 — Multi-Writer Hardening: All 7 Phases Complete

## Progress


**All 7 phases of the multi-writer hardening plan are implemented.** The
design doc lives at `docs/design-plans/2026-07-12-multi-writer-hardening.md`;
the implementation plan is at `plans/multi-writer-hardening.md`.

**Phase 0 (hotfix):** Fixed `vacuum-blobs --apply` data-loss bug —
`orphanBlobPredicate` was missing `page_versions.blob_hash`, deleting live
page-history blobs.

**Phase 1: Agent CAS writes.** `page get --json` outputs
`head_version_id`; `page upsert --expect-head <ver>` CAS-protects writes
(exit code 3 on conflict). Agent prompts updated with read→expect→retry-once
discipline. Blind upsert behavior preserved.

**Phase 2: Lane-aware generation gate.** `GenerationGate` split into
`.ingest` (limit 1) and `.interactive` (limit 3) lanes — a long ingest no
longer blocks chat. Cancellation safety preserved per-lane.

**Phase 3: Head-ref invariant (v34).** Every page now has an explicit
`page-content` ref from birth (`createPage` seeds root version + ref).
v34 migration backfills refs for existing pages, seeding root versions
where needed. MAX(id) fallback demoted to logged assertion.

**Phase 4: Autosave amend + version GC.** Same-actor saves within 5s
coalesce via amend (no new version row). `vacuumPageVersions` deletes
unreachable versions. Also fixed `orphanActivityPredicate` (missing
`page_versions.activity_id` edge).

**Phase 5: Workspace created-page staging (v35).** `workspace_refs`
rebuilt with nullable `version_id` + `blob_hash` + `title`. Created pages
stage as blob+title (no phantom `pages` row, no changeToken movement,
no abandon residue). Merge mints the `pages` row + root version.

**Phase 6: Merge completeness.** `workspaceMerge` returns merged page IDs
for post-merge re-embedding. Wiki-index line-set three-way merge using
`Diff3`. Ingest-completion log entry appended after successful merge.

**Phase 7: Ingest isolation behind flag.** `--workspace W` on `page
upsert`/`page get`/`index set`; `WIKI_WORKSPACE` env var for the agent
subprocess. `workspacesEnabled` flag (default off).
`reapStaleWorkspaces` on app launch (24h TTL).

## Verification

Historical verification remains in the progress record above.
