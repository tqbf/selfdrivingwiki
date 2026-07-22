#if os(macOS)
import Foundation

/// The XPC contract between the `wikid` daemon and its clients (`wikictl`, the app
/// in Phase 2).
///
/// Uses `@objc` + `@escaping` reply closures (standard macOS XPC). Swift
/// `Codable` types that are not `NSSecureCoding` (e.g. `WikiDescriptor`) are
/// serialized to JSON `Data` (which bridges to `NSData`) and deserialized by the
/// client via `JSONDecoder`.
///
/// See `plans/multi-wiki-daemon.md` §4.1.
@objc public protocol WikiDaemonProtocol {
    // MARK: - Registry

    /// List all wikis, MRU-ordered. Returns JSON-encoded `[WikiDescriptor]`.
    func listWikis(reply: @escaping (Data) -> Void)

    /// Create a new wiki. Returns JSON-encoded `WikiDescriptor` on success,
    /// or `nil` on failure.
    func createWiki(name: String, reply: @escaping (Data?) -> Void)

    /// Delete a wiki (removes registry entry + DB files). Returns true on success.
    func deleteWiki(id: String, reply: @escaping (Bool) -> Void)

    /// Rename a wiki (display name only; identity/DB untouched).
    func renameWiki(id: String, name: String, reply: @escaping (Bool) -> Void)

    /// Resolve a selector (ULID id or display name) to a `WikiDescriptor`.
    /// Returns JSON-encoded `WikiDescriptor`, or `nil` if not found.
    func resolveWiki(selector: String, reply: @escaping (Data?) -> Void)

    // MARK: - Store lifecycle

    /// Open (or confirm open) the store for a wiki. The daemon holds a
    /// `GRDBWikiStore` instance alive for this wiki. Returns true on success.
    /// Does NOT grant the client write access — the client still opens its own
    /// store for writes (sole-writer is deferred to Phase 2+).
    func openStore(wikiID: String, reply: @escaping (Bool) -> Void)

    /// Close the daemon's held-open store for a wiki (if no other client holds
    /// a session). Best-effort; the daemon may keep it open for idle-eviction logic.
    func closeStore(wikiID: String, reply: @escaping () -> Void)

    /// The current changeToken for a wiki (per #129 event bus design).
    /// Returns an empty string if the store is not open or the token is unavailable.
    func changeToken(wikiID: String, reply: @escaping (String) -> Void)

    // MARK: - Workload: event sink registration (Phase 0)

    /// Tell the daemon which object to push live workload events to. The app
    /// calls this once after connecting, passing its `WikiDaemonEventSink`
    /// conformer. The daemon captures a weak reference and pushes JSON-encoded
    /// `QueueEvent` envelopes / chat `AgentEvent` batches via `deliverEvent`.
    ///
    /// See `plans/daemon-workloads.md` §3 + §5.2.
    func registerEventSink(_ sink: WikiDaemonEventSink)

    // MARK: - Workload: queue engine (Phase 0 — scaffold)

    /// Full snapshot of all queue items (JSON-encoded `QueueSnapshot`). The app
    /// calls this on launch to rehydrate the Activity window / menu-bar state
    /// after a reconnect. In Phase 0 the daemon serves an empty snapshot (the
    /// engine is constructed but not wired to real workers).
    func queueSnapshot(reply: @escaping (Data) -> Void)
}

/// The reverse-channel protocol the app implements so the daemon can push
/// fine-grained *live* workload events (queue `QueueEvent`s, chat
/// `AgentEvent`s, pending permissions). The app sets itself as the XPC
/// connection's `exportedObject`; the daemon holds a proxy and calls
/// `deliverEvent` with JSON-encoded payloads.
///
/// This is the standard bidirectional-`NSXPCConnection` pattern: one
/// connection carries request/reply (the daemon's `WikiDaemonProtocol`) AND
/// callbacks (the app's `WikiDaemonEventSink`).
///
/// See `plans/daemon-workloads.md` §3 + §5.2.
@objc public protocol WikiDaemonEventSink: AnyObject {
    /// One streamed workload event, JSON-encoded. The daemon encodes a
    /// `QueueEventEnvelope` (`{itemID, kind, payload}`) or an `AgentEvent`
    /// batch; the app decodes and forwards into its existing
    /// `QueueEventBroadcaster` / launcher `events` array.
    func deliverEvent(_ payload: Data)
}
#endif
