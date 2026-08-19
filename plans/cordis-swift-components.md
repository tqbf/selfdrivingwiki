# Swift Cordis Components

**Status:** Implemented. The runtime, queue spike, and production app-local migration passed their gates.

**Provenance-Mode:** `clean-room behavior implementation`

## 1. Purpose

This record defines a small Swift component runtime named `Cordis`.

The runtime will first assemble one test-only queue runtime. Production queue migration can start only after the runtime and spike gates pass.

Cordis does not replace SwiftUI dependency injection. It does not own wiki state, sessions, SQLite connections, XPC connections, or daemon transport.

## 2. Authority and provenance

The original Cordis revision defines lifecycle behavior:

- Cordis: [`8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4`](https://github.com/cordiverse/cordis/tree/8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4)
- cordis4j: [`6c210e5cdc10766190074d63ee35d6c32e4f39bd`](https://github.com/1na-ko/cordis4j/commit/6c210e5cdc10766190074d63ee35d6c32e4f39bd)
- Primer: <https://deepseek-harness.github.io/deepseek-harness/en/reference/cordis-primer>

Original Cordis takes precedence when the references disagree. cordis4j supplies only static typing, explicit context API, and concurrency guidance.

This work uses observable behavior as evidence. It does not copy source code or translate substantial test structures.

The evidence comes from these pinned Cordis suites:

- `packages/core/tests/service.spec.ts`
- `packages/core/tests/fiber.spec.ts`
- `packages/core/tests/dispose.spec.ts`
- `packages/core/tests/plugin.spec.ts`
- `packages/core/tests/isolate.spec.ts`
- `packages/core/tests/shadow.spec.ts`
- `packages/core/tests/invoke.spec.ts`

Both references use the MIT License. Original Cordis states `Copyright (c) 2021-present Shigma`. cordis4j states `Copyright (c) 2025 Cordis4j contributors`.

The clean-room mode does not retain copied or translated material. If implementation work later retains such material, change the provenance mode and add both required MIT notices.

## 3. Runtime boundary

The `Cordis` SwiftPM target imports Foundation only. It has no product dependencies.

The package uses Swift tools 6.0 and macOS 26.0. Command-line SwiftPM is the platform authority.

Cordis stores only `Sendable` service values. Queue assembly can register these values:

- immutable `Sendable` values;
- actors;
- protocol existentials declared `Sendable`;
- existing audited `Sendable` reference types;
- explicit `@MainActor @Sendable` gateway closures.

Cordis must not add unchecked conformances to UI or model objects. It must not store a SQLite connection, statement, transaction, or column state.

## 4. Semantic matrix

| Swift behavior | Pinned evidence | Swift contract |
| --- | --- | --- |
| Pending activation | `service.spec.ts`, `pending inject` | Registration is dormant. A component stays `pending` until every dependency resolves to an active provider. |
| Replacement and reactivation | `service.spec.ts`, `compare snapshot`; `fiber.spec.ts`, restart and inertia tests | Provider withdrawal invalidates exact consumers. A replacement provider creates a new dependency generation and can reactivate them. |
| Provider-visible dependent teardown | `fiber.spec.ts`, inertia tests; `isolate.spec.ts` | Swift strengthens the observed ordering. Dependent cleanup can still resolve the provider that is being withdrawn. |
| LIFO effects | `dispose.spec.ts`, yielded cleanup tests | Dispose owned effects in strict reverse registration order. |
| Activation rollback | `dispose.spec.ts`, aborted and error tests | Swift strengthens partial cleanup into an activation transaction. Failed or stale activation publishes no service and disposes all collected effects. |
| Stale async suppression | `fiber.spec.ts`, inertia lock tests | Each attempt has a generation. Only the current generation with unchanged provider identities can commit. |
| Context hierarchy | `plugin.spec.ts`, `isolate.spec.ts`, `shadow.spec.ts`, `invoke.spec.ts` | A child reads local services, then ancestors. A parent never reads a child. A child can shadow an ancestor. |
| Duplicate services | No complete upstream duplicate rule | Swift rejects a second live provider for the same key in one context. Child shadowing is not a duplicate. |
| Cascade disposal | `plugin.spec.ts` nested disposal; `dispose.spec.ts` nested effects | A parent disposes children before parent-owned services and effects. Repeated disposal is a no-op. |
| Cleanup errors | `fiber.spec.ts`, `dispose error`; primer leaves aggregation open | Swift continues all cleanup and reports a structured aggregate. It never matches error text. |
| Retry | Explicit restart behavior exists. Automatic retry is not specified. | Failure does not retry with unchanged dependencies. `restart()` or a dependency-generation change starts a new attempt. |
| Cycles | No pinned cycle contract | Swift rejects same-activation self-use and declared self-dependency with a typed error. General mutual cycles stay pending and appear in diagnostics. |

## 5. Service identity and lookup

`ServiceRealm` is a typed realm identifier. The API does not expose a magic sentinel string.

`ServiceKey<Value: Sendable>` contains these identity parts:

1. the Swift value type;
2. an explicit service identity;
3. a `ServiceRealm`.

Keys with different value types, identities, or realms never compare equal after erasure.

A context lookup starts in the current context. It then walks each parent. A local provider shadows an ancestor provider with the same key.

A context rejects a second live provider for the same key in that context. This rule applies to ambient and component providers.

A provider identity is unique for one committed supply. Consumers record the exact identity used for every dependency.

## 6. Activation transaction

User activation runs outside the runtime actor. The actor owns all lifecycle state and commit decisions.

An activation receives an attempt-scoped capability. The capability includes the component ID and generation.

Each `supply` and effect registration stages data in that attempt. Staged supplies are not visible to ambient lookup or other components.

The runtime commits one activation atomically. The commit succeeds only when all these facts remain true:

1. the context is live;
2. the component still exists;
3. the component is `loading`;
4. the generation matches;
5. the attempt capability is active;
6. every dependency still resolves to the recorded provider identity;
7. no staged supply conflicts with a live local provider.

The commit publishes all staged supplies and changes the component to `active` in one actor operation.

Invalidation revokes the capability before task cancellation or cleanup. Later registration calls fail with a typed inactive-attempt error.

A failed, cancelled, or stale attempt never publishes staged supplies. It disposes staged effects in LIFO order.

A component cannot resolve its own staged supply during activation. Such a request returns a typed self-cycle error.

## 7. Lifecycle state and settlement

A component uses this finite state machine:

```text
registered -> pending -> loading -> active -> unloading -> pending
               |           |          |          |
               |           |          |          +-> disposed
               |           |          +------------> disposed
               |           +-> failed -> loading (restart or dependency generation)
               +------------------------------------> disposed
```

Only the listed transitions are legal. Runtime transition logic rejects all other moves.

`awaitSettled()` waits for the component generation that exists when the call starts. It returns when that generation is not `loading` or `unloading`.

`pending`, `active`, `failed`, and `disposed` are settled states. State inspection remains safe after disposal.

The runtime owns every activation task. It uses no detached task. Disposal cancels and awaits each owned task.

## 8. Provider withdrawal and component disposal

Provider withdrawal uses the exact provider identity, not only the service key.

The runtime performs these steps:

1. Revoke in-flight attempts that depend on the provider.
2. Find direct and transitive consumers of the exact provider.
3. Move consumers to `unloading` from leaves to roots.
4. Cancel and await their activation tasks.
5. Drain each consumer's dependents.
6. Unpublish the consumer's committed supplies.
7. Run the consumer's effects in LIFO order while its dependency providers remain visible.
8. Continue after cleanup failures and collect them.
9. Remove the original provider after all consumers finish.
10. Reevaluate pending and failed declarations against the new dependency generation.

A component's own supplies are not visible during its own cleanup. Its dependency providers remain visible until its cleanup finishes.

Disposal is idempotent during loading, active, unloading, failed, and disposed states.

An effect handle is also idempotent. A component or context disposal returns one `CleanupAggregateError` when any disposer fails.

## 9. Context disposal

A parent context owns its child contexts. Parent disposal starts child disposal first.

After all children settle, the parent drains its components and ambient supplies. It then marks itself disposed.

After disposal starts, the context rejects registration, supply, lookup requirements, restart, and child creation. Repeated disposal and safe state inspection remain valid.

## 10. Diagnostics and intentional omissions

The first runtime exposes diagnostics for pending components and unresolved dependencies. A general mutual dependency cycle remains pending with a cycle diagnostic.

This phase intentionally excludes:

- event dispatch and event modes;
- loader configuration and expression evaluation;
- interception overlays;
- hot module replacement;
- decorators and proxies;
- callable-service proxies;
- dynamic package or module loading;
- SwiftUI lookup integration.

## 11. Existing queue-output contracts

`QueueWorkerOutputChannel` will exist before factories and the engine. It will use the same broadcaster, store, and transcript reducer as the engine.

| Output | Payload identity | Publication and persistence order | Error behavior | XPC serialization |
| --- | --- | --- | --- | --- |
| Progress | `QueueItem.ID` and line | Broadcast, then append progress | Log persistence failure. Keep the event delivered. | Queue event envelope fields |
| Transcript | `QueueAttemptID`, ordered batch, changed items | Translate and reduce serially. Persist each update, then broadcast. | Existing transcript reducer logs persistence failure and does not broadcast an unpersisted update. | Typed transcript update JSON in `Data` |
| Final usage | `QueueItem.ID` and cumulative `SessionUsage` | Broadcast, then encode and persist activity | Log encode or persistence failure. Keep the event delivered. | `SessionUsage` JSON in `Data` |
| Live usage | `QueueItem.ID` and current `SessionUsage` | Broadcast only | No persistence operation | `SessionUsage` JSON in `Data` |
| Run paths | `QueueItem.ID`, log URL, debug URL | Broadcast, then persist absolute URL strings | Log persistence failure. Keep the event delivered. | URL fields in the queue event envelope |
| Pending permission | `QueueItem.ID` and optional `PendingPermission` | Broadcast only | No persistence operation | Full optional permission payload in the queue event envelope |

The typed channel API calls the fifth output `emitRunPaths`. It replaces the current `makeEmitLogPaths` name and its stale runtime-only comment.

The current XPC decoder drops the encoded pending-permission value and emits `nil`. The new typed envelope must preserve the full payload. This corrects payload identity without changing persistence order.

Terminal item state stays durable before a terminal completion or failure event becomes observable.

This work does not introduce one universal persistence order. Any future ordering change needs a separate plan and operator decision.

## 12. Worker output leases

A durable retry attempt does not identify one in-memory dispatch. Each dispatch gets a separate `WorkerLeaseID`.

The engine creates a `QueueWorkerOutputScope` for one item, attempt, and lease. The worker receives this scope when the factory creates it.

All output calls include the lease through the scope. The output channel checks its lock-protected active lease registry before translation, persistence, or broadcast.

Shutdown, halt, cancellation, and replacement invalidate the lease before they cancel or requeue work.

A stale worker can finish its local call stack. It cannot perform these actions:

- mutate queue state;
- emit output;
- finish transcript state;
- resume completion waiters;
- decrement provider capacity;
- dispatch replacement work.

## 13. Queue-engine lifecycle and shutdown

The local engine uses this finite state machine:

```text
created -> starting -> running -> shuttingDown -> shutDown
                         |             |
                         |             +-> shutdownBlocked -> shuttingDown
                         +-> shuttingDown
```

Only `start` is valid in `created`. Queue operations are valid in `running`.

After shutdown starts, enqueue, retry, resume, reorder, and new dispatch throw `QueueEngineLifecycleError.shuttingDown`.

`shutdownForHandoff()` performs these steps:

1. Atomically enter `shuttingDown`.
2. Reject new work and dispatch.
3. Invalidate every active worker lease.
4. Cancel every engine-owned worker task.
5. Requeue each still-running item once. Preserve attempt and ordering key.
6. Await worker settlement.
7. Resume completion waiters with a typed shutdown error.
8. Retire transcript attempts.
9. Finish the event broadcaster.
10. Return success only when no engine task or output scope can reach a factory or provider.

The shutdown deadline diagnoses an uncooperative worker. It does not authorize resource release.

Production uses `ContinuousClock`. Tests use an injected manual deadline scheduler and fire it only after cancellation is observed.

A deadline produces `shutdownBlocked(activeItemIDs:)`. The owner retains the engine, store, factories, providers, output channel, and tasks.

A later explicit retry can finish shutdown after workers settle. `QueueStore.close()` remains outside the engine.

## 14. Queue client failure contract

Before daemon wire changes, all transported `QueueEngineClient` commands and reads move to one typed failure model.

Fallible commands and reads use `async throws`. The migration updates the engine, unavailable client, hot-swap facade, XPC proxy, test fakes, and all consumers in one compiler-gated change.

UI owners catch failures, log them with `DebugLog`, and expose unavailable or stale state. They must not convert ownership rejection into `Void`, zero, false, or an empty value.

`waitForCompletion` can keep its explicit `Result` because completion failure is its domain value. Transport and ownership failure must still remain distinguishable.

## 15. Daemon queue ownership

A dedicated `DaemonQueueHost` actor exclusively owns these values:

- the queue ownership epoch;
- `QueueStore`;
- `QueueEngine`;
- output channel and factories;
- the daemon event-forwarding task;
- in-flight RPC admission count;
- the single-flight construction task.

`WikiDaemon.ensureQueueEngine()` will not remain as a queue admission API. Every exported queue selector must use the host's operation-generic admission method.

A source-policy test will enumerate queue selectors and reject direct engine, store, or legacy `ensureQueueEngine` access outside the host.

The host uses these states:

```text
serving(epoch) -> relinquishing(epoch) -> relinquished(completedEpoch)
                         |
                         +-> shutdownBlocked(epoch, activeItemIDs)
                                  |
                                  +-> relinquishing(epoch)
```

`relinquished` is permanent for the daemon process. No RPC can construct another queue engine after that transition.

An RPC admitted before `relinquishing` increments the admission count. It must settle or abort before relinquishment acknowledgement.

An RPC admitted after that transition receives a typed ownership-transition error. It cannot start lazy construction.

## 16. Versioned daemon replies

Every queue RPC returns JSON `Data` containing one versioned typed result envelope.

The envelope carries these common fields:

- protocol version;
- ownership epoch;
- daemon host state;
- operation-specific payload or typed error.

Unknown versions fail with a typed protocol error. Clients fail closed and mark the queue unavailable.

Relinquishment success carries the completed epoch and these four true facts:

- `dispatchStopped`;
- `workersSettledOrRequeued`;
- `forwardingStopped`;
- `storeClosed`.

The daemon sends success only after the host enters permanent `relinquished` state. A blocked shutdown returns active item IDs and retains all resources.

XPC interruption only re-registers the event sink. XPC invalidation or failed health moves the app to `daemonOwnershipUnresolved`.

## 17. App ownership and synchronous bootstrap

`LocalQueueRuntimeController` is app-scoped and `@MainActor`. It owns at most one live `QueueRuntimeHandle`.

`WikiFSApp.init` constructs the controller and stable client facade synchronously. The controller owns one startup task in stored state.

Queue operations await startup settlement. Startup failure installs `UnavailableQueueEngine` behavior and preserves the current user-visible database error.

The controller cancels and awaits its startup task during disposal. No setup or forwarding task is unowned.

The controller uses these states:

```text
unavailable
startingLocal -> localReady -> shuttingDownForDaemon -> daemonActive
                         |                |
                         |                +-> shutdownBlocked
                         +-> disposing

daemonActive -> daemonOwnershipUnresolved -> fallingBack -> localReady
```

The controller installs a daemon proxy only after local shutdown, component cleanup, and store closure succeed.

After daemon loss, the controller does not infer relinquishment. It waits for a typed reply for the expected epoch with all four completion facts.

A missing, stale, incomplete, blocked, interrupted, or undecodable reply keeps the stable client unavailable. It never opens a competing local store.

`QueueEngineHotSwap` remains a stable forwarding facade. It never owns a Cordis context or runtime handle.

## 18. Queue Cordis boundary

The test spike and later production assembly can register only these queue values:

- a `QueueStore` handle that already satisfies the reviewed `Sendable` boundary;
- `QueueExtractionProvider` and `QueueIngestionProvider` existentials;
- extraction and ingestion worker factories;
- `CompositeWorkerFactory`;
- `QueueWorkerOutputChannel`;
- `QueueEngine`.

The assembly returns a concrete `QueueRuntimeHandle`. It does not expose its Cordis context.

Runtime disposal shuts down the engine first. It then disposes engine, factory, and provider components. It closes `QueueStore` last.

Cordis must not contain these values:

- a SwiftUI view;
- `WikiStoreModel`;
- `SessionManager`;
- SQLite connection state;
- an XPC connection or proxy;
- `QueueEngineHotSwap`.

Cordis does not run provider calls off their declared actor.

## 19. Gate results

All gates passed in order.

1. The Foundation-only runtime passed its lifecycle suite.
2. Concurrency reviews found two high-severity lifecycle races. The implementation fixed both races before queue work started.
3. The output channel and shutdown contract passed focused queue tests.
4. The test-only queue assembly removed all mutable emit boxes and setup tasks.
5. The Phase 3 decision was **go**. The spike met every production-migration condition.
6. The app-local migration passed focused and full repository tests.

The mutation tool found useful pure-value survivors in `ServiceKey` and `ComponentState`. Tests now cover those cases. The tool could not produce meaningful actor-runtime schemata with version 1.3.0. Those mutants were unviable, not survivors.

## 20. Implemented runtime API

The `Cordis` target contains these public contracts:

- `ServiceRealm` and `ServiceKey<Value>` for typed service identity;
- `CordisContext` for hierarchical context ownership;
- `ComponentDefinition` for declared dependencies and async activation;
- `ComponentHandle` for state, settlement, restart, and disposal;
- `ActivationContext` for attempt-local service and effect registration;
- `EffectHandle` for idempotent async cleanup;
- structured lifecycle, activation, cycle, and cleanup errors.

`CordisRuntime` is the actor-owned implementation. It owns component state, provider identity, dependency edges, activation generations, settlement waiters, and child contexts.

The implementation uses no detached tasks and no `@unchecked Sendable` declarations. User activation and cleanup run outside manual locks. Publication after an `await` requires a current generation and matching provider identities.

## 21. Implemented queue boundary

`QueueWorkerOutputChannel` now exists before the engine and worker factories. Both app-local and daemon assembly use it. It preserves the six output contracts in section 11.

Each worker dispatch receives a `QueueWorkerOutputScope`. Shutdown invalidates its lease before cancellation or resource release. A stale worker cannot publish or persist output.

`QueueEngine.shutdownForHandoff()` rejects new work, cancels workers, requeues running items, resolves waiters, finishes streams, and waits for worker settlement. A blocked shutdown retains every resource and returns the active item identifiers.

`QueueRuntimeAssembly` uses typed Cordis components for the store handle, providers, factories, output channel, and engine. `QueueRuntimeHandle` hides the Cordis context and closes the store only after engine and component shutdown.

The daemon does not use Cordis. `DaemonQueueHost` owns daemon queue resources, serializes admission by ownership epoch, and keeps the relinquished state permanent.

## 22. Production app migration

`LocalQueueRuntimeController` is the only app-local runtime owner. `WikiFSApp` constructs it synchronously and gives consumers one stable `QueueEngineHotSwap` facade.

The controller uses a generation-owned single-flight transition claim. A second direct transition fails closed before its first suspension point. Startup remains an owned task that daemon takeover can cancel and await.

Daemon takeover installs an unavailable client first. It then disposes the local runtime. It installs the daemon proxy only after shutdown, component cleanup, and store closure succeed.

A blocked local shutdown quarantines the full runtime handle. The controller refuses daemon takeover and another local assembly until an explicit retry succeeds.

After daemon invalidation, the controller marks ownership unresolved. It creates a local fallback only after a complete relinquishment reply for the expected epoch.

`QueueEngineHotSwap` owns no runtime resources. Its swap barrier cancels and awaits the old event forwarder and drains old admitted operations before it returns.

## 23. Wire and client behavior

Every queue RPC reply uses `QueueRPCEnvelope<Payload>` in JSON `Data`. The envelope carries its version, ownership epoch, host state, payload, or typed error.

Unsupported versions and ownership transitions throw typed errors. `DaemonWorkloadClient`, `XPCQueueEngineProxy`, `QueueEngineHotSwap`, and UI consumers do not convert these failures to zero, false, empty data, or normal completion.

The app treats XPC interruption as sink re-registration. Invalidation and health failure do not imply ownership relinquishment.

## 24. Verification evidence

The final local verification used these commands:

- `swift test --filter CordisTests` and repeated parallel runtime runs;
- focused queue, wire, shutdown, assembly, controller, hot-swap, daemon-host, and health-monitor filters;
- `swift test --filter StoreConcurrencyTests`;
- `make build`;
- `make test`;
- `swift build`;
- `swift test`;
- opt-in app tests with `WIKIFS_APP_TESTS=1`.

Before final review, the focused default gate passed 91 tests in 14 suites. The combined opt-in ownership gate passed 60 tests in seven suites. Both `make test` and bare `swift test` passed 3,363 tests in 310 suites.

A heterogeneous GLM 5.2 Max review found two high-severity reconnect gaps. The app did not retry blocked local shutdown. It also could not adopt a fresh serving daemon after an ownership-epoch reset. The implementation fixed both gaps and added deterministic controller tests.

The same review found a stale worker lease race. Worker cleanup now invalidates and settles the exact `WorkerLeaseID`. An old worker cannot revoke or settle a replacement dispatch.

After remediation, the focused default gate passed 101 tests in 15 suites. The combined opt-in ownership gate passed 63 tests in seven suites. Final `make test` and bare `swift test` each passed 3,366 tests in 311 suites.

The final heterogeneous re-review reported no remaining critical, high, or medium findings.

The full graph exposed two stale progress tests. They watched private factory callbacks. The tests now subscribe to the public engine event stream with cancellation-bounded waits.

## 25. Intentional deviations and non-goals

The Swift implementation strengthens original Cordis behavior in these areas:

- activation is an atomic staged transaction;
- cleanup failures aggregate after all cleanup runs;
- duplicate local supply is a typed error;
- provider-visible dependent teardown has explicit graph ordering;
- runtime-owned tasks and settlement are explicit.

The implementation still excludes these items:

- Cordis lookup from SwiftUI view bodies;
- conversion of `WikiStoreModel`, `WikiSession`, or `SessionManager`;
- Cordis ownership of XPC or daemon transport;
- a Cordis event bus;
- dynamic loaders, packages, decorators, proxies, and HMR.

The agent provider boundary now uses Cordis in both app and daemon processes. See `plans/cordis-agent-provider-composition.md`.

Remaining areas include extraction backend registration, renderer lifetimes, and daemon transport composition. Each area needs a separate plan and operator decision.
