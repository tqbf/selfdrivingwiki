---
timestamp: 2026-07-08T205000Z
title: "2026-07-08 — #253: Blob GC — sweep orphaned blobs"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #253: Blob GC — sweep orphaned blobs

## Progress


**Shipped (on `feature/253-blob-gc`; 1972 tests green).** Lazy reclamation of
orphaned `blobs` rows — blobs no version references. Deleting a source cascades
its `source_versions`/`source_markdown_versions` rows but leaves the blobs they
pointed at behind; `wikictl admin vacuum-blobs` now sweeps them.

**Open question resolved (§13 Q1):** **lazy-only.** No opportunistic sweep in
`deleteSource` (matches the plan's "nothing depends on eager GC"). The CLI
default is a safe **dry run**; `--apply` deletes. Nothing depends on eager GC.

**What shipped:**
- **`SQLiteWikiStore.vacuumBlobs(dryRun:)`** (+ `BlobVacuumReport`) — one
  reachability predicate (a blob is orphaned when no
  `source_versions.blob_hash` / `source_versions.thumbnail_hash` /
  `source_markdown_versions.blob_hash` cites it; each subquery filters NULLs so
  SQLite's three-valued `NOT IN` never suppresses a live orphan). Count SELECT +
  DELETE share the predicate in ONE `withTransaction`, so the report always
  matches what's reclaimed. **NO_EMIT** (added to `StoreEmissionExhaustivenessTests`'
  `noEmit`: vacuuming orphans changes no projected `ResourceKind` — blobs fold
  into the changeToken only via their version rows).
- **`AdminCommand.swift`** (new, `WikiCtlCore`) — the `admin …` family. First
  subcommand `vacuum-blobs`; `didCommit` true only when `--apply` actually
  deleted (a dry run never wakes the change bridge). Text + JSON output.
- **`ArgumentParser.swift`** — `Command.admin` case + `parseAdminCommand`;
  `Options` generalized from a hardcoded `--json` valueless flag to a
  `booleanFlags` set so `--apply` works; `usageText` gains the `admin` line.
- **`main.swift`** — `execute()` dispatches `.admin`.
- **Tests (13 new):** parser (default dry-run, `--apply`, `--json`,
  missing/unknown subcommand); store GC via the realistic add→delete→vacuum flow
  (orphan reported, dry-run no-op, `--apply` reclaims the orphan while preserving
  a referenced blob, idempotent re-run, no-op when everything referenced);
  `AdminCommand.run` dispatch (dry-run doesn't commit, apply commits, JSON parses
  + matches the report); `WikiManager` preview/apply state flow (2 in
  `WikiManagerTests`).

**Also surfaced in the app UI** (Help menu → "Vacuum Orphaned Storage…"): a
read-only dry-run preview drives a confirm `.alert` (Cancel + destructive
Vacuum; `ByteCountFormatter` for the byte count; "no orphans" empty state).
`BlobVacuumReport` + `vacuumBlobs(dryRun:)` were promoted to the `WikiStore`
protocol (the `@MainActor` model only ever calls protocol methods — no downcast);
`WikiStoreModel.performBlobVacuum` + `WikiManager.previewBlobVacuum`/
`applyBlobVacuum` wire the menu to the active wiki's store.

**Gate:** `swift test` exit 0 — 1974 tests in 160 suites. Resolves §13 Q1;
`plans/graph-model-and-versioning.md` §4.1/§13 marked shipped.

## Verification

Historical verification remains in the progress record above.
