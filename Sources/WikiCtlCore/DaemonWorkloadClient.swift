#if os(macOS)
import Foundation
import WikiFSCore
import WikiDaemonContract
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif
/// Errors from daemon XPC workload calls.
public enum DaemonXPCError: Error, LocalizedError {
    case timeout
    case failure(String)
    case unexpectedReply
    case chatWire(ChatSyncWireError)
    case diagnosticDecode
    case diagnosticVersion(ChatDiagnosticVersionError)

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Daemon XPC call timed out"
        case .failure(let msg):
            return msg
        case .unexpectedReply:
            return "Unexpected reply from daemon"
        case .chatWire(let error):
            return error.localizedDescription
        case .diagnosticDecode:
            return "Daemon diagnostic snapshot could not be decoded"
        case .diagnosticVersion(let error):
            return "Daemon diagnostic snapshot version failure: \(error)"
        }
    }
}

/// Resume-once carrier for one daemon XPC reply (#1428).
///
/// The XPC reply callback fulfils the box; a timeout or a task cancellation
/// releases it with a failure. Whichever happens first wins, exactly one
/// continuation resume ever occurs (a straggling reply is discarded instead
/// of double-resuming, which traps), and the waiting task always finishes —
/// so the ``DaemonWorkloadClient/withTimeout`` task group can actually return
/// its timeout instead of suspending forever on an abandoned continuation.
///
/// This is the production sibling of the resume-once box
/// `WikiDaemonConnection` has used for its health check since #884; see the
/// comment above `WikiDaemonConnection.healthCheck` for why a plain
/// task-group race without this box cannot work.
// NSLock protects the only mutable field and each continuation resumes at most once.
// swiftlint:disable:next unchecked_sendable
private final class DaemonXPCReplyBox<Value: Sendable>: @unchecked Sendable {

    private enum Payload {
        case idle
        case waiting(CheckedContinuation<Value, Error>)
        case settled(Result<Value, Error>)
    }

    private let lock = NSLock()
    private var payload: Payload = .idle

    /// Deliver the XPC reply. A no-op if the box was already settled by a
    /// timeout or cancellation.
    func fulfill(_ value: Value) {
        settle(.success(value))
    }

    /// Release a pending (or future) waiter with a failure.
    private func fail(_ error: Error) {
        settle(.failure(error))
    }

    private func settle(_ result: Result<Value, Error>) {
        lock.lock()
        switch payload {
        case .idle:
            // No waiter yet — the reply raced ahead of the wait, or
            // cancellation fired before the wait installed its continuation.
            // Remember the outcome for the wait that follows.
            payload = .settled(result)
            lock.unlock()
        case .waiting(let continuation):
            payload = .idle
            lock.unlock()
            continuation.resume(with: result)
        case .settled:
            // Resume-once: a late reply after timeout/cancellation is
            // discarded rather than resumed twice (which traps).
            lock.unlock()
        }
    }

    /// Wait for the reply. Cancellation-aware: when the surrounding task is
    /// cancelled while waiting (the `withTimeout` timer won), the box is
    /// released with `CancellationError` and this call throws immediately,
    /// letting the task group finish instead of parking on a continuation
    /// that XPC will never answer.
    func wait() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                lock.lock()
                switch payload {
                case .idle:
                    payload = .waiting(continuation)
                    lock.unlock()
                case .settled(let result):
                    // Already settled before the waiter arrived.
                    lock.unlock()
                    continuation.resume(with: result)
                case .waiting:
                    // One box serves exactly one reply and one waiter; this
                    // is a caller bug. Fail the newcomer rather than risk a
                    // lost or double resume.
                    lock.unlock()
                    continuation.resume(throwing: DaemonXPCError.unexpectedReply)
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }
}

/// Async wrappers over the daemon's workload XPC methods. Sibling to
/// ``WikiDaemonConnection`` (registry + store lifecycle) — this client wraps
/// the workload methods (`queueSnapshot`, `registerEventSink`, `enqueue`,
/// `extractSource`, `startChat`, …).
///
/// The app uses this instead of calling the daemon's `@objc` protocol
/// directly so callers get typed Swift returns (`QueueSnapshot`, not raw
/// `Data`) and `async throws` instead of reply-closure dances.
///
/// See `plans/daemon-workloads.md` Phase 0 §5.
public final class DaemonWorkloadClient: @unchecked Sendable {

