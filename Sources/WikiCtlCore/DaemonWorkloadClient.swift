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
            return "Daemon XPC call timed out after 30s"
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

    private let proxy: WikiDaemonProtocol

    /// Create a workload client from an existing daemon connection (shares the
    /// same `NSXPCConnection` — no second connection). Throws if the connection
    /// can't vend a valid daemon proxy (e.g. it was already invalidated).
    public init(connection: WikiDaemonConnection) throws {
        self.proxy = try connection.daemonProxy()
    }

    init(proxy: WikiDaemonProtocol) {
        self.proxy = proxy
    }

    // MARK: - Timeout helper

    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval = 30,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw DaemonXPCError.timeout
            }
            guard let result = try await group.next() else {
                throw DaemonXPCError.unexpectedReply
            }
            group.cancelAll()
            return result
        }
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
        let data = try await withCheckedThrowingContinuation { cont in
            proxy.queueSnapshot { data in
                cont.resume(returning: data)
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
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.enqueueItem(request: requestData) { data in
                    cont.resume(returning: data)
                }
            }
            let payload = try self.decodeQueuePayload(QueueItemIDPayload.self, from: replyData)
            return QueueItemID(rawValue: payload.itemID)
        }
    }

    /// Cancel a specific queued or running item.
    public func cancelItem(_ id: QueueItem.ID) async throws {
        try await withTimeout {
            let data = await withCheckedContinuation { cont in
                self.proxy.cancelItem(id: id.rawValue) { cont.resume(returning: $0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Cancel all in-flight items. Returns the count cancelled.
    public func cancelAllInFlight() async throws -> Int {
        try await withTimeout {
            let data = await withCheckedContinuation { cont in
                self.proxy.cancelAllInFlight { cont.resume(returning: $0) }
            }
            return try self.decodeQueuePayload(QueueCountPayload.self, from: data).count
        }
    }

    /// Retry a failed item.
    public func retryItem(_ id: QueueItem.ID) async throws {
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.retryItem(id: id.rawValue) { data in
                    cont.resume(returning: data)
                }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: replyData)
        }
    }

    // MARK: - Pause / Resume / Halt / Reorder

    /// Pause a queue (stop dispatching new items).
    public func pause(_ queue: QueueKind) async throws {
        try await withTimeout {
            let data = await withCheckedContinuation { cont in
                self.proxy.pauseQueue(queue: queue.rawValue) { cont.resume(returning: $0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Resume a queue (restart dispatch).
    public func resume(_ queue: QueueKind) async throws {
        try await withTimeout {
            let data = await withCheckedContinuation { cont in
                self.proxy.resumeQueue(queue: queue.rawValue) { cont.resume(returning: $0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Halt a queue (pause + cancel all in-flight items for this queue kind).
    public func halt(_ queue: QueueKind) async throws {
        try await withTimeout {
            let data = await withCheckedContinuation { cont in
                self.proxy.haltQueue(queue: queue.rawValue) { cont.resume(returning: $0) }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    /// Reorder a queued item (move before `beforeItemID`, or end if nil).
    public func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {
        try await withTimeout {
            let data = await withCheckedContinuation { cont in
                self.proxy.reorderItem(id: id.rawValue, beforeItemID: beforeItemID?.rawValue) {
                    cont.resume(returning: $0)
                }
            }
            _ = try self.decodeQueuePayload(QueueVoidPayload.self, from: data)
        }
    }

    // MARK: - Status

    /// Whether the daemon has queued or running items for the given wiki.
    public func hasActiveWork(for wikiID: WikiID) async throws -> Bool {
        try await withTimeout {
            let data = await withCheckedContinuation { cont in
                self.proxy.hasActiveWork(wikiID: wikiID.rawValue) { cont.resume(returning: $0) }
            }
            return try self.decodeQueuePayload(QueueBoolPayload.self, from: data).value
        }
    }

    // MARK: - Await / Transcript / Activity

    /// Await the completion of a specific item. Envelope and transport failures
    /// throw. The returned payload preserves the queue item's domain result.
    public func waitForCompletion(of id: QueueItem.ID) async throws -> QueueCompletionPayload {
        try await withTimeout {
            let replyData = await withCheckedContinuation { cont in
                self.proxy.waitForCompletion(id: id.rawValue) { data in
                    cont.resume(returning: data)
                }
            }
            return try self.decodeQueuePayload(QueueCompletionPayload.self, from: replyData)
        }
    }

    /// Load persisted typed transcript items for a queue item.
    public func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] {
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.loadTranscript(itemID: itemID.rawValue) { data in
                    cont.resume(returning: data)
                }
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
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.loadAllActivitySnapshots { data in
                    cont.resume(returning: data)
                }
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

    /// Read the daemon queue ownership epoch without constructing queue resources.
    public func queueOwnershipStatus() async throws -> QueueOwnershipStatusPayload {
        try await withTimeout {
            let replyData = await withCheckedContinuation { cont in
                self.proxy.queueOwnershipStatus { cont.resume(returning: $0) }
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
            let replyData = await withCheckedContinuation { cont in
                self.proxy.relinquishQueue(request: request) { cont.resume(returning: $0) }
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
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.startChat(request: requestData) { data in
                    cont.resume(returning: data)
                }
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
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.submitChatTurn(request: requestData) { data in
                    cont.resume(returning: data)
                }
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
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.continueChat(request: requestData) { data in
                    cont.resume(returning: data)
                }
            }
            if let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
               let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
        }
    }

    /// Send a follow-up turn to an active chat session.
    public func sendChatMessage(chatID: ChatID, message: String) async throws {
        let requestData = try JSONEncoder().encode([
            "chatID": chatID.rawValue, "message": message
        ])
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.sendChatMessage(request: requestData) { data in
                    cont.resume(returning: data)
                }
            }
            if let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
               let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
        }
    }

    /// Stop/cancel the active chat turn.
    public func stopChat(_ chatID: ChatID) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.stopChat(chatID: chatID.rawValue) { cont.resume() }
            }
        }
    }

    /// Rehydrate a chat's live state after (re)connect.
    public func chatSessionState(_ chatID: ChatID) async throws -> ChatSyncSnapshot {
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.chatSessionState(chatID: chatID.rawValue) { data in
                    cont.resume(returning: data)
                }
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
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.chatDiagnosticSnapshot(request: requestData) { data in
                    cont.resume(returning: data)
                }
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
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.resetChatDiagnostics(request: requestData) { data in
                    cont.resume(returning: data)
                }
            }
            guard replyData.isEmpty == false else { throw DaemonXPCError.unexpectedReply }
        }
    }

    /// Resolve a pending permission request for a chat.
    public func resolveChatPermission(_ request: ChatPermissionResolveRequest) async throws {
        let requestData = try JSONEncoder().encode(request)
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.resolveChatPermission(request: requestData) { cont.resume() }
            }
        }
    }

    /// Set a config option (e.g. thinking effort) on a live chat session.
    public func setChatConfigOption(_ request: ChatConfigOptionRequest) async throws {
        let requestData = try JSONEncoder().encode(request)
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.setChatConfigOption(request: requestData) { data in
                    cont.resume(returning: data)
                }
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
