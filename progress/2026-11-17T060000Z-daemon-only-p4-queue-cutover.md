---
timestamp: 2026-11-17T060000Z
title: Daemon-only P4 queue cutover complete
branch: feature/daemon-only-p1-async-store
status: active
---

# Daemon-only P4 queue cutover complete

## Progress

Phase 4 (plan `plans/daemon-only-access.md` P4 column) is implemented
across two slices (checkpoints 36-37).

- **App-local queue engine removed.** `LocalQueueRuntimeController`'s
  9-state machine (local assembly, fallback, shutdown handoff) shrank
  to 4 states: unavailable / daemonActive / daemonOwnershipUnresolved /
  disposing. Daemon loss degrades to `UnavailableQueueEngine` (which
  `QueueActivityTracker` and `BackgroundIngestCoordinator` already
  handle); unresolved ownership resolves only via a fresh daemon epoch.
  `DaemonTransportAppCoordinator` lost its shutdown-blocked and
  relinquish branches.
- **Workload migration.** The in-app pipelines are deleted: import
  auto-extraction now enqueues a durable format job through an
  `enqueueImportFormatJob` seam the session wires to the hot-swap queue
  client; manual HTML/DOCX extraction and URL refresh route through the
  daemon queue's new `.html`/`.docx`/`.refresh` engine arms (shared by
  both hosts, with a WorkloadIntent payload and an htmlBackend routing
  key). Extracted markdown commits daemon-side; progress/status
  projections arrive over the daemon's queue-event sink.
- **Deletions.** `AppQueueExtractionProvider` /
  `AppQueueIngestionProvider`, `QueueRuntimeFactory` (+ its tests), the
  app-side stranded-format-job recovery scan (the daemon runs the
  identical recovery), and the dead view-threaded extraction provider.
  The provider-invocation counter
  (`WikiStorageSeam.queueProviderInvocation`) stays pinned at zero —
  the AC.8 mechanism.
- **P4 gate suite** (`DaemonWorkloadRoutingTests`, real fixture daemon):
  routed HTML extraction executes in the daemon composition with zero
  app provider invocations; package-only import conversion enqueues,
  converts daemon-side, and the app sees the head; daemon restart
  rehydrates the durable queue rows across a container-accurate probe.
- **Inventory** (P4.3 prerequisite): every app-path workload classified
  in `plans/daemon-only-access.md` — queue-routed engine-agnostic
  enqueues vs the in-app pipelines that moved.

Known follow-ups: the daemon-side host-speech producer mirror widening
and the inline-artifact block-id codec remain queued contract decisions;
MRU/home-page and export/import daemon ops remain queued from P3.

## Verification

- `make build` green; `make lint` 0 violations (781 files).
- Full `make test`: 4,714 tests in 491 suites, 0 issues.
- P4 gate suite (`DaemonWorkloadRoutingTests`) 3/3 via the guarded
  runner; boundary + controller + contract suites green after slice 2's
  deletions.
