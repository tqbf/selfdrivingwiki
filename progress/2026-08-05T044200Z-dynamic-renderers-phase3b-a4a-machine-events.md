# Dynamic renderers Phase 3b A4a machine events

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

Focused Swift Testing coverage validates fresh and ordered bounded journal
reads, rollback, high-water reads, independent same-subsystem leases, live and
heartbeat protection, stale and clean-retirement safety windows, cursor-after-
success behavior, and unsupported envelope rejection.
