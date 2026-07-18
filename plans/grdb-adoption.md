# GRDB.swift Adoption Evaluation (#530)

> **Status:** Design research — not implementation. This document evaluates
> whether to replace the hand-rolled SQLite plumbing with
> [GRDB.swift](https://github.com/groue/GRDB.swift) and recommends an adoption
> strategy.

## Executive summary

**Recommendation: Option D (phased adoption)** — adopt GRDB as the database
foundation, starting with a QueueStore pilot, then expanding to new features,
then a parallel `GRDBWikiStore` conformance, and finally retiring
`SQLiteWikiStore`.

GRDB can replace every piece of hand-rolled plumbing (statements, pools,
transactions, migrations, observation) while preserving the load-bearing
`mutate()` seam and the `WikiEventBus`. The `mutate()` seam survives as a thin
wrapper around `dbQueue.write { }`, and the event bus survives as-is —
`ValueObservation` is a complement, not a replacement, because
`ResourceChangeEvent` carries domain metadata (kind/id/change/seq) that
GRDB's table-level observation cannot synthesize.

The full migration is ~2–4 weeks of focused work for a parallel
implementation, gated by the existing 2,400+ test suite running against both
stores. The risk is real (the store is the source of truth) but manageable
because the protocol boundary (`WikiStore`, 88 methods) means the model and UI
are untouched — a regression is caught at the store conformance level, not in
user-facing code.

---

## 1. GRDB feature mapping

| Concern | Current (hand-rolled) | GRDB equivalent | Lines saved |
|---|---|---|---|
| Prepared statements | `SQLiteStatement` (136 lines) + manual `statements: [String: SQLiteStatement]` cache | Automatic per-`Database` statement cache (`StatementCache`) — `db.cachedStatement(sql:)` | ~136 |
| Connection pooling | `WikiReadPool` (74 lines) — manual checkout/checkin, 3 idle connections | `DatabasePool` — 1 writer + N readers, snapshot isolation, automatic | ~74 |
| Transactions | `withTransaction` (52 lines) — depth-0 `BEGIN IMMEDIATE`, nested `SAVEPOINT` | `db.inTransaction(.immediate)` + `db.inSavepoint` — reentrant, automatic rollback | ~52 |
| Row decoding | `stmt.text(at: 0)` positional (301 call sites) | `Row.decode(MyStruct.self)` (Codable) or `row["title"]` named access | ~301 mechanical changes |
| Migrations | `migrate(from:)` — 37-version ladder, ~1,600 lines | `DatabaseMigrator` — named migrations, auto-tracked via `grdb_migrations` table | ~1,600 (collapses to declarative registration) |
| Observation | `WikiEventBus` (151 lines) + `ChangeCoalescer` (62 lines) + `mutate()` seam (23 lines) | `ValueObservation` (complement) + `TransactionObserver` — fires after commit | `mutate()` seam stays (thin wrapper); event bus stays (domain metadata) |
| FTS5 | Raw SQL strings — 21 trigger+vtable definitions | `Database.add(tokenizer:)`, raw SQL still available for external-content tables | ~0 (SQL is identical; GRDB adds tokenizer support) |
| PRAGMA tuning | `configurePragmas()` + `applyPerformancePragmas()` (~35 lines) | `Configuration` — `journalMode`, `synchronous`, `prepareDatabase` closure | ~35 |
| Custom extensions | `registerVec(on:)` — raw `sqlite3*` call | `Configuration.prepareDatabase { db in ... db.sqliteConnection }` | ~0 (same C call, different invocation site) |
| Busy timeout | `PRAGMA busy_timeout=5000` | `Configuration.busyMode = .timeout(5)` | ~2 |
| Checkpoint/close | `checkpointAndClose()` — explicit TRUNCATE + `sqlite3_close` | `Database.checkpoint(.truncate)` + automatic close on deinit | ~15 |

**Total plumbing eliminated:** ~2,000 lines of infrastructure code (statements,
pools, transactions, PRAGMAs, checkpoint helpers). The remaining ~7,000 lines
of `SQLiteWikiStore` are domain logic (queries, schema definitions, search
ranks, CAS dedup) that would be translated, not eliminated.

### What GRDB does NOT replace

1. **The `mutate()` seam** — GRDB's `DatabaseQueue` serializes writes through
   a dispatch queue (equivalent to our recursive lock), but the
   compute-while-locked / flush-after-unlock discipline is our application
   logic. GRDB's `TransactionObserver` fires after commit but carries no
   domain metadata (kind/id/change). The `mutate()` seam survives as a thin
   wrapper (§2).

2. **`WikiEventBus` + `ResourceChangeEvent`** — `ValueObservation` observes
   table-level changes and delivers fresh values; it does not carry
   `(wikiID, kind, id, change, seq)` metadata. The File Provider projection
   scopes invalidation by `kind`/`id`. The event bus survives; GRDB's
   `TransactionObserver` could optionally _feed_ it (§3).

3. **Domain queries** — the 321 `statement()` calls encode real SQL (CAS
   dedup, FTS5 BM25 + vec cosine RRF fusion, workspace merge, page version
   chains). GRDB's query interface can express some of these, but complex
   multi-join queries will stay as raw SQL (which GRDB supports via
   `db.execute(sql:)` and `Row.fetchAll(sql:)`).

4. **The fresh-schema-vs-ladder parity** — the current code maintains two
   paths (fast-path `createFreshSchemaV20()` for fresh DBs, stepwise ladder
   for existing DBs) enforced by `FreshSchemaParityTests`. GRDB's
   `DatabaseMigrator` eliminates this — migrations are idempotent and
   auto-tracked, so a fresh DB runs the same migrations as an existing one.

---

## 2. The `mutate()` seam on GRDB

### Current design (lines 7570–7592 of `SQLiteWikiStore.swift`)

```swift
private func mutate<T>(
    event: (T) throws -> ResourceChangeEvent?,
    _ body: () throws -> T
) rethrows -> T {
    lock.lock()
    let bus = _eventBus
    mutateDepth += 1
    do {
        let result = try body()              // compute-while-locked
        let pending = try? event(result)     // event from committed state
        mutateDepth -= 1
        let outermost = mutateDepth == 0
        lock.unlock()                        // release BEFORE emit
        if outermost, let pending {
            bus?.emit(pending)                // flush-after-unlock
        }
        return result
    } catch {
        mutateDepth -= 1
        lock.unlock()
        throw error                           // no event on throw
    }
}
```

**Guarantees:**
- (a) No handler runs under the lock → no deadlock under recursive composition
- (b) Subscribers read committed state (flush is post-commit)
- (c) Nested public-calls-public emits exactly once at the outermost exit
- (d) On throw, no event is flushed (rolled-back mutation emits nothing)

### GRDB equivalent design

On GRDB's `DatabaseQueue`, the "lock" is the serial writer dispatch queue.
`dbQueue.write { db in ... }` runs the body on that queue, and the closure
returns only after `COMMIT` succeeds (or `ROLLBACK` on throw). The `mutate()`
seam becomes:

```swift
private func mutate<T>(
    event: (T) throws -> ResourceChangeEvent?,
    _ body: (Database) throws -> T
) throws -> T {
    let result = try dbQueue.write { db -> T in
        let r = try body(db)
        pendingEvent = try? event(r)    // compute while still in transaction
        return r
    }                                    // COMMIT happens here
    // Post-commit: emit outside the writer queue
    if let pendingEvent {
        eventBus?.emit(pendingEvent)
    }
    return result
}
```

**Analysis against the four guarantees:**

| Guarantee | Preserved? | How |
|---|---|---|
| (a) No handler under lock | ✅ Yes | `emit()` runs after `dbQueue.write` returns — outside the serial queue |
| (b) Subscribers read committed state | ✅ Yes | `dbQueue.write` commits before returning; `emit()` is post-commit |
| (c) Nested calls emit once | ⚠️ Needs design | See nesting analysis below |
| (d) No event on throw | ✅ Yes | `dbQueue.write` rethrows; the code after it (emit) is unreachable on throw |

**Nesting (c) is the subtlety.** The current code uses `mutateDepth` to track
nesting — when `mutate()` calls a public method that also calls `mutate()`,
the inner call increments `mutateDepth` to 1, computes its event, but does not
emit (because `outermost` is false). The outermost call emits.

On GRDB, `dbQueue.write { }` is **not reentrant** — calling `dbQueue.write`
from inside `dbQueue.write` deadlocks (it's a serial queue). Public methods
that compose (e.g. `renameSource` → `updatePage`) cannot each call
`dbQueue.write` independently.

**Two resolution approaches:**

**Approach A — mutate wraps `inTransaction`, not `write`:**
`mutate()` calls `dbQueue.writeWithoutTransaction { db in db.inTransaction { ... } }`.
This gives us a raw `Database` handle that can be passed down. Composing
public methods pass the `Database` as a parameter. This is the closest
mechanical translation but requires threading `Database` through method
signatures.

**Approach B — mutate uses a stored pending-event buffer (same as current):**
Keep a `pendingEvent: ResourceChangeEvent?` on the store. `mutate()` enters
`dbQueue.write`, runs the body (which may call `inSavepoint` for nesting),
computes the event, stores it. On mutate-depth-0 exit (after `write` returns),
flush the buffered event. This preserves the exact current semantics with
minimal changes — the `mutateDepth` counter and `pendingEvent` buffer carry
over directly.

**Recommendation: Approach B.** It requires the least method-signature
changes and preserves the exact nesting semantics. The `mutateDepth` counter
and `pendingEvent` buffer are the same mechanism, just with the lock replaced
by `dbQueue.write`'s serial queue. The blast radius is confined to
`mutate()` itself — the 43 call sites don't change.

---

## 3. Database observation migration

### Can `ValueObservation` replace `WikiEventBus`?

**No — but they can coexist.** `ValueObservation` and `WikiEventBus` serve
different purposes:

| Feature | `ValueObservation` | `WikiEventBus` + `ResourceChangeEvent` |
|---|---|---|
| Granularity | Table/row level — observes specific queries | Resource level — carries `kind`/`id`/`change` |
| Metadata | Fresh values (the re-fetched query result) | `(wikiID, kind, id, change, seq)` |
| Origin tracking | No (can't tell local vs. external writes) | `origin` field (though currently removed in Phase E) |
| Cross-process | No (per-connection only) | Yes (`WikiChangeBridge` emits coarse events from Darwin notifications) |
| Coalescing | Built-in (via `reduceQueue`) | Via `ChangeCoalescer` at subscriber edge |
| Delivery timing | After commit (via commit/rollback hooks) | After `mutate()` depth-0 unlock (post-commit) |

**The File Provider depends on `kind`/`id`/`change`** to scope invalidation.
`ValueObservation` delivers fresh query results — it would require
diffing the old/new results to determine what changed. For a projection that
serves thousands of files, this is more work than receiving a structured
`ResourceChangeEvent(kind: .page, id: "01HXYZ...", change: .updated)`.

### Does GRDB's observation fire after commit?

**Yes.** From the GRDB source (`Database.swift`):
```swift
observationBroker?.installCommitAndRollbackHooks()
```
GRDB installs SQLite's `sqlite3_commit_hook` and `sqlite3_rollback_hook`.
`TransactionObserver` callbacks fire:
- `databaseDidCommit(_:)` — after `COMMIT` succeeds
- `databaseDidRollback(_:)` — after `ROLLBACK`

This matches our post-commit flush timing.

### Recommended hybrid model

The `mutate()` seam emits `ResourceChangeEvent` after commit (as designed in
§2). `ValueObservation` is available for new features that want reactive
query results (e.g., a SwiftUI view that shows a live-updating page list)
without going through the model. The event bus remains the primary change
notification for the File Provider and the model's reload path.

`TransactionObserver` could optionally be used to detect **external writes**
(from `wikictl`) on the same connection — but the current architecture handles
external writes via the Darwin notification bridge, which is cross-process and
doesn't depend on connection-level observation.

---

## 4. Custom extension registration

### sqlite-vec (`sqlite3_vec_init`)

**Yes, fully supported.** GRDB exposes the raw `sqlite3*` handle via:

```swift
public private(set) var sqliteConnection: SQLiteConnection?
// where SQLiteConnection = OpaquePointer
```

The registration happens in `Configuration.prepareDatabase`, which runs on
**every** connection (writer + all readers in a `DatabasePool`):

```swift
var config = Configuration()
config.prepareDatabase { db in
    let rc = wikifs_vec_register(UnsafeMutableRawPointer(db.sqliteConnection!))
    if rc != 0 {
        DebugLog.store("registerVec: FAILED rc=\(rc)")
    }
}
```

This is cleaner than the current code, which manually calls `registerVec(on: db)`
in both `init(databaseURL:)` and `init(readOnlyURL:)`. With GRDB, the
registration is in one place and automatically applies to every connection,
including pooled readers.

### zstd extension (#524)

**Yes, same mechanism.** The planned `wikifs_zstd_register` C function
(`sqlite3_create_function` calls) registers scalar SQL functions. GRDB
supports this two ways:

1. **`Database.add(function:)`** — the GRDB-native API for custom SQL
   functions. This wraps `sqlite3_create_function_v2` with Swift type
   safety. However, it requires reimplementing the zstd functions as
   `DatabaseFunction` instances, which may not be practical if the C code
   is complex.

2. **Raw handle access** — call `wikifs_zstd_register(db.sqliteConnection!)`
   directly in `prepareDatabase`, exactly like sqlite-vec. This is the
   recommended path for C extension registration.

### PRAGMA tuning (#523)

**Yes, via `Configuration`.** The current PRAGMAs map directly:

| Current PRAGMA | GRDB Configuration |
|---|---|
| `journal_mode=WAL` | `config.journalMode = .wal` (DatabasePool defaults to WAL) |
| `synchronous=NORMAL` | Automatic when `journalMode = .wal` (GRDB sets this) |
| `foreign_keys=ON` | `config.foreignKeysEnabled = true` (GRDB calls `PRAGMA foreign_keys = ON`) |
| `busy_timeout=5000` | `config.busyMode = .timeout(5)` |
| `mmap_size=268435456` | `config.prepareDatabase { db in try db.execute(sql: "PRAGMA mmap_size=268435456") }` |
| `cache_size=-65536` | Same — via `prepareDatabase` |
| `temp_store=MEMORY` | Same — via `prepareDatabase` |
| `query_only=ON` (readers) | `config.readonly = true` or `db.readOnly { }` (uses `PRAGMA query_only=1` internally) |

GRDB's `setUpWALMode()` already sets `synchronous = NORMAL` when WAL is active,
matching our discipline. The remaining PRAGMAs (`mmap_size`, `cache_size`,
`temp_store`) go in `prepareDatabase`.

---

## 5. Migration framework evaluation

### Can `DatabaseMigrator` handle the 37-version ladder?

**Yes.** `DatabaseMigrator` supports:

- **Named, ordered migrations** — registered in code, run in registration order
- **Persistent tracking** — a `grdb_migrations` table records which migrations
  have been applied (replacing our `PRAGMA user_version` integer)
- **DDL within migrations** — `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`,
  `CREATE VIRTUAL TABLE` (FTS5) all work inside migration closures
- **Data backfill** — `INSERT`, `UPDATE`, `DELETE` inside migration closures
- **FTS5 rebuilds** — `INSERT INTO pages_fts(pages_fts) VALUES('rebuild')`
  works in a migration closure
- **Column drops** — `ALTER TABLE ... DROP COLUMN` (macOS 15 SQLite ≥ 3.43)
  works in a migration closure
- **Table renames** — `ALTER TABLE ... RENAME TO ...` works

### How does GRDB handle migration failures?

Each migration runs inside `db.inTransaction(.immediate)`. If the migration
closure throws:
- The transaction rolls back (atomic per-migration)
- The `grdb_migrations` table is not updated (the migration will re-run on
  next open)
- The error propagates to the caller

This matches our current behavior, EXCEPT for the FTS-corruption self-heal
path. The current code catches `SQLITE_CORRUPT` during migration, rebuilds
FTS indexes, and retries. This self-heal would need to be wrapped around the
`DatabaseMigrator.migrate()` call:

```swift
do {
    try migrator.migrate(dbQueue)
} catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT {
    // Rebuild FTS indexes and retry
    try rebuildFTSIndexes(dbQueue)
    try migrator.migrate(dbQueue)
}
```

### Fresh-schema-vs-ladder parity

**Eliminated entirely.** The current code maintains two paths
(`createFreshSchemaV20()` for fresh DBs, `migrate(from:)` for existing DBs)
because running the full stepwise ladder on a fresh DB was too slow. GRDB's
`DatabaseMigrator` runs all registered migrations on every DB — fresh or
existing — because each migration is tracked individually. The
`grdb_migrations` table means a migration only runs once, regardless of DB
age. This eliminates ~300 lines of fresh-schema code and the
`FreshSchemaParityTests` suite.

The 37 `PRAGMA user_version` stamps collapse to 37 `migrator.registerMigration("v1") { ... }`
calls, each self-contained.

---

## 6. Queue store pilot design

### Why QueueStore is the ideal pilot

`QueueStore.swift` (1,015 lines) is a miniature `SQLiteWikiStore`:
- Separate `queue.sqlite` database (same App Group container)
- 3-version migration ladder (vs. 37)
- 19 public methods (vs. 88)
- No `mutate()` seam — no event bus, no flush-after-unlock
- No FTS5, no sqlite-vec, no custom extensions
- Uses `SQLiteStatement`, `NSRecursiveLock`, `withTransaction` — same
  hand-rolled patterns, just smaller
- No File Provider dependency
- No `WikiReadPool` — single connection
- Tested by its own test suite (not entangled with the 2,400+ store tests)

### What a GRDB-based QueueStore looks like

```swift
import GRDB

public final class GRDBQueueStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.journalMode = .wal  // WAL for crash-safe queue

        dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)

        // Run migrations (idempotent, auto-tracked)
        try GRDBQueueStore.migrator.migrate(dbQueue)
    }

    static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()

        m.registerMigration("v1_create_queue_items") { db in
            try db.create(table: "queue_items") { t in
                t.primaryKey("id", .text)
                t.column("queue", .text).notNull()
                t.column("wiki_id", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("state", .text).notNull()
                t.column("ordering_key", .integer).notNull()
                t.column("provider_id", .text)
                t.column("attempt", .integer).notNull().defaults(to: 0)
                t.column("error", .text)
                t.column("created_at", .integer).notNull()
                t.column("started_at", .integer)
                t.column("finished_at", .integer)
            }
            try db.create(index: "idx_queue_items_active", on: "queue_items",
                          columns: ["queue", "state", "ordering_key"])
            try db.create(table: "queue_state") { t in
                t.primaryKey("queue", .text)
                t.column("state", .text).notNull()
            }
        }

        m.registerMigration("v2_add_item_events") { db in
            try db.create(table: "queue_item_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .text).notNull()
                    .references("queue_items", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("event_json", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(index: "idx_queue_item_events",
                          on: "queue_item_events", columns: ["item_id", "seq"])
        }

        m.registerMigration("v3_namespace_run_state") { db in
            try db.execute(sql: "UPDATE queue_state SET state = 'queue-running' WHERE state = 'running'")
        }

        return m
    }()

    public func enqueue(_ request: QueueItemRequest) throws -> QueueItem {
        try dbQueue.write { db in
            let item = QueueItem(from: request)
            try item.insert(db)
            return item
        }
    }
    // ... 18 more methods, each ~5-10 lines of GRDB
}
```

### Pilot success criteria

1. `GRDBQueueStore` passes the existing QueueStore test suite (adapted)
2. GRDB is added as an SPM dependency without breaking the build
3. WAL mode, foreign keys, and busy timeout work correctly
4. The 3-migration ladder runs correctly on fresh + existing DBs
5. No `sqlite3_*` calls in `GRDBQueueStore.swift` — fully GRDB
6. The queue engine works end-to-end with the GRDB-backed store

### Estimated effort: 2–3 days

---

## 7. Parallel WikiStore conformance design

### Can a `GRDBWikiStore` conform to the 88-method `WikiStore` protocol?

**Yes.** The protocol is implementation-agnostic — it specifies behavior
(method names, parameter types, return types, throws contract) not
implementation. `WikiStoreModel` injects the store at construction:

```swift
// Current:
let store = try SQLiteWikiStore(databaseURL: url)

// GRDB swap:
let store = try GRDBWikiStore(databaseURL: url)
```

`WikiStoreModel` and all 68 app views are unchanged.

### Conformance risk assessment

| Method category | Count | Translation difficulty | Notes |
|---|---|---|---|
| Simple CRUD (create/get/update/delete page) | ~12 | Straightforward | `db.execute(sql:)` + `Row.decode()` |
| Source management (addSource, listSources, etc.) | ~15 | Moderate | CAS dedup + blob chain + provenance joins |
| Processed markdown versions | ~10 | Moderate | Version chain logic, HEAD resolution |
| Page versions + workspaces | ~15 | Hard | CAS, merge, conflict resolution, 3-way diff |
| Search (FTS5 + vec + RRF) | ~6 | Hard | Hybrid search, fallback logic, raw SQL |
| Bookmarks | ~5 | Straightforward | Simple CRUD with position renumbering |
| Chats | ~8 | Moderate | Event_json encoding, seq management |
| Blob/activity GC | ~4 | Moderate | Orphaned-row detection + bulk delete |
| Log + system prompt + wiki index | ~5 | Straightforward | Singleton documents, append-only log |
| Embeddings | ~6 | Straightforward | Chunk table CRUD |
| Derivative read helpers | ~2 | Straightforward | Batched joins |

**Estimated breakdown:**
- ~30 methods are straightforward translations (CRUD, logs, bookmarks, embeddings)
- ~40 methods are moderate (domain logic stays, plumbing changes)
- ~18 methods are hard (search, workspaces, CAS dedup — domain logic
  intertwined with SQL)

### Migration ladder translation

The 37-version ladder translates to 37 `migrator.registerMigration()` calls.
Each migration closure contains the same SQL (DDL + data backfill) as the
current `if version < N { ... }` block — the SQL doesn't change, just the
registration mechanism.

The fresh-schema fast path (`createFreshSchemaV20()`) is eliminated — the
migrator handles fresh DBs by running all migrations from empty.

### Running both implementations against the same test suite

**Feasible but requires test infrastructure work.** The current tests
construct `SQLiteWikiStore` directly:

```swift
let store = try SQLiteWikiStore(databaseURL: tmpURL)
```

To run against both, tests need to be parameterized:

```swift
func storeFactory(_ url: URL) throws -> WikiStore
```

Most tests call `WikiStore` protocol methods (not `SQLiteWikiStore`-specific
methods), so they work against any conforming store. The concrete read
helpers (`listAllPagesOrderedByID`, `listAllSourcesOrderedByID`,
`listAllLogEntriesOrderedByID`, `listAllLinks`) are not on the protocol —
they'd need to be added to the protocol or kept concrete.

**Risk:** The 2,400+ tests include integration tests that open real databases,
assert schema state, and test migration paths. A `GRDBWikiStore` needs to
produce the **exact same schema** (table names, column names, index names,
trigger names) as `SQLiteWikiStore` for the File Provider projection to work.
This is the highest-risk area — a discrepancy in FTS5 trigger names or index
names would cause silent data access failures.

**Mitigation:** Add a `SchemaParityTests` suite that dumps
`sqlite_master` from both stores opened on fresh DBs and asserts byte-identical
schema.

---

## 8. Cost/risk estimate

### Effort estimate

| Phase | Scope | Estimated effort | Risk |
|---|---|---|---|
| Phase 1: QueueStore pilot | GRDB dependency, `GRDBQueueStore`, pilot tests | 2–3 days | Low — separate DB, no event bus |
| Phase 2: New features on GRDB | Budget tracking (#528), scheduling (#527) use GRDB for new tables | 1–2 days per feature | Low — additive, no migration |
| Phase 3: `GRDBWikiStore` conformance | 88-method protocol conformance, 37 migrations, schema parity | 2–3 weeks | High — data layer, schema exactness |
| Phase 4: Parallel test validation | Parameterize test suite, run both stores, fix discrepancies | 1 week | Medium — test infrastructure |
| Phase 5: Cutover + retirement | Swap injection point, delete `SQLiteWikiStore` + `SQLiteStatement` + `WikiReadPool` | 1–2 days | Low — after parity proven |
| **Total** | | **~4–5 weeks** | |

### Risk profile

**The store is the source of truth — a regression here is data loss.** The
risk is real but mitigated by:

1. **Protocol boundary** — `WikiStoreModel` only knows the 88-method protocol.
   A GRDB store that passes the same tests is transparently swappable.
2. **Parallel validation** — both stores run against the same test suite
   before cutover. Discrepancies are caught at the test level, not in
   production.
3. **Schema parity tests** — `sqlite_master` dumps compared between stores.
4. **WAL coexistence** — GRDB and raw SQLite3 connections on the same WAL-mode
   database file coexist natively (WAL is a file-level feature, not a
   connection-level one). The File Provider extension can keep using raw
   SQLite3 while the main app uses GRDB — they share the same file.
5. **No data migration** — the DB file is the same. GRDB opens the same
   SQLite file, runs the same migrations (ported to `DatabaseMigrator`), and
   reads/writes the same tables. There is no data conversion step.

**Residual risks:**

- **Statement caching behavior** — GRDB's `StatementCache` may differ from
  our `statements: [String: SQLiteStatement]` in edge cases (e.g. a statement
  left at `SQLITE_ROW` — issue #332). GRDB manages this internally, but the
  `assertNoBusyStatements` debug check would need reimplementation or removal.
- **FTS5 external-content trigger interaction** — FTS5 triggers fire on the
  same connection. GRDB's `TransactionObserver` and `ValueObservation` may
  interact with FTS5 trigger writes in unexpected ways. Needs testing.
- **sqlite-vec timing** — `prepareDatabase` runs after GRDB's own setup
  (foreign keys, busy mode, authorizer). The `registerVec` call must succeed
  before any search query runs. The current code registers immediately after
  open; GRDB registers on every connection including pooled readers (which
  is actually better — pooled readers currently register vec too).
- **Migration tracking migration** — switching from `PRAGMA user_version` to
  `grdb_migrations` table means existing DBs at version 37 need a one-time
  "bootstrap migration" that creates the `grdb_migrations` table and
  pre-populates it with all 37 migration names. GRDB handles this
  automatically when `migrator.migrate()` first runs on a DB that has tables
  but no `grdb_migrations` table — it runs all registered migrations. But a
  DB at version 37 already has all the schema, so the migrations must be
  idempotent (most are `IF NOT EXISTS` or guarded, but some ALTER TABLE drops
  are not). This needs careful handling: either mark all 37 as "already
  applied" on first GRDB open, or restructure the migrations to be idempotent.

---

## 9. Recommended adoption strategy

### Option D: Phased adoption (recommended)

```
Phase 1: QueueStore pilot            [2-3 days]
    ↓
Phase 2: New features on GRDB        [ongoing]
    ↓
Phase 3: GRDBWikiStore conformance   [2-3 weeks]
    ↓
Phase 4: Parallel test validation    [1 week]
    ↓
Phase 5: Cutover + retirement        [1-2 days]
```

**Why this option:**

1. **QueueStore pilot first** — proves GRDB works in the project with minimal
   risk. It touches a separate DB, has a simple schema, has no `mutate()` seam,
   and has no File Provider dependency. If GRDB integration has any issues
   (SPM resolution, C target interaction with `CSqliteVec`, WAL behavior),
   they surface here, not in the wiki store.

2. **New features on GRDB** — the filed issues (#527 scheduling, #528 budget
   tracking) add new tables. These can use GRDB from the start without
   migrating existing data. This grows the GRDB surface area organically.

3. **Parallel `GRDBWikiStore`** — the protocol boundary makes this a drop-in
   replacement. Build the full conformance, run it against the test suite
   alongside `SQLiteWikiStore`, and validate parity before cutover. The
   `mutate()` seam carries over as a thin wrapper (§2). The event bus stays
   (§3). The migrations port to `DatabaseMigrator` (§5).

4. **Cutover only after parity** — the injection point swap is one line.
   `SQLiteWikiStore`, `SQLiteStatement`, and `WikiReadPool` are deleted only
   after the test suite passes against `GRDBWikiStore`.

### Why not the other options

- **Option A (pilot only):** Too conservative. The pilot proves GRDB works,
  but doesn't address the ~9,000 lines of plumbing in `SQLiteWikiStore`. The
  plumbing is where the bugs live (statement caching, #332 WAL pinning,
  savepoint nesting). Leaving it in place means continuing to maintain it.
- **Option B (new features only):** Creates a split codebase — some stores on
  GRDB, some on raw SQLite3. This is worse than either full adoption or no
  adoption because it requires maintaining both skill sets and both sets of
  infrastructure.
- **Option C (immediate full migration):** Too risky without the pilot. The
  store is the source of truth; a migration error is data loss. The phased
  approach validates each layer before moving to the next.

---

## 10. Interaction with other filed issues

### #524 — zstd BLOB compression
**GRDB accelerates this.** The `wikifs_zstd_register` C function registers
scalar SQL functions via `sqlite3_create_function`. On GRDB, this goes in
`prepareDatabase` alongside `registerVec` — one registration site for all
custom extensions per connection. No additional GRDB work needed.

### #525 — ACP session lifecycle (warm subprocess)
**No interaction.** This is about the agent subprocess lifecycle (ACP SDK
sessions), not the database. GRDB doesn't affect it.

### #526 — Tantivy search sidecar
**GRDB makes this cleaner.** If Tantivy replaces FTS5 + sqlite-vec + RRF,
the SQLite store would drop its FTS5 trigger tables and embedding chunk
tables entirely. GRDB's `DatabaseMigrator` makes the migration to drop these
tables cleaner (named migration: "v38_remove_fts5_and_vec"). GRDB's
`ValueObservation` won't observe Tantivy (it's external to SQLite), but the
event bus already handles non-DB changes via the `mutate()` seam. Tantivy
would be a separate index with its own change-notification path through
the existing `mutate()` seam after index updates.

If Tantivy is adopted, the GRDB migration for the wiki store becomes smaller
(no FTS5 triggers to port, no vec registration to preserve). The two efforts
are complementary — GRDB for the data layer, Tantivy for the search layer.

### #527 — Off-peak ingest scheduling
**GRDB accelerates this.** The `scheduledFor` column on `queue_items` is a
schema migration. On GRDB, this is a one-line `migrator.registerMigration`
with `ALTER TABLE queue_items ADD COLUMN scheduled_for INTEGER`. If QueueStore
is already on GRDB (Phase 1 pilot), this migration is trivial.

### #528 — Budget/quota-aware ingestion
**GRDB accelerates this.** New tables for budget tracking are additive. On
GRDB, the schema and queries use the query interface (`db.create(table:)`,
`Budget.filter { $0.spent > $0.cap }.fetchOne(db)`). No new raw SQL needed.

---

## Appendix A: GRDB key API reference (from source code reading)

### `Database.sqliteConnection`
```swift
/// The raw SQLite connection, suitable for the SQLite C API.
public private(set) var sqliteConnection: SQLiteConnection?
// where public typealias SQLiteConnection = OpaquePointer
```
Direct access to the `sqlite3*` handle. Safe for `sqlite3_vec_init` and
custom C extension registration.

### `Configuration.prepareDatabase`
```swift
config.prepareDatabase { db in
    // Runs on EVERY connection (writer + readers in DatabasePool)
    // After GRDB's internal setup, before app code
    let rc = wikifs_vec_register(UnsafeMutableRawPointer(db.sqliteConnection!))
}
```

### `Database.inTransaction` / `inSavepoint`
- `inTransaction(.immediate)` — `BEGIN IMMEDIATE TRANSACTION`, auto-rollback on throw
- `inSavepoint` — reentrant, nests savepoints, auto-rollback on throw
- Top-level `inSavepoint` automatically opens an `inTransaction` (GRDB prefers
  IMMEDIATE for writes, matching our discipline)

### `Database.readOnly`
```swift
try db.readOnly {
    // PRAGMA query_only=1 set internally
    // Writes throw SQLITE_READONLY
}
```
Reentrant — nests correctly. Used by DatabasePool readers automatically.

### `DatabaseMigrator`
```swift
var migrator = DatabaseMigrator()
migrator.registerMigration("v1") { db in
    try db.create(table: "pages") { t in ... }
    try db.execute(sql: "INSERT INTO ...")
}
try migrator.migrate(dbQueue)  // idempotent, auto-tracked
```
Tracks applied migrations in `grdb_migrations` table. Fresh DBs run all
migrations; existing DBs run only pending ones.

### `ValueObservation`
```swift
let observation = ValueObservation.tracking { db in
    try Page.fetchAll(db)
}
let cancellable = observation.start(in: dbQueue) { pages in
    // Called after every commit that changes the observed region
}
```
Fires after commit via `sqlite3_commit_hook`. Observes table-level regions,
not domain metadata.

---

## Appendix B: Current store metrics (verified from source)

| Metric | Value | Source |
|---|---|---|
| `SQLiteWikiStore.swift` lines | 8,994 | `wc -l` |
| `WikiStore.swift` protocol methods | 88 | `rg -c 'func '` |
| `mutate()` call sites | 43 | `rg -c 'mutate\(event:'` |
| `withTransaction` references | 56 | `rg -c 'withTransaction'` |
| `sqlite3_*`/`SQLITE_*`/`OpaquePointer` call sites | 134 | `rg -c` |
| `statement()` calls | 321 | `rg -c 'statement\('` |
| Positional column access (`.text(at:)` etc.) | 301 | `rg -c` |
| Schema version (current) | 37 | `currentSchemaVersion` |
| `PRAGMA user_version` stamps | 48 | `rg -c` (fresh + ladder) |
| FTS5 trigger/vtable definitions | 21 | `rg -c` |
| `QueueStore.swift` lines | 1,015 | `wc -l` |
| QueueStore public methods | 19 | `rg -c 'public func '` |
| QueueStore migration versions | 3 | source review |
