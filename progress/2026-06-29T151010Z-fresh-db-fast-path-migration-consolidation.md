---
timestamp: 2026-06-29T151010Z
title: "2026-06-29 — Fresh-DB fast path (migration consolidation)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-29 — Fresh-DB fast path (migration consolidation)

## Progress


The stepwise ladder (v0→v14) is correct but does heavy create→mutate→drop churn
on a **fresh** DB: v7/v12 create single-row embeddings that v14 immediately
drops; v2 creates `ingested_files` that v10 renames to `sources`; v8 creates
`file_markdown_versions` that v10 renames; `source_links` is created (v10) then
rebuilt for cascade (v11). ~40 DDL statements for a fresh DB.

**Consolidation (safe):** added `createFreshSchemaV14()` — when `user_version ==
0`, build the complete current schema in ONE block and jump to v14, skipping all
the churn. The stepwise ladder is preserved verbatim as `migrate(from:)` for
EXISTING dbs (version >= 1), which MUST keep their irreversible data migrations
(renames, column adds, table rebuilds) — those cannot be collapsed without
risking existing data. Legacy index names (`ingested_files_created`,
`file_markdown_versions_file`) that survive the ladder's renames are reproduced
verbatim in the fast path.

**Parity guard:** `FreshSchemaParityTests` forces a fresh DB through the full
ladder (via a test-only `forceLadderMigration` init flag) and asserts the two
produce identical schemas (object inventory + per-table columns + FKs + version).
`swift build` clean; **1211 tests pass**.

## Verification

Historical verification remains in the progress record above.
