---
title: Dynamic renderers Phase 3b A3 machine index
issue: 1026
---

# Dynamic renderers Phase 3b A3 machine index

## Delivered

- Added a machine-only SQLite authority at `renderers/v1/index.sqlite` and an
  atomically regenerated derived `derived/index.json`.
- Added typed renderer package install records, state, redacted diagnostics,
  generation-CAS mutation, safe-mode persistence, immutable hash reservation,
  and an explicit empty descriptor projection for unvalidated records.
- Routed machine-index reads and mutations through the existing A2 package-store
  coordinator. The implementation does not change wiki SQLite, File Provider,
  registry, validator, activation, journal, delivery, or UI code.

## Evidence

- `swift test --filter RendererMachineIndexStoreTests` passed: 10 tests.
- `make build` passed on Swift 6.3.3.
- The focused tests cover fresh initialization, generation increment and stale
  rejection, immutable conflicting hashes, package-root escape, duplicates,
  derived JSON replacement rollback, corruption rejection, safe-mode reopen,
  unavailable projection, and wiki/File Provider isolation.
