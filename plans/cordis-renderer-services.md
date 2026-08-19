# Cordis Renderer Services

**Status:** Implemented

## Purpose

The app owns one private Cordis domain for installed renderer packages.

The domain resolves the machine registry, validates installed packages, and returns immutable preparations. SwiftUI and WebKit remain outside Cordis.

## Public facade

`RendererServices` is a `Sendable` protocol. It supports registry preparation, bundled bootstrap, local installation, exact removal, and exact safe-mode reset.

Each successful operation returns one `RendererPreparation`. The preparation contains one `RendererMachineIndex` and its matching providers.

The provider lookup uses `RendererPackageReservation`. It never exposes an installed package path.

## Snapshot rule

The runtime prepares providers from one machine-index value. It does not read the index again after a successful mutation.

The runtime omits a package when provider construction fails. Other valid packages remain available.

An earlier preparation does not change after a later registry mutation. Existing renderer panes keep their pinned session configuration.

## Service graph

`RendererRuntimeAssembly` registers these fixed labels:

| Label | Value |
| --- | --- |
| `renderer.package-store-layout` | Machine package-store layout |
| `renderer.machine-index-store` | Authoritative machine-index actor |
| `renderer.package-validator-factory` | Package validator factory |
| `renderer.resource-provider-factory` | Validated provider factory |
| `renderer.bundled-package-source` | Reviewed bundled package resolver |
| `renderer.runtime` | `RendererRuntime` actor |
| `renderer.services` | Public renderer facade |

Each component declares all dependencies. Each activation resolves its dependencies with `ActivationContext.require`.

Cordis controls activation order. Component registration order does not control activation order.

## Mutation policy

A cancellation-aware FIFO gate serializes index mutations across actor suspension points.

Installation validates from the original directory for each stale-generation retry. The runtime never reuses a consumed staged package.

Removal and safe-mode reset use the store bounded generation operations. Each operation prepares the returned index directly.

Identity conflicts and hash conflicts fail closed. Source fallback remains available.

## Process ownership

`RendererCompositionOwner` owns assembly, bundled bootstrap, publication admission, and shutdown.

The owner exposes one stable `MutableRendererServices` facade. The facade reports an unavailable error before installation and after shutdown.

`WikiFSApp` starts the owner during app initialization. Renderer startup does not depend on a SwiftUI scene task.

The owner publishes one startup preparation through an atomic consume operation. Shutdown invalidates admission before it awaits startup or disposes the runtime.

The renderer domain remains app-only. The `wikid` process does not create this runtime.

## UI and session boundary

`InstalledRendererHost` is the main-actor observation adapter. It converts a preparation into `InstalledRendererFactory.Inputs`.

These values stay outside Cordis:

- `InstalledRendererHost`;
- `InstalledRendererFactory`;
- `InstalledRendererSessionConfiguration`;
- SwiftUI views and settings models;
- WebKit objects and active renderer sessions;
- active panes and source preferences;
- SQLite connections, statements, and transactions.

Views and sessions receive the typed facade or immutable preparations. They never receive a `CordisContext`, `ActivationContext`, or `ServiceKey`.

## Lifecycle

The root `CordisContext` remains private to `RendererRuntimeHandle`. The handle exports only `RendererServices`.

Runtime disposal is idempotent. It rejects new work and queued mutations.

The owner cancels and awaits unfinished startup. It disposes a late assembly result and discards an unconsumed preparation.

App termination stops active app work before renderer disposal.

## Compatibility

The migration preserves package IDs, versions, registration IDs, SQLite records, derived JSON, URLs, and renderer preferences.

The bundled Excalidraw package remains machine-scoped and idempotent. Conflicting identities or hashes remain fail-closed.

Source fallback remains the default when the runtime, package, or provider is unavailable.
