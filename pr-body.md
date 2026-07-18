## GRDB pilot: rewrite QueueStore with GRDB.swift

Closes #530 (Phase 1 pilot from the design doc in PR #538).

### Summary

Replaces the hand-rolled `sqlite3_*` C API calls in `QueueStore.swift` with
[GRDB.swift](https://github.com/groue/GRDB.swift) (v7.11.1), proving GRDB works
in the project before the larger `SQLiteWikiStore` migration.

### What changed

**`Package.swift`** — Added `GRDB.swift` (from: `7.0.0`) as an SPM dependency
and linked it to the `WikiFSCore` target.

**`Sources/WikiFSCore/Core/QueueStore.swift`** — Full rewrite (~550 lines, down
from ~1,015):
- **Connection:** `DatabaseQueue` (serial writer, no pool needed) replaces
  `OpaquePointer` + `NSRecursiveLock`
- **Migrations:** `DatabaseMigrator` with 3 named migrations
  (`v1_create_queue_schema`, `v2_add_item_events`, `v3_namespace_run_state`)
  replaces the `PRAGMA user_version` ladder. All migrations are idempotent
  (`IF NOT EXISTS`, `INSERT OR IGNORE`) so existing databases created by the
  old hand-rolled code are detected automatically — GRDB sees no
  `grdb_migrations` table and runs all migrations, which are no-ops on
  already-current schema.
- **Queries:** `Row.fetchAll`/`fetchOne` with named column access replaces
  `SQLiteStatement` positional `text(at: 0)` — safer, no index-shift bugs.
- **Transactions:** `dbQueue.write { db in ... }` replaces `withTransaction` /
  `BEGIN`/`COMMIT`/`SAVEPOINT` — crash-safe automatic rollback on throw.
- **Statement caching:** Deleted — GRDB handles this automatically.
- **PRAGMAs:** Applied via `Configuration.prepareDatabase` (WAL, synchronous
  NORMAL, mmap_size, cache_size, temp_store MEMORY) — matching #523.
- **Error wrapping:** `DatabaseError` is caught and rewrapped as
  `QueueStoreError.sqlite` so callers see the same error type.

**Public API is unchanged** — all 19 methods keep their exact signatures. No
caller changes required.

**Downstream fixes** — GRDB's `SQL` type is `ExpressibleByStringInterpolation`,
so it competes with `String` in string interpolation contexts in downstream
modules. Fixed by adding explicit `String` type annotations in:
- `Sources/WikiCtlCore/ChatCommand.swift` (1 site)
- `Sources/WikiCtlCore/PageCommand.swift` (1 site)
- `Sources/WikiCtlCore/SourceCommand.swift` (1 site)
- `Sources/WikiFS/Reader/ReaderMarkdown.swift` (1 site)

Used `internal import GRDB` (SE-0409) in `QueueStore.swift` to minimize the
leakage surface, though SPM still makes GRDB's module physically available to
transitive dependents.

### Verification

- `make version prompts` + `swift build` — clean compile, GRDB resolves and
  coexists with the system SQLite3 used by `SQLiteWikiStore`/`CSqliteVec`
- `swift test --filter QueueStore` — 20/20 tests pass
- `swift test --filter QueueEngine` — 22/22 tests pass
- `swift test --filter QueueExtractionTests --filter QueueEventLogTests --filter QueueIngestionTests` — 47/47 tests pass
- Full fast tier: `swift test --skip 'EnumeratorDeletionTests|SQLiteWikiStoreTests|StoreEmissionTests|FreshSchemaParityTests|SQLiteStatementLifecycleIntegrationTests|BlobVacuumTests|AgentCASTests|GenerationGateLaneTests|WorkspaceStagingTests|WorkspaceMergeCompletenessTests|IngestIsolationTests|ChatSummaryTests|ProjectionTreeTests'` — **2456 tests in 211 suites, all passed**

### Pilot success criteria (from design doc §6)

- [x] GRDB added as SPM dependency without breaking the build
- [x] QueueStore rewritten — no `sqlite3_*` calls remain
- [x] WAL, foreign keys, busy timeout, and performance PRAGMAs configured
- [x] 3-migration ladder runs correctly on fresh + existing DBs
- [x] QueueStore test suite passes unchanged
- [x] Queue engine works end-to-end with the GRDB-backed store

### Notes for reviewers

- The `internal import GRDB` is the Swift 6.0+ successor to
  `@_implementationOnly` (which would require `-enable-library-evolution` on
  WikiFSCore and all its dependencies — not worth the churn for a pilot).
  SPM still exposes the GRDB module transitively, so the 4 `String` type
  annotations are the pragmatic fix. A future Phase 3 (`GRDBWikiStore`) should
  evaluate isolating GRDB behind a dedicated target to fully prevent leakage.
- No `sqlite3_*` calls remain in `QueueStore.swift` — fully GRDB.
- The main `SQLiteWikiStore` is untouched — this PR only affects the queue DB.
