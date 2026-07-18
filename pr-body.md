## Summary

`GRDBWikiStore` previously used a single consolidated `DatabaseMigrator` with one `IF NOT EXISTS`-guarded `createFreshSchema` migration. This was unsound for existing wiki databases (produced by `SQLiteWikiStore` at `PRAGMA user_version` 1-37): those DBs have no `grdb_migrations` table, so the migrator would treat every migration as "unrun" -- but `IF NOT EXISTS` guards cannot reproduce the data-backfill steps (v18 name sanitize, v19 content_hash backfill, v20-23 graph-model CAS-moves, v29 chat-kind sweep, v33->34 ref seeding). Those steps MUST actually run once for a genuine upgrade.

This PR replaces the `DatabaseMigrator` with a faithful translation of `SQLiteWikiStore`'s proven 37-version `PRAGMA user_version` ladder, using GRDB's `db.execute(sql:)` / `db.execute(sql:arguments:)` / `Row.fetchAll` / `db.inTransaction(.immediate)` APIs.

## Changes

- **`migrateIfNeeded(_:)`** -- reads `PRAGMA user_version`; fresh DB (v0) -> `createFreshSchema` + stamp to v37; existing DB -> runs the stepwise ladder. Mirrors `SQLiteWikiStore.bootstrapSchema`.
- **`migrate(from:in:)`** -- all 37 steps (`if version < N` guards), faithfully translated:
  - `exec(sql)` -> `db.execute(sql: sql)`
  - `statement` + `bind` + `step` -> `db.execute(sql:arguments:)` (one-shot)
  - cursor `while step()` loops -> `Row.fetchAll` into Swift array first (avoids stepping a cursor across other statement ops on the same connection)
  - `withTransaction` -> `db.inTransaction(.immediate)` with `return .commit`
  - `queryScalarText` COUNT checks -> `Int.fetchOne`
- **Data-migration helpers** translated verbatim: `migrateV19ToV20`, `migrateV20ToV21`, `migrateV21ToV22`, `migrateV22ToV23`, `migrateV28ToV29`, `migrateV29ToV30`, `migrateV32ToV33`, `migrateV33ToV34`, `migrateV34ToV35`, `migrateV35ToV36`, `sanitizeStoredNames`, `backfillContentHashes`.
- **Schema introspection helpers**: `hasColumn`, `hasIndex`, `tableExists`, `tableColumnInfo`, `queryScalarText` -- GRDB equivalents of the `SQLiteWikiStore` privates.
- **Shared table builders** extracted as `static func`s (`createObjectsTablesV20`, `createPageVersionsV30`, `createWorkspacesV31`, `createWorkspaceConflictsV32`, `createChatTablesV23`, `createChatSearchTables`, `createWikiMetadataTable`) for fresh-path + migration-step parity.
- **`healCorruptFTSIndexes`** -- FTS5 corruption heal-and-retry path (mirrors `SQLiteWikiStore.bootstrapSchema`'s SQLITE_CORRUPT catch).
- **`_Locked` resolver variants** (`resolveTitleToIDLocked`, `resolveSourceByNameLocked`, `resolveChatByTitleLocked`) -- take a `Database` directly to avoid `dbQueue.read` re-entry deadlock inside the migration (DatabaseQueue is serial, not reentrant).

## Implementation notes

- Uses `writeWithoutTransaction` (not `write`) in init: the proven ladder commits each step independently. If we wrapped the whole migration in one outer transaction, a failure in step N+1 would roll back steps 1..N (and their `user_version` bumps), forcing a full restart-from-scratch on retry.
- Per-step `PRAGMA user_version = N` stamping inside each helper's transaction matches `SQLiteWikiStore`'s proven behavior -- a retry can resume from the last successfully-stamped version.
- The SQL is preserved verbatim from the proven ladder -- only the API calls change.

## Test plan

- [x] `swift build` passes
- [x] Fast test tier passes (2462 tests, 211 suites)
- [ ] Integration tests (run via `swift-integration` CI job)
