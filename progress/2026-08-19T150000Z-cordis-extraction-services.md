---
timestamp: 2026-08-19T15:00:00Z
title: Cordis extraction services
branch: feature/cordis-extraction-services
status: review
---

# Cordis Extraction Services

## Progress

Implementation and all local gates are complete. An independent GLM 5.2 review found one high and three medium lifecycle issues. All issues are fixed. The re-review found no remaining critical, high, or medium issues.

### Implemented work

`WikiFSEngine` now defines `ExtractionServices`, `ExtractionPreparation`, `ExtractionRuntime`, and `MutableExtractionServices`.

`ExtractionRuntimeAssembly` registers eight typed capabilities. Each consumer component declares its dependencies and resolves them through `ActivationContext.require`.

The runtime reads one `ExtractionConfig` for each preparation. A backend override selects both the extractor and the provenance metadata.

Each preparation creates a new extractor. Existing Anthropic, Gemini, Docling Serve, ACP, and local pdf2md behavior remains available.

ACP still uses the configured provider and its existing credential. ACP still falls back to local pdf2md when no provider resolves.

### Process composition

`ExtractionCompositionOwner` owns asynchronous assembly, one runtime handle, and the stable facade.

The owner rejects late installation after shutdown. It disposes a late handle and makes shutdown idempotent.

`WikiFSApp` creates one extraction owner before queue and session composition. Direct extraction, queue extraction, sessions, and launchers receive the same facade or adapter.

`WikiDaemon` creates one extraction owner. Queue extraction, ingestion launchers, chat, and chat launchers receive the same facade or adapter.

Queue providers now use one operation preparation. The old `SourceDetailView` backend construction helper is removed.

### Lifecycle

Every accepted app termination path now returns `.terminateLater`. The app stops its local queue runtime before extraction disposal.

`GracefulShutdownPolicy` bounds app and daemon termination cleanup. `WIKIFS_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS` sets the deadline. The policy uses a named default when no valid override exists. A timeout logs the fallback, cancels cleanup, and completes termination.

Daemon shutdown relinquishes queue admission before it stops chat sessions and disposes extraction services.

A daemon process lifetime coordinator handles `SIGTERM` and `SIGINT`. It calls the same idempotent shutdown method, then exits the process. Tests inject a completion action instead of exiting.

### Boundaries

Cordis context APIs remain in approved `WikiFSEngine` assembly files.

Views, stores, sessions, XPC owners, renderer services, File Provider services, and transport services do not receive a Cordis context.

Logging remains unchanged. Existing `DebugLog` calls stay outside the service graph.

## Verification

The following focused checks passed:

- `ExtractionRuntimeAssemblyTests`: 7 tests;
- `ExtractionCompositionOwnerTests`: 5 tests;
- `GracefulShutdownPolicyTests`: 4 tests;
- `DaemonProcessLifetimeCoordinatorTests`: 2 tests;
- `ExtractionCompositionBoundaryTests`: 4 tests;
- `CordisSourcePolicyTests`: 6 tests;
- focused Cordis, queue extraction, session, and store concurrency suites;
- opt-in app integration filters: 86 tests in 6 suites;
- `make build`, including signed app assembly;
- `make test`: 3,442 tests in 331 suites;
- `swift build`;
- `swift test`: 3,442 tests in 331 suites.

The focused tests cover shuffled registration, typed missing components, configuration snapshots, backend overrides, distinct extractors, disposal, late assembly cleanup, process facade identity, and shutdown order.

### Deferred domains

This migration does not include these service domains:

- logging;
- renderer services;
- File Provider services;
- daemon transport services;
- stores and sessions.

These domains require separate plans and lifecycle reviews.
