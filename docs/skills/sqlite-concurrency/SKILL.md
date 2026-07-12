---
description: This app's SQLite concurrency discipline — the store is method-atomic (internal recursive lock + savepoint transactions); writes flow through the main-actor model, off-main reads go through WikiReadPool, and connection state must never cross a call boundary. Read before adding anything that touches the store off the main actor or composes transactions.
---

# SQLite concurrency: method-atomic store, pooled readers

`SQLiteWikiStore` keeps **one connection** with a **prepared-statement cache
keyed by SQL text**. Since graph-model Phase 0
(`plans/graph-model-and-versioning.md` §8) the store is **method-atomic**: every
public entry point holds an internal `NSRecursiveLock` for its whole body, and
transactions nest via `withTransaction` (outermost `BEGIN IMMEDIATE`, inner
`SAVEPOINT`s). That changed the rules. This skill is the current discipline.

> **Invariant:** the store is safe to *call* from any thread — but UI writes
> still flow through the `@MainActor` model (they mutate observable state), and
> off-main reads go through **`WikiReadPool`** (separate read-only snapshot
> connections), not the write store. No statement handle, column pointer, or
> other connection state ever crosses a method boundary.

## What changed and what stayed

| | Before Phase 0 | Now |
|---|---|---|
| Thread safety | Conventional ("main actor only") | Structural (recursive lock around every method body) |
| Off-main reads | Forbidden | Via `WikiReadPool` (preferred) or the store itself (safe, but contends with the writer) |
| Off-main writes | Forbidden | *Safe* but still **routed through the main-actor model** — observable state (`summaries`, `sources`, drafts) must mutate on main |
| Transactions | Six raw `BEGIN IMMEDIATE` sites, non-nestable | `withTransaction` (savepoint nesting); transaction-owning methods compose |
| `renameSource` | "Eventually consistent" multi-statement | Atomic (one transaction; embedding/FTS side effects after commit) |
| Bulk work | Blocking modal, sole owner of the store | Blocking modal still the default shape; off-main bulk is possible but needs a model-coordination design first (open question §13.4 of the plan) |

## Why the lock, not just `FULLMUTEX` (the failure that started this)

The connection is opened `SQLITE_OPEN_FULLMUTEX`, which serializes *individual*
C calls. That never protected the app-level sequence: the statement cache hands
two callers of byte-identical SQL the **same `sqlite3_stmt*`**, and

```
Thread A: sqlite3_column_text(stmt)  → pointer P into stmt's row buffer
Thread B: sqlite3_step(stmt)/reset   → stmt advances/clears, P now garbage
Thread A: String(cString: P)         → traps on invalid UTF-8 (EXC_BREAKPOINT)
```

This crashed launch twice (a clean `exit()` from MLX off-main, and the
`String(cString:)` trap from a detached-Task store read). The method-atomic
lock makes the whole bind → step → read sequence indivisible; the regression
guard is `StoreConcurrencyTests.concurrentReadersAndWriterDoNotCorrupt`.

## The rules

### 1. Reads that shouldn't block typing → `WikiReadPool`

```swift
// WikiStoreModel — debounced search (the pattern to copy)
if let pool = self.readPool {
    results = (try? await pool.asyncRead { reader in
        try reader.searchSimilar(query: query, limit: 20)
    }) ?? []
} else {
    results = (try? self.store.searchSimilar(query: query, limit: 20)) ?? []
}
```

- Pool connections are `SQLiteWikiStore(readOnlyURL:)`: `query_only=ON`, **no
  migrations, no open-time self-heal** — a pool member can never author schema
  or write. (Never build a pool from `init(databaseURL:)` — that init *writes*
  on open: migrations + search self-heal.)
- Each pooled store has its own statement cache → no aliasing with the writer.
- WAL = N readers + 1 writer across connections *and* processes; this is the
  same mechanism `wikictl` and the File Provider extension already rely on.
- The pool is `nil` for in-memory wikis and in most tests — **always keep the
  main-store fallback branch.**

### 2. Writes stay on the main-actor model

