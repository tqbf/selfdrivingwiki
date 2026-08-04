# Dynamic renderers Phase 3 readiness


## Purpose

This note is the Phase 3 bootstrap handoff for [dynamic renderers](dynamic-renderers.md). It records readiness decisions and unresolved bootstrap choices. It does not redesign the reviewed implementation plan.

## Entry conditions

- Start only after PR [#1062](https://github.com/tqbf/selfdrivingwiki/pull/1062) merges, or after the operator provides its equivalent updated head: `feature/dynamic-renderers-02-builtins`.
- Preserve the dependency order in [the implementation plan](dynamic-renderers-implementation.md). Phase 3 is the persistence slice named there as PR 3.
- Keep package payloads and machine records outside wiki databases and File Provider projections.

## Schema decision

Add schema v49 immediately after the current v47-to-v48 step and before the catch-all `GRDBWikiStore` fallback. Update the fresh-schema path in the same change. The migration and fresh schema must create the same wiki-scoped renderer tables and indexes. Verify upgrade, fresh creation, reopen, and schema parity.

Current evidence:

- [`GRDBWikiStore.currentSchemaVersion`](../Sources/WikiFSCore/Store/GRDBWikiStore.swift) is v48.
- The migration ladder warns that new work must precede the fallback.
- [`createFreshSchema(on:)`](../Sources/WikiFSCore/Store/GRDBWikiStore.swift) is the fresh-schema authority.
- [`StoreBackend`](../Sources/WikiFSCore/Store/StoreBackend.swift) uses GRDB as the sole production backend.

## Bootstrap decisions to make

These are implementation choices for Phase 3 bootstrap. They are not a redesign.

### Machine package-store coordination

Choose one coordinator after a focused crash and race spike:

1. A lock-file protocol with ownership, bounded acquisition, and atomic index replacement.
2. A Foundation file-coordination protocol with equivalent ownership and atomic replacement guarantees.
3. Another local App Group coordination primitive only if it proves the same guarantees.

The selected option must serialize index, machine journal, lease, cursor, checkpoint, and compaction mutations. It must prevent lost read-modify-write updates and preserve the last valid index after a failed replacement.

Record evidence before selection:

- Two independent processes race install-state, safe-mode, lease, cursor, and compaction updates.
- A process dies while holding coordination and during index replacement.
- A stale generation or conflicting expected hash fails closed.
- Reopen recovers the previous valid index and leaves no active partial record.
- The test harness can observe ordering and atomicity without sleeps or blocking waits.

### Durable structures

Decide the exact schema and ownership before writing the migration:

- **Wiki tables:** renderer enablement, source preference, wiki-scoped event journal, process leases, per-lease cursors, and subsystem checkpoints. Use typed columns, constraints, scoped monotone sequences, and transaction-local event insertion.
- **Machine store:** package-ID/version directories, a versioned machine index, machine install and safe-mode records, machine event journal, process leases, per-lease cursors, and subsystem checkpoints. Keep payloads separate from records and wiki storage.

The decision record must name every table, key, uniqueness rule, foreign key, retention field, and authoritative reload projection. Do not substitute metadata JSON for dedicated wiki tables.

### Policy constants

Define named constants before implementation. Do not invent numeric values in this handoff. The Phase 3 policy must specify:

- lease heartbeat interval
- lease expiry bound
- clock-skew safety margin
- clean-retirement safety interval
- journal retention minimum age and count floor
- drain batch limit and any related ordered-drain bound

Tests must inject clocks and generators. Policy tests must cover heartbeat renewal, expiry, retirement, reclamation, retention gaps, cursor reset, and bounded drains.

## Wake and isolation contract

Darwin notifications are payload-free wake-ups. Define separate, stable names for wiki and machine scopes. The name may identify the scope, but it must not encode event data, event IDs, sequences, or settings payloads. After a wake, the owning process lease reads the durable journal and performs an authoritative, idempotent reload.

Route renderer wakes to the renderer journal reader. Keep the existing generic resource wake path for resource events. `FileProviderFacade` and Tantivy must subscribe only to `.resource`. Renderer events must not cause File Provider enumeration, Tantivy indexing, provenance activity, source versions, or page versions.

Current evidence:

- [`WikiChangeNotification`](../Sources/WikiFSCore/Store/WikiChangeNotification.swift) uses payload-free per-wiki names.
- [`DarwinNotifier`](../Sources/WikiFSCore/Core/DarwinNotifier.swift) posts no payload and does not signal File Provider directly.
- [`WikiEventBus`](../Sources/WikiFSCore/Store/WikiEventBus.swift) carries resource metadata in-process. Renderer journals must not create a parallel resource event path.

## Cross-process test contract

Use Swift Testing suites marked `.serialized` with explicit time limits. Use nonblocking process termination handlers and timeout-bounded continuation races. Never use `Process.waitUntilExit()`, thread sleeps, semaphore waits, or an unbounded continuation in this harness.

The harness must provide two real store or process instances, isolated temporary App Group paths, deterministic IDs and clocks, observable journal and wake seams, crash/reopen control, and cleanup. It must prove commit ordering, no record on rollback, one post-commit producer wake, independent same-subsystem process leases, at-least-once replay, cursor-after-success, retention-gap reload, and File Provider/Tantivy isolation.

## Dependency-ordered gates

1. **Bootstrap:** verify PR #1062 dependency, record exact head, current schema, and selected coordination evidence.
2. **Schema:** add v49 before the fallback and mirror it in fresh schema. Pass upgrade, fresh, reopen, and parity tests.
3. **Durable records:** implement typed wiki tables, machine index, journals, leases, cursors, checkpoints, and named policy constants. Pass transaction and crash-recovery tests.
4. **Coordination:** implement the selected machine coordinator. Pass two-process race, generation, atomic replacement, and stale-owner tests.
5. **Delivery:** add wake-only notification naming, ordered at-least-once drains, authoritative reload, replay, retention, and fan-out. Pass cross-process tests.
6. **Isolation:** prove renderer records do not reach File Provider or Tantivy. Pass routing and projection isolation tests.
7. **Gate:** run the Phase 3 focused inventory and review, then `make build`, `make test`, the documented opted-in app tests, `make prompts`, `swift build`, and `swift test` after prerequisite sync.

Do not open a dependent renderer PR until the Phase 3 exact-head test inventory, review, and command gates pass. Do not merge this handoff PR. The operator owns merge decisions.
