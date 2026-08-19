---
timestamp: 2026-08-18T033500Z
title: Swift Cordis runtime and queue migration
branch: feature/cordis-runtime
status: complete
---

# Swift Cordis Runtime and Queue Migration

**Status:** Complete

## Progress

This change adds a Foundation-only Swift component runtime and uses it at the app-local queue composition boundary.

The change keeps Cordis outside SwiftUI views, wiki models, sessions, XPC, and the daemon process.

## Runtime

The new `Cordis` target provides these contracts:

- typed service keys and realms;
- hierarchical contexts;
- dependency-gated component activation;
- generation-safe activation transactions;
- dependent-first provider withdrawal;
- LIFO effect cleanup;
- cleanup error aggregation;
- explicit lifecycle state and settlement;
- idempotent component, effect, and context disposal.

The runtime uses an actor for lifecycle state. User activation and cleanup run through nonisolated runners. The runtime uses no detached tasks and no `@unchecked Sendable` declarations.

## Queue output and shutdown

`QueueWorkerOutputChannel` removes the mutable callback-box construction cycle. App-local and daemon assembly use the same typed output boundary.

The channel preserves the established contract for each output type:

- progress publishes before persistence;
- transcript persists before publication;
- final usage publishes before persistence;
- live usage is runtime-only;
- run paths publish before persistence;
- pending permission is runtime-only.

Each worker dispatch has a unique `WorkerLeaseID`. Output and transcript state use the exact lease owner. A stale worker cannot revoke or settle a replacement dispatch.

`QueueEngine.shutdownForHandoff()` rejects new work, invalidates output leases, cancels workers, requeues running items, resolves waiters, finishes event streams, and waits for settlement. A blocked shutdown retains all resources and returns active item identifiers.

## Ownership and wire contract

`DaemonQueueHost` is the only daemon queue admission point. It serializes lazy construction, queue operations, and relinquishment by ownership epoch. The relinquished state is permanent for the daemon process.

Every queue RPC reply uses a versioned typed envelope in `Data`. Unsupported versions, ownership transitions, and invalid envelopes fail closed.

Queue item completion remains a domain `Result`. Transport and ownership failures still throw.

## Production migration

`QueueRuntimeAssembly` uses Cordis components for the store handle, providers, worker factories, output channel, and engine. It returns a concrete `QueueRuntimeHandle` and does not expose its Cordis context.

`LocalQueueRuntimeController` is the app-local runtime owner. It provides one stable `QueueEngineHotSwap` facade and uses a generation-owned single-flight transition claim.

The controller supports these ownership transitions:

1. Start one local runtime.
2. Block dispatch before daemon takeover.
3. Dispose the local runtime and close its store.
4. Quarantine a blocked runtime and refuse a second owner.
5. Retry blocked shutdown after worker settlement.
6. Fail closed after daemon invalidation.
7. Create local fallback only after complete relinquishment for the expected epoch.
8. Adopt a fresh serving daemon when daemon replacement resets the epoch.

## Review

The implementation author used the OpenAI model family.

A heterogeneous GLM 5.2 Max review found two high-severity reconnect gaps:

- blocked local shutdown had no production retry route;
- daemon epoch reset could leave ownership unresolved forever.

The implementation fixed both gaps and added deterministic controller tests.

The review also found stale dispatch transcript ownership. The implementation now keys worker output and transcript state by the exact in-memory lease.

The final GLM re-review reported no remaining critical, high, or medium findings.

## Verification

These commands passed at the final reviewed revision:

```text
make build
make test
swift build
swift test
swift test --filter StoreConcurrencyTests
WIKIFS_APP_TESTS=1 swift test --filter LocalQueueRuntimeControllerTests
WIKIFS_APP_TESTS=1 swift test --filter 'LocalQueueRuntimeControllerTests|QueueEngineHotSwapTests|DaemonHealthMonitorTests|WikiDaemonWorkloadHostTests|WikiDaemonHeartbeatTests'
swift test --filter 'CordisTests|QueueRuntimeAssemblyTests|QueueWorkerOutputChannelTests|QueueAssemblyContractTests|QueueEngineTests|QueueTranscriptConcurrencyTests|WikiDaemonQueueWireTests|UnavailableQueueEngineTests|QueueEngineClientConformanceTests'
```

Final results:

- final `make test` and bare `swift test`: 3,366 tests in 311 suites each;
- focused default Cordis and queue gate: 101 tests in 15 suites;
- focused opt-in ownership gate: 63 tests in seven suites;
- store concurrency gate: 10 tests;
- signed app bundle: built successfully.

The mutation tool produced useful pure-value survivors for `ServiceKey` and `ComponentState`. Tests now cover them. Version 1.3.0 could not produce meaningful actor-runtime schemata, so those mutants were unviable.

## Deferred work

This change does not add a Cordis event bus, dynamic loader, proxy layer, HMR, SwiftUI lookup, daemon composition, or session conversion.

Possible follow-ups include daemon transport composition, extraction backend registration, renderer-provider lifetimes, and ACP provider discovery. Each follow-up needs a separate plan.