Not because SQLite would corrupt (it won't anymore) but because every write is
followed by observable-state mutation (`reloadSummaries()`, `sources`, tab
retitling) that must happen on main, and the synchronous write-then-reload
contract is load-bearing across ~100 call sites. Don't move writes off-main
piecemeal; that redesign is plan §13.4.

### 3. Compose multi-step writes with `withTransaction`

```swift
try store.withTransaction {
    // any store calls — including methods that own their own transactions
    // (replaceLinks, storePageChunks): they become SAVEPOINTs inside this.
    try store.updatePage(...)
    try store.replaceLinks(...)
}
```

- Outermost call = `BEGIN IMMEDIATE` (grab the write lock up front, the
  long-standing discipline). Nested = savepoints; an inner failure rolls back
  only itself, so `try?`-best-effort side effects keep their semantics.
- Never write raw `BEGIN`/`COMMIT`/`ROLLBACK` in store code again.
- **Never run model inference or network I/O inside `withTransaction`** — an
  open write transaction stalls `wikictl` (the second writer process).
  `renameSource` shows the shape: transaction commits first, then best-effort
  `reembedSource`/`upsertSourceSearch`.

### 4. Adding a store method? Take the lock.

Every public/internal entry that touches `db`, `statements`, or
`transactionDepth` starts with:

```swift
lock.lock(); defer { lock.unlock() }
```

Private helpers called only from locked entries don't re-take it (the lock is
recursive, so re-taking is harmless — but the convention is: lock at the public
boundary). A method returning a single expression needs an explicit `return`
after the lock line.

### 5. Values only across boundaries

Reads return decoded Swift structs (`WikiPage`, `SourceSummary`, …). Never let
a `SQLiteStatement`, a raw handle, or a column pointer escape a method — the
lock protects a method body, not your saved pointer. `SQLiteStatement.text(at:)`
already copies bytes out immediately with a lossy-UTF-8 fallback; keep using it
(❌ `String(cString:)` — traps on invalid UTF-8, stops at embedded NUL).

### 6. Bulk work: blocking modal is still the default shape

The one-time search-index upgrade (`WikiStoreModel.upgradeSearchIndex`) keeps
its non-dismissible sheet: main-actor store I/O, off-main **pure compute**
(MLX embedding) only. With the method-atomic store this is now a UX choice
rather than a crash-safety requirement — but do not convert it to a background
job without designing model coordination (who reloads observable state, when)
— plan §13.4.

### 7. Statement lifetime: always `defer { stmt.reset() }`

A prepared statement left stepped-to-`SQLITE_ROW` (busy) holds an **implicit
read transaction** open on the connection, pinning the WAL read snapshot. In
WAL mode this has two consequences:

1. **Stale reads** — subsequent reads on the same connection see data as of the
   pinned snapshot, even after an external writer commits.
2. **Write-lock failure** — `BEGIN IMMEDIATE` fails with `SQLITE_BUSY_SNAPSHOT`
   when the snapshot is stale relative to the WAL head.

This was the root cause of issue #332: 18 functions used a "reset-before-use"
idiom (`stmt.reset()` *before* `bind`/`step`) that cleared the *previous* call's
leftover but left the *current* call's statement busy on return.

**The rule:** every stepped statement gets `defer { stmt.reset() }` immediately
after `try statement(...)`. This covers all exit paths — success, early return,
and throw — uniformly.

```swift
// ✅ Correct — defer bounds the statement's read transaction to the call.
let stmt = try statement("SELECT … WHERE id = ?1;")
defer { stmt.reset() }
try stmt.bind(id, at: 1)
if try stmt.step() { return stmt.text(at: 0) }

// ❌ Wrong — reset-before-use clears the PREVIOUS call's leftover but leaves
// the CURRENT call's statement busy at ROW when the function returns.
let stmt = try statement("SELECT … WHERE id = ?1;")
stmt.reset()
try stmt.bind(id, at: 1)
if try stmt.step() { return stmt.text(at: 0) }
```

When a read precedes a `withTransaction` in the same method (e.g.
`revertProcessedMarkdown` reads a target row, then writes), add an explicit
`target.reset()` after extracting the values — the `defer` fires at scope exit,
but `withTransaction` runs first and its debug guard would fire.

**Debug guard:** `assertNoBusyStatements()` (DEBUG-only) is called at the top of
`withTransaction` at depth 0 — it throws if any cached statement is busy before
`BEGIN IMMEDIATE`. The `SQLiteStatement.isBusy` property wraps
`sqlite3_stmt_busy`. The regression test `noBusyStatementsAfterReads` exercises
every fixed site and asserts no busy statement remains.

### 8. Cached statement reuse: `reset()` before `bind` on shared statements

The statement cache keys by SQL text — two methods that use identical SQL share
the **same `sqlite3_stmt*`**. After `step` returns `SQLITE_DONE` (an INSERT,
UPDATE, or SELECT with no rows), the statement is in the "done" state. Calling
`sqlite3_bind_*` on a statement in the "done" state **without `sqlite3_reset`
first** returns `SQLITE_MISUSE` (error 21: "bad parameter or other API misuse").

