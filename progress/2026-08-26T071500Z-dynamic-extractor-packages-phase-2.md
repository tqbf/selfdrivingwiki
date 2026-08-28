---
timestamp: 2026-08-26T071500Z
title: Dynamic extractor packages Phase 2 trusted plugin host
branch: feature/dynamic-extractor-packages
status: complete
---

# Dynamic extractor packages Phase 2 trusted plugin host

## Progress

Phase 2 adds `DynamicPluginHost` to `CordisLoader`.

The host accepts trusted in-memory `PluginDefinition` values and immutable fingerprints. It does not accept source code, package paths, shared libraries, arbitrary configuration, or runtime modules.

The host supports define, run, stop, undefine, inspect, inspect-all, and reconcile operations. Each run calls the trusted factory again and gets a new Cordis component identity.

## Lifecycle

A settled pending component is a waiting run. The same component activates when its Cordis dependencies become available. The host does not create a second run for that transition.

Stop removes current ownership before physical disposal. A token-owned disposal barrier coalesces repeated stop and undefine calls. New runs cannot start until Cordis disposal and host bookkeeping both complete.

The barrier stores the disposing run and its terminal lifecycle. Any waiter can complete the same idempotent finish. The finish records component state, state history, cleanup failures, and cleanup anomalies before it clears the barrier.

Failed activation disposes the physical component before the host returns the failure. Stop during activation rollback wins and prevents a stale failure from restoring ownership.

Stop can also occur while Cordis registration is suspended and no handle exists. The host keeps run ownership in the Stopping state. Each stop call waits on its own bounded completion stream. Registration completion disposes the exact handle before it releases all stop calls. A package-internal initializer injects the registration operation for tests. The public initializer always uses `CordisContext.register`.

## Inspection and retention

Inspection exposes only identities, fingerprints, lifecycle state, run and component state, missing dependencies, declared work count, bounded run history, failure phases, and cleanup diagnostics.

The host bounds retained runs and diagnostics with a named policy. Disposed handles are not retained.

`ScopeDiagnosticsSnapshot` now reports the number of retained Cordis component records. The churn test confirms that Cordis retains one disposed record per run while active registrations return to zero. The host keeps only its configured run count. This phase does not add runtime record eviction.

## Static and dynamic boundaries

`PluginCatalog` remains immutable and link-time. It rejects the reserved `dynamic:` plugin namespace.

`DynamicPluginHost` requires that namespace and rejects static plugin IDs. A source guard checks that the trusted definition and inspection contracts contain no source or loader fields.

## Defects found during review

The first host allowed a repeated stop to report Stopped before physical cleanup completed. A new run could overlap old cleanup.

The first failed-run path removed current ownership without reserving a cleanup barrier. A replacement run could start before failed-component disposal completed.

The first concurrent undefine path could remove a definition while old cleanup still ran.

The first barrier let a non-owner waiter clear the token before run-specific bookkeeping completed. The barrier now carries the disposing run and terminal lifecycle.

The first reconcile report invented a run ID for lifecycle errors. Reconcile now reports operation failures separately and keeps run IDs tied to retained run records.

The first stop path treated a handle-less run as stopped while `CordisContext.register` was still suspended. Registration could then return a live, unowned component. Stop now waits for registration completion and exact handle disposal.

## Verification

The following checks passed:

- `swift test --filter DynamicPluginHostTests`
- `swift test --filter 'DynamicPluginHostTests|CordisTests|CordisLoaderTests'`
- `make lint`
- `swift build`
- LSP diagnostics for the host, host tests, Cordis runtime, and plugin catalog

The final host suite passed 22 tests. The focused Cordis run passed 108 tests in 16 suites. The unrelated `mise.lock` remains untracked and unchanged.