    /// Production bound for one daemon XPC round trip. Every workload call
    /// waits at most this long for its reply — see ``withTimeout``.
    public static let defaultTimeout: TimeInterval = 30

    private let proxy: WikiDaemonProtocol
    private let xpcTimeout: TimeInterval

    /// Create a workload client from an existing daemon connection (shares the
    /// same `NSXPCConnection` — no second connection). Throws if the connection
    /// can't vend a valid daemon proxy (e.g. it was already invalidated).
    ///
    /// - Parameter xpcTimeout: per-call reply bound in seconds. Tests inject a
    ///   short value so fault-injection scenarios stay bounded; production
    ///   callers use the ``defaultTimeout`` default.
    public init(
        connection: WikiDaemonConnection,
        xpcTimeout: TimeInterval = DaemonWorkloadClient.defaultTimeout
    ) throws {
        self.proxy = try connection.daemonProxy()
        self.xpcTimeout = xpcTimeout
    }

    init(
        proxy: WikiDaemonProtocol,
        xpcTimeout: TimeInterval = DaemonWorkloadClient.defaultTimeout
    ) {
        self.proxy = proxy
        self.xpcTimeout = xpcTimeout
    }

    // MARK: - Timeout helper

    private func withTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = xpcTimeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DaemonXPCError.timeout
            }
            guard let result = try await group.next() else {
                throw DaemonXPCError.unexpectedReply
            }
            group.cancelAll()
            return result
        }
    }

    /// Send one XPC request and await its reply through the resume-once box.
    ///
    /// `send` registers the request with the daemon and receives the reply
    /// closure to invoke with the response data. The reply may never come (a
    /// wedged or dead daemon) — the caller's timeout or cancellation releases
    /// the wait, and a reply straggling in afterwards is discarded.
    private func xpcReply<Value: Sendable>(
        _ send: @escaping @Sendable (_ reply: @escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        let box = DaemonXPCReplyBox<Value>()
        send { box.fulfill($0) }
        return try await box.wait()
    }

    /// Void-reply variant of ``xpcReply`` for the daemon methods whose XPC
    /// reply closure carries no payload (`stopChat`, `resolveChatPermission`).
    private func xpcVoidReply(
        _ send: @escaping @Sendable (_ reply: @escaping @Sendable () -> Void) -> Void
    ) async throws {
        let box = DaemonXPCReplyBox<Void>()
        send { box.fulfill(()) }
        try await box.wait()
    }

    // MARK: - Queue envelope

    private func decodeQueueEnvelope<Payload: Codable & Sendable>(
        _ payloadType: Payload.Type,
        from data: Data
    ) throws -> (envelope: QueueRPCEnvelope<Payload>, payload: Payload) {
        do {
            let envelope = try QueueRPCWire.decode(payloadType, from: data)
            return (envelope, try envelope.requirePayload())
        } catch let error as QueueRPCError {
            throw error
        } catch {
            throw DaemonXPCError.unexpectedReply
        }
    }

    private func decodeQueuePayload<Payload: Codable & Sendable>(
        _ payloadType: Payload.Type,
        from data: Data
    ) throws -> Payload {
        try decodeQueueEnvelope(payloadType, from: data).payload
    }

    // MARK: - Queue snapshot

    /// Fetch the daemon's queue snapshot (JSON-encoded `QueueSnapshot`).
    /// The app calls this on launch to rehydrate the Activity window after a
    /// reconnect. In Phase 0 the daemon serves an empty snapshot (the stub
    /// factory produces no workers).
    public func queueSnapshot() async throws -> QueueSnapshot {
        let data = try await withTimeout {
            try await self.xpcReply { reply in
                self.proxy.queueSnapshot { reply($0) }
            }
        }
        let payload = try decodeQueuePayload(QueueDataPayload.self, from: data)
        do {
            return try JSONDecoder().decode(QueueSnapshot.self, from: payload.data)
        } catch {
            throw DaemonXPCError.unexpectedReply
        }
    }

    // MARK: - Event sink registration

    /// Register an event-sink with the daemon. The daemon captures the proxy
    /// and pushes live workload events to it via `deliverEvent(_:)`. The app
    /// calls this once after connecting.
    public func registerEventSink(_ sink: WikiDaemonEventSink) {
        proxy.registerEventSink(sink)
    }

    // MARK: - Enqueue / Cancel / Retry

    /// Enqueue a queue item. Returns the assigned item ID.
    @discardableResult
    public func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        let requestData = try JSONEncoder().encode(request)
        return try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.enqueueItem(request: requestData) { reply($0) }
            }
            let payload = try self.decodeQueuePayload(QueueItemIDPayload.self, from: replyData)
            return QueueItemID(rawValue: payload.itemID)
        }
    }

    /// Cancel a specific queued or running item.
    public func cancelItem(_ id: QueueItem.ID) async throws {
        try await withTimeout {
            let data = try await self.xpcReply { reply in
                self.proxy.cancelItem(id: id.rawValue) { reply($0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Cancel all in-flight items. Returns the count cancelled.
    public func cancelAllInFlight() async throws -> Int {
        try await withTimeout {
            let data = try await self.xpcReply { reply in
                self.proxy.cancelAllInFlight { reply($0) }
            }
            return try self.decodeQueuePayload(QueueCountPayload.self, from: data).count
        }
    }

    /// Retry a failed item.
    public func retryItem(_ id: QueueItem.ID) async throws {
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.retryItem(id: id.rawValue) { reply($0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: replyData)
        }
    }

    // MARK: - Pause / Resume / Halt / Reorder

    /// Pause a queue (stop dispatching new items).
    public func pause(_ queue: QueueKind) async throws {
        try await withTimeout {
            let data = try await self.xpcReply { reply in
                self.proxy.pauseQueue(queue: queue.rawValue) { reply($0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Resume a queue (restart dispatch).
    public func resume(_ queue: QueueKind) async throws {
        try await withTimeout {
            let data = try await self.xpcReply { reply in
                self.proxy.resumeQueue(queue: queue.rawValue) { reply($0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Halt a queue (pause + cancel all in-flight items for this queue kind).
    public func halt(_ queue: QueueKind) async throws {
        try await withTimeout {
            let data = try await self.xpcReply { reply in
                self.proxy.haltQueue(queue: queue.rawValue) { reply($0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Reorder a queued item (move before `beforeItemID`, or end if nil).
    public func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {
        try await withTimeout {
            let data = try await self.xpcReply { reply in
                self.proxy.reorderItem(id: id.rawValue, beforeItemID: beforeItemID?.rawValue) {
                    reply($0)
                }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    // MARK: - Status

    /// Whether the daemon has queued or running items for the given wiki.
    public func hasActiveWork(for wikiID: WikiID) async throws -> Bool {
        try await withTimeout {
            let data = try await self.xpcReply { reply in
                self.proxy.hasActiveWork(wikiID: wikiID.rawValue) { reply($0) }
            }
            return try self.decodeQueuePayload(QueueBoolPayload.self, from: data).value
        }
    }

    // MARK: - Await / Transcript / Activity

    /// Await the completion of a specific item. Envelope and transport failures
    /// throw. The returned payload preserves the queue item's domain result.
    public func waitForCompletion(of id: QueueItem.ID) async throws -> QueueCompletionPayload {
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.waitForCompletion(id: id.rawValue) { reply($0) }
            }
            return try self.decodeQueuePayload(QueueCompletionPayload.self, from: replyData)
        }
    }

    /// Load persisted typed transcript items for a queue item.
    public func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] {
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.loadTranscript(itemID: itemID.rawValue) { reply($0) }
            }
            let payload = try self.decodeQueuePayload(QueueDataPayload.self, from: replyData)
            do {
                return try JSONDecoder().decode([ChatTranscriptItem].self, from: payload.data)
            } catch {
                throw DaemonXPCError.unexpectedReply
            }
        }
    }

    /// Load all persisted activity snapshots for rehydration.
    public func loadAllActivitySnapshots() async throws -> [String: QueueEngine.ActivitySnapshotData] {
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.loadAllActivitySnapshots { reply($0) }
            }
            let payload = try self.decodeQueuePayload(QueueDataPayload.self, from: replyData)
            do {
                return try JSONDecoder().decode(
                    [String: QueueEngine.ActivitySnapshotData].self,
                    from: payload.data)
            } catch {
                throw DaemonXPCError.unexpectedReply
            }
        }
    }

    // MARK: - Durable attempt reports

    /// Load the durable attempt report for one queue item. The daemon
    /// answers with a JSON-encoded `QueueReportLoadResult` so missing
    /// reports and capability failures both arrive as typed values.
    public func loadQueueReport(for itemID: QueueItem.ID) async throws -> QueueReportLoadResult {
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.loadQueueReport(itemID: itemID.rawValue) { reply($0) }
            }
            let payload = try self.decodeQueuePayload(QueueDataPayload.self, from: replyData)
            do {
                return try JSONDecoder().decode(QueueReportLoadResult.self, from: payload.data)
            } catch {
                throw DaemonXPCError.unexpectedReply
            }
        }
    }

    /// Load bounded report summaries for the displayed queue items. The
    /// daemon answers with a JSON-encoded `QueueReportSummariesResult`.
    public func loadQueueReportSummaries(
        for itemIDs: [QueueItem.ID]
    ) async throws -> QueueReportSummariesResult {
        let requestData = try JSONEncoder().encode(itemIDs.map(\.rawValue))
        return try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.loadQueueReportSummaries(itemIDs: requestData) { reply($0) }
            }
            let payload = try self.decodeQueuePayload(QueueDataPayload.self, from: replyData)
            do {
                return try JSONDecoder().decode(QueueReportSummariesResult.self, from: payload.data)
            } catch {
                throw DaemonXPCError.unexpectedReply
            }
        }
    }

    /// Read the daemon queue ownership epoch without constructing queue resources.
    public func queueOwnershipStatus() async throws -> QueueOwnershipStatusPayload {
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.queueOwnershipStatus { reply($0) }
            }
            let decoded = try self.decodeQueueEnvelope(
                QueueOwnershipStatusPayload.self,
                from: replyData)
            guard decoded.envelope.ownershipEpoch == decoded.payload.epoch,
                  decoded.envelope.hostState == decoded.payload.hostState else {
                throw QueueRPCError(
                    code: .invalidEnvelope,
                    message: "Queue ownership status metadata did not match its payload")
            }
            return decoded.payload
        }
    }

    /// Ask the daemon to permanently relinquish queue ownership.
    public func relinquishQueue(
        expectedEpoch: QueueOwnershipEpoch
    ) async throws -> QueueRelinquishmentSuccess {
        let request = try QueueRPCWire.encode(
            QueueRPCEnvelope<QueueRelinquishmentRequest>.success(
                QueueRelinquishmentRequest(expectedEpoch: expectedEpoch),
                epoch: expectedEpoch,
                hostState: .serving))
        return try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.relinquishQueue(request: request) { reply($0) }
            }
            let success = try self.decodeQueuePayload(
                QueueRelinquishmentSuccess.self,
                from: replyData)
            guard success.completedEpoch == expectedEpoch, success.isComplete else {
                throw QueueRPCError(
                    code: .ownershipTransition,
                    message: "Daemon relinquishment reply was stale or incomplete")
            }
            return success
        }
    }

    // MARK: - Chat (Phase C)

    #if canImport(WikiFSEngine)

    /// Start a new chat on the daemon. Returns the assigned chat ULID.
    @discardableResult
    public func startChat(_ request: ChatStartRequest) async throws -> ChatID {
        let requestData = try JSONEncoder().encode(request)
        return try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.startChat(request: requestData) { reply($0) }
            }
            guard let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
                throw DaemonXPCError.unexpectedReply
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
            guard let chatID = dict["chatID"] as? String else {
                throw DaemonXPCError.unexpectedReply
            }
            return ChatID(rawValue: chatID)
        }
    }

    /// Submit one typed chat turn. The daemon creates a chat when
    /// `request.chatID == nil`, otherwise it decides how to route the turn for
    /// the existing chat.
    @discardableResult
    public func submitChatTurn(_ request: ChatSubmitRequest) async throws -> ChatID {
        let requestData = try JSONEncoder().encode(request)
        return try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.submitChatTurn(request: requestData) { reply($0) }
            }
            guard let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
                throw DaemonXPCError.unexpectedReply
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
            guard let chatID = dict["chatID"] as? String else {
                throw DaemonXPCError.unexpectedReply
            }
            return ChatID(rawValue: chatID)
        }
    }

    /// Continue a persisted chat with a new user turn.
    public func continueChat(_ request: ChatContinueRequest) async throws {
        let requestData = try JSONEncoder().encode(request)
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.continueChat(request: requestData) { reply($0) }
            }
            if let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
               let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
        }
    }

    /// Send a follow-up turn to an active chat session.
    public func sendChatMessage(wikiID: WikiID, chatID: ChatID, message: String) async throws {
        let requestData = try JSONEncoder().encode(
            ChatMessageRequest(wikiID: wikiID, chatID: chatID, message: message))
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.sendChatMessage(request: requestData) { reply($0) }
            }
            if let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
               let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
        }
    }

    /// Stop/cancel the active chat turn.
    public func stopChat(wikiID: WikiID, chatID: ChatID) async throws {
        let requestData = try JSONEncoder().encode(ChatStopRequest(wikiID: wikiID, chatID: chatID))
        try await withTimeout {
            try await self.xpcVoidReply { reply in
                self.proxy.stopChat(request: requestData) { reply() }
            }
        }
    }

    /// Rehydrate a chat's live state after (re)connect.
    public func chatSessionState(wikiID: WikiID, chatID: ChatID) async throws -> ChatSyncSnapshot {
        let requestData = try JSONEncoder().encode(ChatSessionStateRequest(wikiID: wikiID, chatID: chatID))
        return try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.chatSessionState(request: requestData) { reply($0) }
            }
            do {
                return try ChatSyncSnapshotEnvelope.decodeData(replyData)
            } catch let error as ChatSyncWireError {
                throw DaemonXPCError.chatWire(error)
            } catch {
                throw DaemonXPCError.unexpectedReply
            }
        }
    }

    /// Request a redacted daemon trace. The request is bounded by the same XPC
    /// timeout as every app-side workload request and validates both envelope
    /// versions after decoding.
    public func chatDiagnosticSnapshot(
        _ request: ChatDiagnosticSnapshotRequest
    ) async throws -> ChatDiagnosticSnapshotEnvelope {
        let requestData = try JSONEncoder().encode(request)
        return try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.chatDiagnosticSnapshot(request: requestData) { reply($0) }
            }
            let snapshot: ChatDiagnosticSnapshotEnvelope
            do {
                snapshot = try JSONDecoder().decode(ChatDiagnosticSnapshotEnvelope.self, from: replyData)
            } catch {
                throw DaemonXPCError.diagnosticDecode
            }
            do {
                try snapshot.validatingVersion()
            } catch let error as ChatDiagnosticVersionError {
                throw DaemonXPCError.diagnosticVersion(error)
            }
            return snapshot
        }
    }

    /// Acknowledge a successfully persisted/copy-delivered export. The daemon
    /// validates the same versioned request boundary before rotating its ring.
    public func resetChatDiagnostics(_ request: ChatDiagnosticResetRequest) async throws {
        let requestData = try JSONEncoder().encode(request)
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.resetChatDiagnostics(request: requestData) { reply($0) }
            }
            guard replyData.isEmpty == false else { throw DaemonXPCError.unexpectedReply }
        }
    }

    /// Resolve a pending permission request for a chat.
    public func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws {
        let requestData = try JSONEncoder().encode(request)
        try await withTimeout {
            try await self.xpcVoidReply { reply in
                self.proxy.resolveChatPermission(request: requestData) { reply() }
            }
        }
    }

    /// Set a config option (e.g. thinking effort) on a live chat session.
    public func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws {
        let requestData = try JSONEncoder().encode(request)
        try await withTimeout {
            let replyData = try await self.xpcReply { reply in
                self.proxy.setChatConfigOption(request: requestData) { reply($0) }
            }
            if let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
               let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
        }
    }

    #endif // canImport(WikiFSEngine)
}
#endif
