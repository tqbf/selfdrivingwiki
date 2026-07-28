---
timestamp: 2026-07-03T193623Z
title: "2026-07-03 — Graph-model Phase 0: method-atomic store, savepoint transactions, `WikiReadPool`"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-03 — Graph-model Phase 0: method-atomic store, savepoint transactions, `WikiReadPool`

## Progress


Concurrency substrate for [`plans/graph-model-and-versioning.md`](plans/graph-model-and-versioning.md)
(the design of record superseding the `source-versioning-and-providers.md`
draft; also records the "no CozoDB" decision). The "one connection,
main-thread-only" store convention is replaced by structural safety — no
schema change, no `WikiStore` protocol change, zero call-site churn.

- **`SQLiteWikiStore` is method-atomic.** New internal `NSRecursiveLock`;
  all 50 public/internal entry points acquire it for their whole body
  (`lock.lock(); defer { lock.unlock() }`). This closes the two app-level races
  `FULLMUTEX` never covered: byte-identical SQL sharing one cached
  `sqlite3_stmt*` (the historical `String(cString:)` `EXC_BREAKPOINT`), and the
  unguarded `statements` dictionary.
- **`withTransaction` (savepoint nesting).** Outermost = `BEGIN IMMEDIATE`,
  nested = `SAVEPOINT`s; the six raw transaction sites (deletePage,
  replaceLinks, createBookmarkNode, deleteBookmarkNode, moveBookmarkNode,
  replaceChunks) converted. Transaction-owning methods now compose.
- **`renameSource` is atomic** — source row + every page rewrite in one
  transaction (retires phase-d's "eventually consistent" caveat). Embedding +
  FTS side effects run after commit so MLX inference never holds the write
  lock against `wikictl`.
- **New `WikiReadPool`** (`Sources/WikiFSCore/WikiReadPool.swift`): lazily
  opened, reusable read-only snapshot connections (`init(readOnlyURL:)`,
  `query_only=ON`, own statement cache each). `WikiManager.openActive` injects
  one per file-backed wiki; `WikiStoreModel`'s debounced page/source searches
  now run **off-main** through it (main-store fallback kept for in-memory/tests).
- **Docs/invariant updated**: `docs/skills/sqlite-concurrency/SKILL.md`
  rewritten for the new discipline; AGENTS.md invariant bullet replaced.
- Gate: full suite green — **1269 tests / 99 suites** (10 new in
  `StoreConcurrencyTests`: concurrent reader/writer hammer, savepoint
  commit/rollback semantics, nested transaction-owning methods, atomic rename,
  pool visibility/read-only/reuse/async/concurrency).
- **Adversarial review pass** (5 lenses × skeptic verification; 12 confirmed
  of 17 raised): two code fixes — `checkpointDatabase` now steps
  `wal_checkpoint(TRUNCATE)` as a query with a 5s busy wait and fails the
  export loudly when the `busy` column is set (a pooled reader could
  previously make an export silently stale), and `renameSource` reads the
  old name *inside* its transaction (cross-process TOCTOU vs `wikictl`
  rename) — plus ten design-doc amendments (pin-distinct `source_links`
  edges via a `COALESCE`'d unique index, `refs.owner_id` cascade +
  polymorphic-`version_id` integrity note, dual-write/read-fallback rules for
  binary skew during the `sources.content` soak, byteless zero-byte
  projection interim rule, `sources.role` added in v20, §3 sweep pinned to
  `92124bd`).

## Verification

Historical verification remains in the progress record above.
