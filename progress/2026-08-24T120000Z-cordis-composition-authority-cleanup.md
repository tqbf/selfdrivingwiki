---
timestamp: 2026-08-24T120000Z
title: Cordis composition authority cleanup
branch: feature/cordis-composition-authority
status: complete
---

# Cordis Composition Authority Cleanup

## Progress

Cordis now composes stable macOS production capabilities. Application and
operation objects remain outside the service graph.

The implementation record is
`plans/cordis-composition-authority-cleanup.md`.

## Opaque profile ownership

`ProfileLifetime` now owns each booted profile. It provides idempotent shutdown
and rejects child boot after shutdown starts.

Application facades contain typed services and a lifetime handle. They do not
expose `BootedProfile` or `CordisContext`.

The main-actor session factory now creates `WikiStoreModel`, the search owner,
the launcher pair, and `ProfileWikiSession`. Cordis supplies only their stable
capabilities.

## Daemon wiki creation

Production `WikiDaemon` no longer accepts `makeStore`. It receives
`StoreBootstrap` and resolves the live store from the new child profile.

`DaemonWikiCreationCoordinator` owns admission, registry persistence, profile
publication, cancellation, and rollback. Failed creation removes the registry
entry and all database artifacts without replacing the primary error.

The XPC exporter keeps the existing `Data?` reply shape. It owns the asynchronous
creation task and replies once.

## Read boundary

`WikiReadService` replaced the public `WikiReadPool` service. The actor owns its
read-only pool and rejects new reads after shutdown starts.

Each read receives a noncopyable `WikiReadAccess`. The facade returns Sendable
values and does not expose a store, connection, statement, or transaction.

Search, metadata hydration, and transclusion now use this capability.

## Process dependencies

The renderer key now uses `any RendererServices`. Embedding, URL fetch, and
Zotero dependencies use typed process keys.

Agent and extraction plugins declare `process.inputs`. They resolve typed
configuration, credential, command, permission, HTTP, and factory inputs during
activation.

App-only queue, transport, and renderer owners remain outside Cordis. Narrow
Sendable gateways connect these owners to process activation.

## Policy and tests

The boundary checker now rejects hidden production store factories, erased
service keys, forbidden service values, context exposure, and missing process
inputs.

Compiler fixtures prove that typed facade operations compile. Negative fixtures
prove that profile, context, `require`, `find`, and `supply` access does not
compile.

Behavior tests cover exact store identity, daemon rollback, profile shutdown,
read disposal, process dependency substitution, and shuffled component
registration.

## Deliberate exceptions

`any WikiStore` remains the method-atomic repository capability. No connection
state escapes a method call.

UI models, sessions, launchers, gates, operation state, XPC connections, WebKit
sessions, File Provider connections, and pre-profile bootstrap remain outside
Cordis.

Direct embedding calls in store and model code remain a documented legacy
boundary for a separate design.

## Verification

Focused daemon, profile, read-service, process dependency, integration,
renderer, compiler-boundary, and documentation tests pass.

`make build` and `make check-cordis` pass. The final full gate matrix runs before
pull-request creation.
