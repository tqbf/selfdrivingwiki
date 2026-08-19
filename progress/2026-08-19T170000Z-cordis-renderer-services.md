---
timestamp: 2026-08-19T17:00:00Z
title: Cordis renderer services
branch: feature/cordis-renderer-services
status: implementation
---

# Cordis Renderer Services

## Progress

The app now owns one private Cordis renderer domain. Renderer startup no longer depends on a SwiftUI scene task.

### Service domain

`RendererServices` defines the installed renderer operations. Each successful operation returns one immutable `RendererPreparation`.

`RendererRuntimeAssembly` registers seven typed capabilities. Each component resolves its declared dependencies through `ActivationContext.require`.

`RendererRuntime` owns admission and a cancellation-aware FIFO mutation gate. Installation retries stale generations from the original directory.

The runtime prepares descriptors and providers from one machine-index generation. A failed provider removes only its package from the preparation.

### Process composition

`RendererCompositionOwner` owns assembly, bundled bootstrap, publication admission, and shutdown.

The owner exposes one stable `MutableRendererServices` facade. It rejects late installation and disposes late runtime handles.

`WikiFSApp` starts the owner during app initialization. The app publishes the startup preparation through the owner atomic consume operation.

App termination stops active app work before renderer shutdown. Repeated renderer shutdown is safe.

### UI boundary

`InstalledRendererHost` now receives only `RendererServices`. It converts preparations into main-actor factory inputs.

SwiftUI views, settings models, WebKit sessions, active panes, and source preferences remain outside Cordis.

Existing materialized session configurations retain their original providers after a later preparation changes the registry.

### Compatibility

The migration keeps the machine package-store layout and SQLite authority. It does not change package identifiers, versions, registrations, URLs, JSON, or preferences.

Bundled Excalidraw bootstrap remains machine-scoped and idempotent. Identity and hash conflicts fail closed.

## Verification

These checks passed:

- `swift build --target WikiFS` with warnings as errors;
- the full opt-in app-test graph compilation;
- `RendererRuntimeAssemblyTests`: 9 tests;
- focused host, settings, scheme-handler, and WebKit session tests: 31 tests;
- `InstalledRendererHostTests`: 6 tests, including immutable pane pinning;
- `make build`, including signed app assembly;
- `make test`: 3,442 tests in 331 suites;
- `swift build` and `swift test`: 3,442 tests in 331 suites;
- the full opt-in app test suite with `WIKIFS_APP_TESTS=1`.

The independent review found no critical, high, or medium issues. It reported one low test-coverage risk for direct mutation-gate race tests. The startup publication race found during review is fixed and has a deterministic regression test.
