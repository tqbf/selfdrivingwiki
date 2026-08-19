---
timestamp: 2026-08-19T22:15:00Z
title: Cordis daemon transport services
branch: feature/cordis-daemon-transport
status: implementation
---

# Cordis Daemon Transport Services Progress

**Date:** 2026-08-19

## Progress

The migration added a typed daemon transport contract and runtime to `WikiFSEngine`.

`DaemonTransportRuntimeAssembly` composes four fixed services in one private Cordis context. Registration order does not control activation order.

`DaemonTransportRuntime` owns attempts, health probes, retries, candidate acceptance, invalidation, interruption, and disposal.

`DaemonTransportCompositionOwner` owns asynchronous assembly. It supplies one stable facade before assembly completes.

`DaemonTransportAppBridge` keeps `WikiDaemonConnection` outside the Engine assembly. It registers concrete connections by exact candidate ID.

`DaemonTransportAppCoordinator` now owns app queue and chat acceptance policy. It publishes connected state only after queue activation succeeds.

`DaemonHealthMonitor` now maps typed transport events to UI state. It no longer owns XPC connections or a retry loop.

App termination stops transport first. It then disposes queue, search, extraction, and renderer runtimes in the existing order.

## Preserved behavior

The XPC protocol and workload payloads did not change.

Queue ownership epochs and relinquishment rules did not change.

Invalidation still marks daemon ownership unresolved and clears chat.

Interruption still registers a new event sink on the same connection without a UI disconnect.

The app does not terminate the embedded daemon process.

## Verification

The Engine and app targets compile with SwiftPM.

Twelve daemon transport runtime tests pass. They cover assembly, acceptance, invalidation, interruption, expiry, and late probe shutdown.

Six presentation adapter tests pass in the opt-in app-test target.

Cordis source policy and daemon transport boundary policy tests pass.

`make build` produced a signed app bundle.

`make test` passed 3,471 tests in 335 suites.

The split opt-in app regressions passed 19 queue tests, 7 connection health tests, and 18 daemon workload tests.

The final independent re-review reported no critical, high, or medium findings.
