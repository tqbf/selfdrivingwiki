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

    /// Unified search + autocomplete. `request` is JSON-encoded
    /// `SearchRPCRequest`; the reply is ALWAYS JSON-encoded `SearchRPCReply`
    /// (failures carry its `error`, never a nil/empty Data). The daemon owns
    /// the per-wiki search runtime and synchronizes it against the store's
    /// change token before serving, so replies include other processes'
    /// committed writes. See `SearchRPCWire`.
    func search(request: Data, reply: @escaping (Data) -> Void)

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

    /// Load the durable attempt report for one queue item. Reply uses the
    /// versioned queue envelope wrapping `QueueDataPayload`, whose data is
    /// JSON-encoded `QueueReportLoadResult` (loaded report / notReported /
    /// unavailable).
    func loadQueueReport(itemID: String, reply: @escaping (Data) -> Void)

    /// Load bounded report summaries for the displayed queue items.
    /// `itemIDs` is JSON-encoded `[String]`; reply uses the versioned queue
    /// envelope wrapping `QueueDataPayload`, whose data is JSON-encoded
    /// `QueueReportSummariesResult`.
    func loadQueueReportSummaries(itemIDs: Data, reply: @escaping (Data) -> Void)

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

    // MARK: - Workload: staged lint proposals (W5b read seam)

    /// Load the staged lint proposals for one page from the daemon's lint
    /// run state. The app's proposal-review section resolves the durable
    /// records' `staged_proposal=<id>` references against these values.
    /// Reply is the versioned queue envelope wrapping `QueueDataPayload`,
    /// whose data is JSON-encoded `[LintStagedProposalRecord]` (empty when
    /// the daemon holds none for the page). Read-only state export — no
    /// socket operation, no child surface.
    func loadLintStagedProposals(pageID: String, reply: @escaping (Data) -> Void)
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

/// One staged lint proposal crossing the daemon→app boundary: the app-side
/// value mirror of the daemon's staged record — exactly the fields the
/// review UI renders and `LintProposalApplyService` consumes. Primitive
/// fields only (the contract target links no store types); ids arrive as
/// their raw strings and each hunk as its own record.
public struct LintStagedProposalRecord: Codable, Hashable, Sendable {
    /// One ranged edit, mirroring the store's hunk shape byte for byte.
    public struct Hunk: Codable, Hashable, Sendable {
        public let startByte: Int
        public let endByte: Int
        public let oldText: String
        public let newText: String
        public let reason: String

        public init(
            startByte: Int, endByte: Int, oldText: String,
            newText: String, reason: String
        ) {
            self.startByte = startByte
            self.endByte = endByte
            self.oldText = oldText
            self.newText = newText
            self.reason = reason
        }
    }

    /// The run configuration identity for breaker accounting: the tier-2
    /// key components the run recorded, so review actions land in the same
    /// breaker window the run used. Absent when the daemon recorded none —
    /// the review actions then stay disabled with their honest reason
    /// rather than guessing a key.
    public struct BreakerKeyComponents: Codable, Hashable, Sendable {
        public let pipelineDigest: String
        public let provider: String
        public let model: String
        public let effort: String

        public init(
            pipelineDigest: String, provider: String, model: String, effort: String
        ) {
            self.pipelineDigest = pipelineDigest
            self.provider = provider
            self.model = model
            self.effort = effort
        }
    }

    /// The proposal's stable reference (the durable records' proposal id).
    public let id: String
    /// The managed run that staged it.
    public let runID: String
    /// The page it targets (raw id).
    public let pageID: String
    /// When the daemon accepted it.
    public let stagedAt: Date
    /// The head the hunks were composed against (the apply-time CAS
    /// expect-head).
    public let inspectedHead: String
    /// The inspected body's fingerprint (diff provenance).
    public let bodyFingerprint: String
    /// The exact ranged edits, in submission order.
    public let hunks: [Hunk]
    /// One defect class per hunk, parallel to `hunks`.
    public let perHunkClasses: [String]
    /// The run's breaker-key components, when recorded.
    public let breakerKey: BreakerKeyComponents?

    public init(
        id: String, runID: String, pageID: String, stagedAt: Date,
        inspectedHead: String, bodyFingerprint: String,
        hunks: [Hunk], perHunkClasses: [String],
        breakerKey: BreakerKeyComponents?
    ) {
        self.id = id
        self.runID = runID
        self.pageID = pageID
        self.stagedAt = stagedAt
        self.inspectedHead = inspectedHead
        self.bodyFingerprint = bodyFingerprint
        self.hunks = hunks
        self.perHunkClasses = perHunkClasses
        self.breakerKey = breakerKey
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
