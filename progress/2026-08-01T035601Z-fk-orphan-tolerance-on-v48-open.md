---
timestamp: 2026-08-01T035601Z
title: Tolerate orphaned cascade rows when opening (v48 FK gate self-heal)
branch: fk-constraint-tolerance
status: complete
---

# Tolerate orphaned cascade rows when opening (v48 FK gate self-heal)

## Progress

A wiki database (`user_version=47`) would not open: the v47→v48 migration
ends in a hard `PRAGMA foreign_key_check` gate that threw on any orphaned
row, aborting the open. The operator's DB had 8 violations, all
`ON DELETE CASCADE` children of one deleted `sources` row (`source_chunks`,
`source_search`, `source_markdown_versions`, `source_versions`) that survived
because the parent was deleted while foreign-key enforcement was off.

`GRDBWikiStore.migrateV47ToV48` now does **repair-then-recheck**: when the
gate reports violations, `reconcileCascadingOrphans(in:)` completes the
cascade cleanup that should have run — deleting children whose parent row no
longer exists, restricted to `ON DELETE CASCADE` FKs (driven generically by
`foreign_key_check` + `foreign_key_list`, so it handles composite keys and
`WITHOUT ROWID` tables). The gate then re-checks; non-cascade orphans and
other corruption still abort, so genuinely unrepairable damage is not masked.

This is the only place orphans block opening (post-v48 there is no open-time
FK check, and cascades run normally), so the fix is necessary and sufficient.

## Verification

- `swift test --filter SchemaV48MigrationTests` — 39 tests pass, including two
  new ones: `orphanedCascadeChildrenAreRepairedAndMigrationSucceeds` and
  `nonCascadeOrphanStillAbortsMigration`.
- `make test` — full suite, 2951 tests pass.
- Compiled fix verified against a copy of the operator's real v47 DB (8
  cascade orphans): opened cleanly to `user_version=48` with a 0-row
  `foreign_key_check`. The live DB will be auto-repaired on next app launch.
