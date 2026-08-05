---
timestamp: 2026-08-05T044200Z
title: Dynamic renderers Phase 3b A4a machine events
branch: feature/dynamic-renderers-03b-machine-store
status: complete
---

# Dynamic renderers Phase 3b A4a machine events

## Progress

This bounded Phase 3b increment adds durable machine-only renderer event
structures beneath the App Group package store. The new machine journal records
typed renderer settings envelopes in `machine.sqlite`; it remains outside wiki
SQLite databases and File Provider projections.

`RendererMachineIndexStore.mutateAndAppendMachineEvent` holds the existing
package-store coordinator and uses one SQLite transaction across the index and
journal attachment. It commits the generation update, derived index, scoped
sequence, and event record together; a failed mutation or derived-index write
leaves no committed event.

`RendererMachineLeaseRegistry` persists distinct process leases beneath stable
subsystem identities, heartbeats, retirement, lease-safe reclamation, per-lease
cursors, and subsystem checkpoints. Consumers explicitly mark a record handled
only after a successful authoritative handler; event UUIDs are not dedup keys.

## Verification

- `swift test --filter RendererMachineEventJournalTests` passed: 9 tests across
  3 suites. The suite includes the lease and cursor coverage recorded for this
  increment.