This bit `updatePage` after Phase 4's `appendPageVersion` amend path was added:
both methods use the same `UPDATE pages SET ...` SQL. `appendPageVersion` called
`stmt.reset()` before binding (clearing the prior state). `updatePage` only had
`defer { stmt.reset() }` — which runs *after* the body, so `bind` hit a
statement still at `SQLITE_DONE` from `appendPageVersion`'s call.

**The rule:** when a method uses `statement(...)` to get a cached statement and
then calls `bind`, always call `stmt.reset()` before the first `bind` — `defer`
alone is too late because it runs at scope exit, not before reuse.

```swift
// ✅ Correct — reset before bind (covers cached-statement reuse) AND defer
//   for the current call's cleanup.
let stmt = try statement("UPDATE pages SET ... WHERE id = ?1;")
stmt.reset()                    // clear any SQLITE_DONE from a prior caller
defer { stmt.reset() }          // clean up THIS call's state on exit
try stmt.bind(id, at: 1)
_ = try stmt.step()

// ❌ Wrong — defer runs AFTER bind, so if the cached statement was left at
//   SQLITE_DONE by a prior call, sqlite3_bind_text returns SQLITE_MISUSE.
let stmt = try statement("UPDATE pages SET ... WHERE id = ?1;")
defer { stmt.reset() }          // too late — bind already failed
try stmt.bind(id, at: 1)
_ = try stmt.step()
```

**Multi-statement methods** (e.g. `tryAmendPageVersion`) have a related hazard:
if several statements are created in sequence, a SELECT left at `SQLITE_ROW`
via `defer` pins the connection while the *next* `statement()` or `step()` runs.
Reset each statement **immediately after reading its value**, not via `defer`:

```swift
// ✅ Correct — reset immediately after reading, before creating the next stmt.
let check = try statement("SELECT ... WHERE id = ?1;")
try check.bind(id, at: 1)
guard try check.step() else { check.reset(); return nil }
let value = check.text(at: 0)
check.reset()                   // don't pin the connection for the next stmt

// ❌ Wrong — the SELECT stays at SQLITE_ROW while the next statement is
//   prepared and stepped, pinning the WAL read snapshot mid-method.
let check = try statement("SELECT ... WHERE id = ?1;")
defer { check.reset() }
try check.bind(id, at: 1)
guard try check.step() else { return nil }
let value = check.text(at: 0)
// ... next statement created here — check is still busy

## Anti-patterns (updated)

- **Pooling `init(databaseURL:)` connections** — that init writes (migrations,
  self-heal). Read-only pools use `init(readOnlyURL:)`, always.
- **Holding a write transaction across embedding/network** — stalls `wikictl`.
- **Raw `BEGIN IMMEDIATE` in store code** — breaks nesting; use `withTransaction`.
- **Off-main writes that then mutate observable state from that thread** —
  route writes through the model on main.
- **Letting a statement or column pointer outlive its method** — the lock can't
  protect it.
- **`String(cString:)` on a DB column** — byte-length lossy decode only.
- **Reset-before-use instead of `defer { stmt.reset() }`** — leaves the
  statement busy at `SQLITE_ROW` when the function returns, pinning the WAL
  snapshot (#332). Always `defer` immediately after `try statement(...)`.
- **Treating `SQLITE_OPEN_FULLMUTEX` as app-level safety** — it serializes C
  calls, not bind/step/read sequences; the recursive lock does that.
- **`bind` without `reset()` on a cached statement** — when two methods share
  the same SQL (same cached `sqlite3_stmt*`), the prior call leaves it at
  `SQLITE_DONE`; `bind` without `reset` returns `SQLITE_MISUSE` (error 21).
  Always `stmt.reset()` before the first `bind`, even if `defer { stmt.reset() }`
  is also present (Rule 8).
- **Multi-statement methods with `defer` only** — in a method that creates
  multiple statements in sequence, a SELECT left at `SQLITE_ROW` via `defer`
  pins the WAL read snapshot while the next statement is prepared and stepped.
  Reset each statement immediately after reading its value (Rule 8).

## Verifying

```sh
# New store methods must take the lock at entry:
grep -n "public func\|internal func" Sources/WikiFSCore/SQLiteWikiStore.swift | wc -l
grep -c "lock.lock(); defer { lock.unlock() }" Sources/WikiFSCore/SQLiteWikiStore.swift
# No raw transactions outside withTransaction:
grep -n "BEGIN IMMEDIATE\|ROLLBACK" Sources/WikiFSCore/SQLiteWikiStore.swift   # only inside withTransaction
# The regression suite:
swift test --filter StoreConcurrencyTests
# Statement lifecycle (issue #332):
swift test --filter SQLiteStatementLifecycleTests
```
