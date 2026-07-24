#if os(macOS)
// WikiDaemonContract — the single, explicit app↔daemon XPC boundary.
//
// This module is the one place that defines the wire contract between the
// `wikid` XPC service (server) and its clients (the `WikiFS` app + `wikictl`,
// via the typed proxies in `WikiCtlCore`). It holds exactly three things:
//
//   • `WikiDaemonProtocol`   — the @objc request/reply interface (server-side
//                              implementation in `wikid`; client proxy in
//                              `WikiCtlCore.WikiDaemonConnection`).
//   • `WikiDaemonEventSink`  — the @objc reverse channel the daemon uses to push
//                              live events back to the app (implemented by the
//                              app's `DaemonQueueEventSink`).
//   • `WikiDaemonError`      — the shared transport error vocabulary.
//
// **Why there are no DTO types here.** Every payload crosses the wire JSON-
// encoded as `Data` (NSXPC's @objc protocols can't carry arbitrary `Codable`
// types). The protocol signatures therefore reference only
// `Data`/`String`/`Bool`/`Int` — no domain types — which is what lets this
// module stay a Foundation-only leaf with zero domain coupling. The payload
// DTOs (`WikiDescriptor`, `QueueItemRequest`, `AgentEvent`, `ChatStartRequest`,
// `QueueSnapshot`, `QueueEventEnvelope`, …) remain domain types in `WikiFSCore`
// / `WikiFSEngine`; the typed client/server wrappers encode and decode them.
//
// macOS-only: NSXPC + `@objc` are unavailable on Linux, so all source here is
// guarded with `#if os(macOS)` and the module is empty on Linux.
#endif
