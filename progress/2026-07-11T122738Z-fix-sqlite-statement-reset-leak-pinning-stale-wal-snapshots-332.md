---
timestamp: 2026-07-11T122738Z
title: "2026-07-11 — Fix: SQLite statement reset leak pinning stale WAL snapshots (#332)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — Fix: SQLite statement reset leak pinning stale WAL snapshots (#332)

## Progress


**Problem:** Cached SELECT statements across 18 functions (26 leaking statements)
in `SQLiteWikiStore.swift` used a "reset-before-use" idiom (`stmt.reset()` before
`bind`/`step`) that cleared the *previous* call's leftover but left the
*current* call's statement stepped-to-`SQLITE_ROW` (busy) when the function
returned. A busy statement holds an implicit read transaction open, pinning the
connection's WAL read snapshot. After an external writer (`wikictl`, another
store instance) commits, the pinned snapshot is stale — subsequent reads return
old data and `BEGIN IMMEDIATE` fails with `SQLITE_BUSY_SNAPSHOT`.

**Fix (Phase 1):** At every affected site, replaced the leading `stmt.reset()`
with `defer { stmt.reset() }` immediately after `try statement(...)`. This bounds
the statement's read transaction to the call, covering success, early-return, and
throw paths uniformly. Also converted the migration-loop statements
(`resolveVersion`/`resolveVersionMax`) and fixed `revertProcessedMarkdown`, which
stepped a `target` statement to ROW before entering `withTransaction` — added an
explicit `target.reset()` after extracting values so the read snapshot is released
before `BEGIN IMMEDIATE`.

**Guard (Phase 2):** Added `SQLiteStatement.isBusy` (wraps `sqlite3_stmt_busy`),
an internal `assertNoBusyStatements()` method (iterates the statement cache,
throws if any is busy), and a `_testProbeBusyStatement()` test seam. The guard
fires at the top of `withTransaction` at depth 0 (`#if DEBUG` only) — before
`BEGIN IMMEDIATE`.

**Tests (Phase 3):** New `SQLiteStatementLifecycleTests` suite (not
`.integration`-tagged → runs in CI): `noBusyStatementsAfterReads` (Test 1,
deterministic — exercises every fixed site via public callers, asserts no busy
statement), `detectsBusyStatement` (AC.2 — verifies the guard throws). Integration
suite `SQLiteStatementLifecycleIntegrationTests` (`.integration`-tagged):
multi-connection WAL write-lock and read-only stale-snapshot tests.

**Documentation (Phase 4):** Updated `docs/skills/sqlite-concurrency/SKILL.md`
(new §7 on statement lifetime discipline), `AGENTS.md` (rule addition to the
SQLite concurrency bullet), CI skip regex in `.github/workflows/ci.yml`.

**Files changed:**
- `Sources/WikiFSCore/SQLiteStatement.swift` — added `isBusy`
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — 18 functions + migration + `revertProcessedMarkdown` fixed; `assertNoBusyStatements()` + `_testProbeBusyStatement()` added; guard in `withTransaction`
- `Tests/WikiFSTests/SQLiteStatementLifecycleTests.swift` — new test file
- `docs/skills/sqlite-concurrency/SKILL.md`, `AGENTS.md`, `.github/workflows/ci.yml` — documentation + CI

## Verification

Historical verification remains in the progress record above.
