# Cordis Composition Authority Cleanup

Status: implemented on `feature/cordis-composition-authority`.

## Purpose

Cordis composes stable headless capabilities. It owns dependency settlement,
profile lifetimes, and reversible activation effects.

Cordis is not a global service locator. Normal application code receives typed
facades and opaque lifetime handles. It cannot inspect or mutate a
`CordisContext`.

## Service inclusion rules

A Cordis service must have a stable typed `Sendable` contract. A component must
declare each stable dependency and resolve it during activation.

Use Cordis when dependency order, substitution, lifetime, or cleanup affects a
capability. Keep active operation state and application ownership outside the
service graph.

Cordis service values must not contain these application objects:

- `WikiStoreModel`
- `SearchCompositionOwner`
- `GenerationGate`
- `AgentLauncher`
- `ProfileWikiSession`
- `BootedProfile`
- `CordisContext`

A service key must not use `any Sendable` as its value type. Each key names a
specific capability contract.

## Opaque profile lifetimes

`ProfileLifetime` owns one `BootedProfile`. It exposes idempotent shutdown and
internal child-profile boot operations.

The type does not expose the profile or its context. It rejects a new child boot
after shutdown starts. It also rejects a late child result and shuts that child
down.

`AppServices` and `AppProcessServices` contain resolved typed capabilities.
Normal app and daemon code retain these facades plus `ProfileLifetime`.

The main-actor session factory resolves stable services once. It then creates
`WikiStoreModel`, `SearchCompositionOwner`, the launcher pair, and
`ProfileWikiSession` outside Cordis.

## Store capability exception

`StoreServiceKeys.store` keeps `any WikiStore` under the fixed `wiki.store`
label. This is an explicit repository exception.

The store has a stable typed contract and a child-profile lifetime. Its methods
are atomic. No database transaction, statement, connection, or connection state
can escape a method call.

This exception avoids an artificial facade over the full repository contract.
It does not permit a raw database connection in Cordis.

## Narrow read capability

`StoreServiceKeys.readService` supplies `WikiReadService` under the
`wiki.store.read-service` label.

`WikiReadService` owns its read-only connection pool privately. Consumers never
receive `WikiReadPool` or a read-only store.

Each `asyncRead` call receives a borrowed `WikiReadAccess`. The facade is
noncopyable and non-Sendable. It exposes only the value reads needed by search,
metadata hydration, and transclusion.

Shutdown first rejects new reads. It waits for admitted reads, closes idle
connections, and becomes stopped. A resolved service returns
`WikiReadServiceError.unavailable` after shutdown starts.

## Daemon wiki creation

Production `WikiDaemon` receives `StoreBootstrap`, not `makeStore`.
`StoreBootstrap` creates and seeds database artifacts without returning a live
store connection.

`DaemonWikiCreationCoordinator` owns create admission and request state. It
uses these ordered steps:

1. Reserve a typed wiki ID.
2. Bootstrap and seed the database.
3. Save the registry descriptor and Home page ID.
4. Boot and resolve the child profile.
5. Publish the resolved services and exact child-profile store.
6. Return success after publication.

A failed or canceled create rolls back in reverse order. It removes child
services, removes the registry descriptor, and deletes the database files.
Cleanup errors are logged without replacing the primary error.

Delete and shutdown wait for an in-flight create for the same wiki. Shutdown
rejects new requests before it drains work and disposes profiles.

## Process dependency contracts

`ProcessServiceKeys.compositionInputs` supplies `ProcessCompositionInputs`
under the `process.inputs` label. Process plugins declare and resolve this key
before they install process services.

The inputs include typed readers and factories for agent configuration,
credentials, command resolution, permission policy, extraction configuration,
HTTP requests, and local extractors.

App-only queue, transport, and renderer owners stay outside Cordis. The app
boundary supplies narrow `Sendable` assembly gateways for these owners.

`ProcessServiceKeys.renderer` uses `any RendererServices`. The service no longer
uses an erased `any Sendable` value.

`ProcessServiceKeys.embeddings` supplies `EmbeddingsSearchProvider`. The app
installs the MLX implementation. The Linux diagnostic path installs an explicit
unavailable implementation.

`ProcessServiceKeys.urlFetchProvider` and
`ProcessServiceKeys.zoteroClientProvider` supply typed integration factories.
Zotero resolves one configuration and credential snapshot for each client.
The integration registry distinguishes registration from runtime availability.

## Deliberate non-Cordis boundaries

The following values remain outside Cordis:

- active launchers and generation gates
- SwiftUI models, controllers, and per-wiki sessions
- chat, queue, and extraction operation state
- XPC connections, callbacks, and event sinks
- WebKit views and active renderer sessions
- File Provider projection connections
- registry and database bootstrap before a profile exists
- renderer source fallback and profile-selected extraction fallback
- Linux diagnostic fixtures

Framework and UI objects can cross a composition boundary only through a narrow
`Sendable` gateway. They do not become service values.

Direct embedding calls inside `GRDBWikiStore`, `WikiStoreModel`, and
`PageUpsert` remain a deliberate legacy boundary. A separate design must move
those calls because they are not Cordis plugin activation paths.

## Enforcement

`scripts/check-cordis-boundaries` rejects hidden production store factories,
untyped service keys, forbidden application objects in service keys, exposed
contexts, and undeclared process inputs.

Compiler fixtures verify that typed facade operations compile. Negative
fixtures verify that `.profile`, `.context`, `require`, `find`, and `supply` are
not available to normal application code.

Behavior tests verify exact service identity, rollback, lifecycle rejection,
partial activation cleanup, dependency substitution, and component registration
order. Source policy tests enforce boundaries that Swift cannot express.
