---
timestamp: 2026-07-24T051811Z
title: "refactor: Extract the app↔daemon XPC contract into a `WikiDaemonContract` module"
branch: null
status: historical
timestamp_source: git-commit
---

# refactor: Extract the app↔daemon XPC contract into a `WikiDaemonContract` module

## Progress


**Goal:** make the XPC boundary between the `wikid` service and its clients
explicit. The contract was previously smeared across `WikiFSCore` (the two `@objc`
protocols, buried in a 131-file module) and `WikiCtlCore` (`WikiDaemonError`, mixed
into the client transport).

**What changed:** new Foundation-only leaf module **`WikiDaemonContract`** holding
exactly the contract — `WikiDaemonProtocol`, `WikiDaemonEventSink`,
`WikiDaemonError`, plus a `Contract.swift` module doc. No DTOs moved: every payload
crosses the wire as JSON `Data`, so the protocols reference no domain types and the
DTOs stay in `WikiFSCore`/`WikiFSEngine`. Depended on by `wikid` (server), `WikiFS`
(app), and `WikiCtlCore` (typed client); `WikiFSCore`/`WikiFSEngine` do not depend
on it. All source is `#if os(macOS)` (empty on Linux). See
`plans/xpc-service-migration.md`.

**Files:** new `Sources/WikiDaemonContract/{WikiDaemonProtocol,WikiDaemonError,Contract}.swift`
(protocol `git mv`'d from `WikiFSCore/Core/`, error extracted from
`WikiCtlCore/WikiDaemonConnection.swift`); `import WikiDaemonContract` added at the
real use sites (`wikid/main.swift`, `wikid/WikiDaemon.swift`,
`WikiCtlCore/{WikiDaemonConnection,DaemonWorkloadClient}.swift`,
`WikiFS/Queue/DaemonQueueEventSink.swift`, three daemon test files); `Package.swift`
gains the target + edges.

**Evidence:** `swift build` ✓ (all products link); `swift test --filter` over the 5
daemon/contract suites ✓ (56 tests); WikiFSCore clean of the moved symbols.

---

## Verification

Historical verification remains in the progress record above.
