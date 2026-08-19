# Cordis Daemon Transport Services

**Status:** Implemented

## Purpose

The app uses one private Cordis runtime for daemon transport availability.

The runtime owns connection attempts, health probes, retries, candidate deadlines, handlers, and disposal.

The app still owns queue policy, chat policy, UI state, sessions, stores, and XPC workload objects.

## Public facade

`DaemonTransportServices` is a `Sendable` value in `WikiFSEngine`.

The facade starts admission, sends candidate acknowledgements, requests manual reconnect, supplies typed events, reports availability, and stops the runtime.

The facade does not expose a Cordis context, a service key, an XPC object, a queue client, or a store.

`DaemonTransportCompositionOwner` supplies one stable facade during asynchronous assembly. It owns and awaits the assembly task.

## Service graph

`DaemonTransportRuntimeAssembly` registers these fixed labels:

| Label | Value |
| --- | --- |
| `daemon-transport.connection-factory` | The headless candidate connection factory |
| `daemon-transport.configuration` | Retry, probe, timeout, and acceptance settings |
| `daemon-transport.runtime` | The transport state and lifecycle actor |
| `daemon-transport.services` | The public `DaemonTransportServices` facade |

Each component declares its dependencies. Each activation resolves its dependencies with `ActivationContext.require`.

Cordis controls activation order. Registration order does not control activation order.

## State and events

The runtime has five states:

1. `idle`
2. `retrying`
3. `awaitingAcceptance(candidateID)`
4. `connected(candidateID)`
5. `stopped`

The runtime allocates a new `DaemonTransportCandidateID` before each attempt. The factory registers the concrete app connection under that exact ID.

A successful health probe publishes `awaitingAcceptance`. It does not publish `connected`.

The app validates queue ownership and installs the queue endpoint. The app then sends one acknowledgement for the same candidate ID.

The acknowledgement outcome is `connected`, `retry`, or `localFallbackReady`.

The runtime ignores stale, duplicate, mismatched, and post-stop acknowledgements.

An acceptance deadline invalidates an unaccepted candidate. The runtime then starts retry admission again.

## App bridge and coordinator

`DaemonTransportAppBridge` owns the candidate ID to `WikiDaemonConnection` registry.

The bridge returns only a narrow `DaemonTransportConnection` wrapper to the Engine runtime.

`DaemonTransportAppCoordinator` resolves the concrete connection only for the current candidate ID.

The coordinator preserves the existing queue ownership transaction. It installs a chat coordinator only after queue activation succeeds.

The coordinator contains no Cordis context, activation context, or service key.

`DaemonHealthMonitor` is a presentation adapter. It maps typed events to connected, disconnected, and reconnecting UI state.

## Invalidation and interruption

Invalidation ends one candidate generation. The runtime publishes one disconnect event and starts retry admission.

The app marks the active daemon queue epoch unresolved. It also clears the chat coordinator.

Interruption keeps the same accepted connection. The runtime publishes an interruption event without a disconnect event.

The app registers a new event sink on that same connection. The UI remains connected.

## Shutdown order

App termination uses this order:

1. Stop daemon transport admission and connection work.
2. Dispose the local queue runtime.
3. Release search runtimes.
4. Stop extraction composition.
5. Stop renderer composition.

Repeated transport shutdown and runtime disposal are safe.

The app does not request daemon process termination. macOS still owns the embedded XPC service lifecycle.

## Scope limits

These values stay outside Cordis:

- `WikiDaemonConnection`, `NSXPCConnection`, and XPC wire protocols;
- `DaemonWorkloadClient`, event sinks, and queue proxies;
- `QueueEngineHotSwap` and `LocalQueueRuntimeController`;
- queue ownership epochs and active queue work;
- `ChatDaemonCoordinator` and active chat sessions;
- `WikiStore`, `WikiStoreModel`, `WikiSession`, and `SessionManager`;
- SwiftUI views and `DaemonHealthMonitor` state.

## Compatibility

The migration does not change the daemon XPC protocol or payloads.

It does not change queue ownership epoch rules, chat event delivery rules, or daemon process ownership.

`WikiDaemonConnection.healthCheck` keeps its existing timeout and single-resume safeguards.
