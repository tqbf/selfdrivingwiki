# Cordis Extraction Services

**Status:** Implemented

## Purpose

Extraction is a core Cordis service domain in `WikiFSEngine`.

The service graph resolves extraction dependencies and returns one immutable preparation for each operation. The app and daemon each own one extraction context.

This migration preserves existing extraction behavior and persisted formats. Logging remains outside Cordis.

## Public contract

`ExtractionServices` is a `Sendable` protocol. It defines this operation:

```swift
func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation
```

`ExtractionPreparation` contains these non-secret values:

- a concrete `MarkdownExtractor`;
- the effective `ExtractionBackend`;
- the model version, when applicable;
- technique metadata, when applicable.

The preparation does not contain credentials, tokens, endpoints, or backend construction inputs.

## Snapshot rule

The runtime reads `ExtractionConfig` once for each preparation. It then selects `backendOverride ?? config.backend`.

The backend resolver reads the required credentials and constructs the extractor for that effective backend. The preparation reports metadata from the same configuration snapshot.

A settings change does not change an existing preparation. The next preparation reads the new settings.

Each preparation gets a new extractor. The process service does not share mutable extractor state between operations.

## Service graph

`ExtractionRuntimeAssembly` registers these fixed service labels:

| Label | Value |
| --- | --- |
| `extraction.configuration-reader` | `@Sendable () throws -> ExtractionConfig` |
| `extraction.credential-reader` | Typed extraction secret reader |
| `extraction.acp-resolver` | Typed ACP extraction resolver |
| `extraction.http-fetcher` | `HTTPRequestFetcher` |
| `extraction.local-extractor-factory` | Async Sendable local extractor factory |
| `extraction.backend-resolver` | Backend construction closure |
| `extraction.runtime` | `ExtractionRuntime` actor |
| `extraction.services` | Public `ExtractionServices` value |

Each consumer component declares its dependencies in `ComponentDefinition`. Each activation resolves those dependencies with `ActivationContext.require`.

Cordis controls activation order. Registration order does not control activation order.

## Backend behavior

The runtime preserves these backends:

- local pdf2md;
- ACP;
- Anthropic;
- Gemini;
- Docling Serve.

ACP uses the existing provider configuration and credential store. If no ACP provider resolves, the runtime uses local pdf2md.

Anthropic and Gemini preserve their default base URLs and configured model identifiers. Docling Serve preserves its endpoint and optional token behavior.

A backend override selects both the concrete extractor and the reported provenance. This fixes the previous daemon mismatch between the override and configured extractor.

## Process ownership

`ExtractionCompositionOwner` owns asynchronous assembly and one runtime handle. It exposes a stable `MutableExtractionServices` facade before assembly starts.

The facade returns `ExtractionServicesError.unavailable` until assembly succeeds. An assembly failure does not stop unrelated app or daemon features.

The app creates one owner in `WikiFSApp`. It gives the same facade to direct UI extraction, queue extraction, sessions, and launchers.

The daemon creates one owner in `WikiDaemon`. It gives the same facade to queue extraction, ingestion launchers, chat, and chat launchers.

No app or daemon consumer receives a `CordisContext`.

## Lifecycle

The owner retains its startup task. Shutdown cancels and awaits unfinished assembly.

A late assembly result cannot install after shutdown. The owner disposes that result instead.

Runtime disposal is idempotent. Disposal rejects later preparation requests.

App termination stops the local queue runtime before extraction disposal. Every accepted quit path uses asynchronous termination cleanup.

Daemon shutdown stops queue admission and drains queue resources. It then stops chat sessions and disposes extraction services.

The daemon process lifetime coordinator handles termination signals and calls the same shutdown method.

Process termination uses `GracefulShutdownPolicy`. The `WIKIFS_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS` environment value sets the deadline. A named default applies when the value is absent or invalid. After the deadline, the process logs the timeout, cancels cleanup, and completes termination without awaiting cancellation.

## Scope limits

These values stay outside the extraction context:

- `WikiStoreModel`, `WikiSession`, and `SessionManager`;
- SQLite and GRDB connections;
- queue ownership and daemon ownership epochs;
- XPC connections and event sinks;
- active chat and extraction operations;
- SwiftUI views and WebKit sessions;
- renderer, File Provider, and daemon transport services;
- logging services and all existing `DebugLog` calls.

The app now implements renderer package composition as a separate Cordis domain. File Provider and transport composition remain possible later domains.

## Compatibility

The migration does not change these contracts:

- `ExtractionConfig` JSON;
- Keychain credential storage;
- queue and XPC payloads;
- extraction provenance fields;
- persisted markdown and source data;
- backend display names and readiness behavior.
