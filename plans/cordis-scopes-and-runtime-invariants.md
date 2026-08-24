# Cordis Scopes and Runtime Invariants

## Status

Implemented for process and wiki scopes on 2026-08-24.

Page, rendering-job, chat, and queue-item scopes remain deferred.

## Scope model

Self Driving Wiki uses the existing Cordis context tree as its scope model.

`ContextID` is the opaque runtime identity. A `ScopeDescriptor` adds typed diagnostic metadata. The descriptor does not replace context identity.

`ContextRecord.parentID` is the only parent relationship. The runtime does not use a second parent registry. It does not support reparenting or descriptor mutation.

Cordis context disposal is the only scope lifetime boundary. Disposal rejects new effects, disposes child contexts, runs cleanup, and supports repeated calls.

The initial hierarchy is:

```text
process → wiki
```

A process descriptor contains a typed `ProcessScopeRole`. A wiki descriptor contains a `WikiID`.

The public `CordisContext.init()` remains available for standalone runtimes and tests. Production app and daemon roots use process descriptors. Production wiki profiles use wiki descriptors before configuration and activation start.

## Identity, visibility, and lifetime

Identity answers which runtime context owns work. Cordis uses `ContextID` for this purpose.

Visibility answers which ancestor services a context can resolve. Cordis uses its existing parent traversal.

Lifetime answers when registrations and effects must stop. Cordis uses context disposal and component cleanup.

These concepts are related, but they are not interchangeable.

Application facades must not expose `CordisContext`. `ProfileLifetime` keeps the booted profile private. Internal diagnostics return immutable Sendable values only.

## Diagnostics snapshots

`ScopeDiagnosticsSnapshot` contains:

- the context ID
- the parent context ID
- the optional descriptor
- the optional parent descriptor
- the lifecycle state
- the active child count
- the active registration count

The Cordis actor creates each snapshot from its owned records. A snapshot does not expose a context, service instance, disposer, or mutable record.

`WikiScopeIdentitySnapshot` compares the scope, profile, session, store, event bus, database, and host identities. The host association is tagged as app or daemon. Only daemon snapshots require a daemon cache key.

## Runtime invariant registry

`InvariantRegistry` reserves one typed owner label for each active invariant installer. It creates one Cordis child context for each selected installer.

Installers use `ComponentDefinition`. They declare typed dependencies through the existing Cordis component contract. Registration waits for component settlement.

A failed installer disposes its child before the registry releases the owner. The returned registration is an idempotent asynchronous disposer. It releases the owner after child disposal finishes.

Registry filter configuration is immutable. Startup rejects blank, padded, duplicate, and invalid patterns. Blocklist matches override allowlist matches.

`InvariantViolation` contains a stable code, owner, message, and optional scope snapshot. The recording sink uses a private lock for deterministic tests. The production sink reports through `DebugLog`.

Invariant reporting does not throw from event listeners. It does not own product state or database connections.

## Initial invariants

### Wiki identity

The identity snapshot compares each available typed `WikiID` with the wiki scope descriptor. Optional subsystems can be absent.

The daemon cache key is required only for daemon-hosted profiles.

### Scope parent and lifecycle

A described wiki context has a described process parent in production trees. Standalone undescribed roots remain compatible with loader tests and custom runtimes.

A reopened wiki receives a new `ContextID`. Disposed snapshots report no active registrations.

### Wiki events

`WikiEventBus` stamps the event sequence under its lock. It calls the diagnostic observer after stamping and before asynchronous subscriber delivery.

The observer reports a wrong event `WikiID` and a non-increasing sequence. It cannot detect an event that was never emitted.

Store mutation completeness remains in `StoreEmissionExhaustivenessTests`. Rollback emission and post-commit visibility remain in deterministic store tests.

### Process ownership

Queue and extraction services remain process-owned. Wiki profiles consume typed facades. They do not provide duplicate process services.

## Renderer object capabilities

Scope controls identity, visibility, and lifetime. A capability controls authority.

Installed renderer packages are untrusted WebKit content. Protocol version 1 permits `input.read`. Optional external-link activation uses a separate trusted host adapter.

`input.read` reads one exact session-authorized pinned input. It returns bytes and a MIME type.

External activation requires normalized HTTPS, a trusted user gesture, a one-shot nonce, and matching session, window, frame, and navigation state.

The package policy keeps `default-src 'none'` and `connect-src 'none'`. Package navigation rejects unsupported schemes, cross-host requests, file URLs, popups, and arbitrary network access.

Native built-in renderers and host adapters are trusted application code. Shared built-in factory inputs do not expose `WikiStoreModel`. The Mermaid path receives a prepared view projection. JSON Canvas receives a closure for the closed `JSONCanvasHostAction` enum.

A new package capability requires a protocol revision, threat analysis, focused authorization tests, and a product decision.

## Deferred scope gates

### Page and rendering job

Adopt a child context only after both conditions are true:

1. Identify a concrete registration, listener, callback, or reversible effect with page or render-job lifetime.
2. Add a failing isolation or teardown test for the current lifetime behavior.

The renderer admission state machine remains authoritative until this evidence exists.

### Chat

Adopt a child context only after both conditions are true:

1. Identify a chat-owned listener, permission callback, or reversible effect.
2. Add a failing stale-registration test that generation and epoch checks cannot reject.

`ChatSessionMachine` and `ChatAgentRuntime` remain authoritative until this evidence exists.

### Queue item and convergence

Queue ownership remains process-wide. `QueueAttemptID` and output-channel admission remain the stale-output authority.

Do not add a queue-item scope without a concrete registration lifetime. Defer convergence diagnostics until production invariant data shows a useful signal and an acceptable false-positive rate.

## Upstream references

This design adapts the public DeepSeek Harness scope and runtime invariant work:

- `deepseek-harness/packages/core/scope/src/index.ts`
- the tests for `packages/core/scope`
- `deepseek-harness/packages/runtime-diagnostics/invariants/src/index.ts`
- the tests for `packages/runtime-diagnostics/invariants`

The upstream design adds identity and ancestry around Cordis. The Swift Cordis runtime already owns identity, ancestry, lookup, and disposal. This implementation adds immutable metadata and diagnostics to that existing tree instead of adding another hierarchy.
