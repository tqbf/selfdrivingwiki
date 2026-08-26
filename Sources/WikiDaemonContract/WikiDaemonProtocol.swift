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

    /// Run the opt-in signed extractor process-boundary probe.
    /// The daemon uses only its bundled reviewed fixture and App Group files.
    /// Request and reply values use the versioned JSON envelopes below.
    func runSignedExtractorProbe(request: Data, reply: @escaping (Data) -> Void)

    // MARK: - Workload: event sink registration (Phase 0)

    /// Tell the daemon which object to push live workload events to. The app
    /// calls this once after connecting, passing its `WikiDaemonEventSink`
    /// conformer. The daemon captures a weak reference and pushes JSON-encoded
    /// `QueueEvent` envelopes / chat `AgentEvent` batches via `deliverEvent`.
    ///
    /// See `plans/daemon-workloads.md` §3 + §5.2.
    func registerEventSink(_ sink: WikiDaemonEventSink)

    // MARK: - Workload: queue engine (Phase A+B)

    /// Full snapshot of all queue items (JSON-encoded `QueueSnapshot`). The app
    /// calls this on launch to rehydrate the Activity window / menu-bar state
    /// after a reconnect. In Phase 0 the daemon serves an empty snapshot (the
    /// engine is constructed but not wired to real workers).
    func queueSnapshot(reply: @escaping (Data) -> Void)

    /// Enqueue a queue item. `request` is JSON-encoded `QueueItemRequest`;
    /// reply is JSON `{"id": "<itemID>", "error": null}`.
    func enqueueItem(request: Data, reply: @escaping (Data) -> Void)

    /// Cancel a specific item. Reply uses the versioned queue envelope.
    func cancelItem(id: String, reply: @escaping (Data) -> Void)

    /// Cancel all in-flight items. Reply uses the versioned queue envelope.
    func cancelAllInFlight(reply: @escaping (Data) -> Void)

    /// Retry a failed item. Reply is JSON `{"error": null}`.
    func retryItem(id: String, reply: @escaping (Data) -> Void)

    /// Pause a queue. Reply uses the versioned queue envelope.
    func pauseQueue(queue: String, reply: @escaping (Data) -> Void)

    /// Resume a queue. Reply uses the versioned queue envelope.
    func resumeQueue(queue: String, reply: @escaping (Data) -> Void)

    /// Halt a queue. Reply uses the versioned queue envelope.
    func haltQueue(queue: String, reply: @escaping (Data) -> Void)

    /// Reorder an item. Reply uses the versioned queue envelope.
    func reorderItem(id: String, beforeItemID: String?, reply: @escaping (Data) -> Void)

    /// Check if a wiki has active work. Reply uses the versioned queue envelope.
    func hasActiveWork(wikiID: String, reply: @escaping (Data) -> Void)

    /// Await completion of an item. Reply is JSON `{"success": true}` or
    /// `{"success": false, "error": "..."}`.
    func waitForCompletion(id: String, reply: @escaping (Data) -> Void)

    /// Load transcript items for an item. Reply is JSON-encoded `[ChatTranscriptItem]`.
    func loadTranscript(itemID: String, reply: @escaping (Data) -> Void)

    /// Load all activity snapshots through the versioned queue envelope.
    func loadAllActivitySnapshots(reply: @escaping (Data) -> Void)

    /// Return the daemon queue ownership epoch and host state.
    /// Reply uses the versioned queue envelope.
    func queueOwnershipStatus(reply: @escaping (Data) -> Void)

    /// Permanently relinquish queue ownership for the expected epoch.
    /// Request and reply use versioned queue wire values.
    func relinquishQueue(request: Data, reply: @escaping (Data) -> Void)

    // MARK: - Workload: chat (Phase C)

    /// Start a new chat. `request` is JSON-encoded `ChatStartRequest`;
    /// reply is JSON `ChatStartReply` (`{"chatID": "<ulid>", "error": null}`).
    func startChat(request: Data, reply: @escaping (Data) -> Void)

    /// Submit one typed chat turn. `request` is JSON-encoded
    /// `ChatSubmitRequest`; reply is JSON `ChatSubmitReply`.
    func submitChatTurn(request: Data, reply: @escaping (Data) -> Void)

    /// Continue a persisted chat with a new user turn.
    /// `request` is JSON `ChatContinueRequest`; reply `{"error": null}`.
    func continueChat(request: Data, reply: @escaping (Data) -> Void)

    /// Send a follow-up turn to the active chat session.
    /// `request` is JSON `{"chatID": "...", "message": "..."}`; reply `{"error": null}`.
    func sendChatMessage(request: Data, reply: @escaping (Data) -> Void)

    /// Cancel/stop the active turn (or end the session). The encoded request
    /// carries both wiki and chat identity.
    func stopChat(request: Data, reply: @escaping () -> Void)

    /// Rehydrate a chat's authoritative sync state after (re)connect. The
    /// encoded request carries both wiki and chat identity. Reply is
    /// JSON-encoded `ChatSyncSnapshotEnvelope` data.
    func chatSessionState(request: Data, reply: @escaping (Data) -> Void)

    /// Returns a versioned, redacted diagnostic snapshot. Both request and
    /// reply are JSON `Data`; protocol versions are validated by the daemon.
    func chatDiagnosticSnapshot(request: Data, reply: @escaping (Data) -> Void)

    /// Acknowledges a successfully delivered diagnostic export so `wikid` can
    /// rotate its identity, fingerprint key, and bounded ring.
    func resetChatDiagnostics(request: Data, reply: @escaping (Data) -> Void)

    /// Resolve a pending permission request for a chat (approve/reject).
    /// `request` is JSON `ChatPermissionResolveRequest`.
    func resolveChatPermission(request: Data, reply: @escaping () -> Void)

    /// Set a config option (e.g. thinking effort) on the live chat session
    /// without restarting it. `request` is JSON `ChatConfigOptionRequest`;
    /// reply is JSON `{"error": null}`.
    func setChatConfigOption(request: Data, reply: @escaping (Data) -> Void)
}

public struct SignedWikiDExtractorProbeRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: String

    public init(version: Int = Self.currentVersion, requestID: String) {
        self.version = version
        self.requestID = requestID
    }
}

public struct SignedWikiDExtractorProbeReply: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: String
    public let reviewedPackageResolved: Bool
    public let operationDirectoryIsPrivate: Bool
    public let protocolExchangeSucceeded: Bool
    public let processGroupTerminated: Bool
    public let fixtureChildTerminated: Bool
    public let diagnostics: [String]

    public init(
        version: Int = Self.currentVersion,
        requestID: String,
        reviewedPackageResolved: Bool,
        operationDirectoryIsPrivate: Bool,
        protocolExchangeSucceeded: Bool,
        processGroupTerminated: Bool,
        fixtureChildTerminated: Bool,
        diagnostics: [String] = []
    ) {
        self.version = version
        self.requestID = requestID
        self.reviewedPackageResolved = reviewedPackageResolved
        self.operationDirectoryIsPrivate = operationDirectoryIsPrivate
        self.protocolExchangeSucceeded = protocolExchangeSucceeded
        self.processGroupTerminated = processGroupTerminated
        self.fixtureChildTerminated = fixtureChildTerminated
        self.diagnostics = diagnostics
    }

    public var passed: Bool {
        version == Self.currentVersion
            && reviewedPackageResolved
            && operationDirectoryIsPrivate
            && protocolExchangeSucceeded
            && processGroupTerminated
            && fixtureChildTerminated
            && diagnostics.isEmpty
    }
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
