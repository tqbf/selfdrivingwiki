# Cordis Agent Provider Composition

**Status:** Implemented

## Purpose

Cordis is the process-level composition boundary for agent provider services.

The app and daemon each own one provider runtime. Each runtime exposes one stable `AgentProviderServices` facade.

This boundary covers interactive chat, ingestion, lint, queue readiness, and model summaries.

## Scope boundaries

The process scope owns these services:

- authoritative provider configuration reads;
- operation policy resolution;
- PATH and credential resolution;
- private provider spawn records;
- backend construction and reuse by operation snapshot and provider ID.

The queue runtime remains a child composition boundary. `QueueRuntimeAssembly` still owns queue stores, providers, factories, output, and engine lifecycle.

Each `AgentLauncher` remains a per-wiki `@MainActor` client. Cordis does not own launchers or active agent sessions.

Each operation owns its subprocess and session state outside Cordis. Existing launcher and daemon owners keep cancellation, streaming, permission, and teardown control.

## Dependency direction

`WikiFS` can inject app objects into headless adapters. `WikiFSEngine` does not import SwiftUI or app model types.

Cordis stores only headless `Sendable` services. Public handles do not expose `CordisContext`.

Views, environment values, XPC objects, and persistence connections cannot access the Cordis context.

## Operation snapshots

The provider service reads current configuration once when an operation starts.

The snapshot freezes these values:

- the operation kind and policy;
- the selected provider and model;
- each ingest stage model;
- each ingest stage provider chain;
- private spawn records for every eligible provider.

A later settings change affects the next operation. It does not change an active operation.

Fallback uses the frozen provider chain. It does not reload provider settings.

Backend identity is the operation snapshot plus provider ID. Stages reuse one backend when the provider ID does not change.

## Secret boundary

Public descriptors contain only a typed provider ID and display label.

Public preparations do not contain commands, arguments, environment values, credentials, paths, prompts, or source content.

The runtime stores private spawn records in process memory. Only `WikiFSEngine` can use those records to create a backend profile.

Model summary owners send text through the public service. They do not receive a backend profile or secret hints.

Diagnostics can include provider IDs and operation kinds. Diagnostics cannot include commands, credentials, environment values, prompts, or source content.

## Process composition

`WikiFSApp` creates one stable `MutableAgentProviderServices` facade. It installs the assembled runtime service after startup.

The app injects the same facade into these clients:

- the settings launcher;
- every `WikiSession` launcher;
- `AppQueueIngestionProvider`.

`WikiDaemon` creates the same stable facade pattern. It injects the facade into these clients:

- `DaemonQueueIngestionProvider`;
- `DaemonChatHost`;
- `LauncherChatAgentRuntime`;
- every daemon-created launcher.

If assembly fails, the facade stays unavailable. Non-agent app and daemon features remain available.

## Lifecycle

The app and daemon retain their runtime handle for the process lifetime.

The queue owner must stop or hand off queue work before provider runtime disposal.

Chat owners must stop admission and close active sessions before provider runtime disposal.

The runtime handle disposes its Cordis context idempotently. Disposal invalidates all outstanding operation tokens.

## Preserved behavior

Interactive chat keeps the 1,800-second turn ceiling and no deferred-permission budget.

Ingestion and lint keep the 600-second turn ceiling and the 60-second deferred-permission budget.

Quota fallback keeps provider cooldown, fork reconciliation, isolated fallback scratch directories, and backend cleanup.

The queue ownership controller, output leases, handoff rules, and daemon ownership epochs do not change.

## Remaining migrations

Daemon cold starts now use one process-local prepared start value. The provider runtime resolves provider, model, thinking, policy, credentials, and backend state from one configuration snapshot.

The controller uses the redacted request from that preparation for durable claim attribution. The launcher consumes the matching opaque preparation without a second provider configuration read.

`ChatRuntimeStartRequest` keeps its Codable wire shape. Process-local tokens remain outside JSON, XPC, and persistence.

Extraction backend registration and renderer lifetimes remain separate Cordis migrations.

Cordis still excludes dynamic loaders, provider plugins, an event bus, hot module replacement, and SwiftUI service lookup.
