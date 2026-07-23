#if os(macOS)
import Foundation
import WikiFSCore
#if canImport(WikiFSEngine)
import WikiFSEngine
#endif
/// Errors from daemon XPC workload calls.
public enum DaemonXPCError: Error, LocalizedError {
    case timeout
    case failure(String)
    case unexpectedReply

    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "Daemon XPC call timed out after 30s"
        case .failure(let msg):
            return msg
        case .unexpectedReply:
            return "Unexpected reply from daemon"
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
    /// same `NSXPCConnection` — no second connection).
    public init(connection: WikiDaemonConnection) {
        self.proxy = connection.proxy
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
        do {
            return try JSONDecoder().decode(QueueSnapshot.self, from: data)
        } catch {
            throw WikiDaemonError.unexpectedReply
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
            guard let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
                  let id = dict["id"] as? String else {
                throw DaemonXPCError.unexpectedReply
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
            return id
        }
    }

    /// Cancel a specific queued or running item.
    public func cancelItem(_ id: QueueItem.ID) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.cancelItem(id: id) { cont.resume() }
            }
        }
    }

    /// Cancel all in-flight items. Returns the count cancelled.
    public func cancelAllInFlight() async throws -> Int {
        try await withTimeout {
            await withCheckedContinuation { cont in
                self.proxy.cancelAllInFlight { count in
                    cont.resume(returning: count)
                }
            }
        }
    }

    /// Retry a failed item.
    public func retryItem(_ id: QueueItem.ID) async throws {
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.retryItem(id: id) { data in
                    cont.resume(returning: data)
                }
            }
            if let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
               let error = dict["error"] as? String, !error.isEmpty {
                throw DaemonXPCError.failure(error)
            }
        }
    }

    // MARK: - Pause / Resume / Halt / Reorder

    /// Pause a queue (stop dispatching new items).
    public func pause(_ queue: QueueKind) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.pauseQueue(queue: queue.rawValue) { cont.resume() }
            }
        }
    }

    /// Resume a queue (restart dispatch).
    public func resume(_ queue: QueueKind) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.resumeQueue(queue: queue.rawValue) { cont.resume() }
            }
        }
    }

    /// Halt a queue (pause + cancel all in-flight items for this queue kind).
    public func halt(_ queue: QueueKind) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.haltQueue(queue: queue.rawValue) { cont.resume() }
            }
        }
    }

    /// Reorder a queued item (move before `beforeItemID`, or end if nil).
    public func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.reorderItem(id: id, beforeItemID: beforeItemID) { cont.resume() }
            }
        }
    }

    // MARK: - Status

    /// Whether the daemon has queued or running items for the given wiki.
    public func hasActiveWork(for wikiID: String) async throws -> Bool {
        try await withTimeout {
            await withCheckedContinuation { cont in
                self.proxy.hasActiveWork(wikiID: wikiID) { result in
                    cont.resume(returning: result)
                }
            }
        }
    }

    // MARK: - Await / Transcript / Activity

    /// Await the completion of a specific item. Throws on failure/cancellation.
    public func waitForCompletion(of id: QueueItem.ID) async throws {
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.waitForCompletion(id: id) { data in
                    cont.resume(returning: data)
                }
            }
            guard let dict = try JSONSerialization.jsonObject(with: replyData) as? [String: Any] else {
                throw DaemonXPCError.unexpectedReply
            }
            if dict["success"] as? Bool == true {
                return
            }
            let errorMsg = (dict["error"] as? String) ?? "unknown error"
            throw DaemonXPCError.failure(errorMsg)
        }
    }

    /// Load persisted transcript events for a queue item.
    public func loadTranscript(for itemID: QueueItem.ID) async throws -> [AgentEvent] {
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.loadTranscript(itemID: itemID) { data in
                    cont.resume(returning: data)
                }
            }
            do {
                return try JSONDecoder().decode([AgentEvent].self, from: replyData)
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
            do {
                return try JSONDecoder().decode(
                    [String: QueueEngine.ActivitySnapshotData].self,
                    from: replyData)
            } catch {
                throw DaemonXPCError.unexpectedReply
            }
        }
    }

    // MARK: - Chat (Phase C)

    #if canImport(WikiFSEngine)

    /// Start a new chat on the daemon. Returns the assigned chat ULID.
    @discardableResult
    public func startChat(_ request: ChatStartRequest) async throws -> String {
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
            return chatID
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
    public func sendChatMessage(chatID: String, message: String) async throws {
        let requestData = try JSONEncoder().encode([
            "chatID": chatID, "message": message
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
    public func stopChat(_ chatID: String) async throws {
        try await withTimeout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.proxy.stopChat(chatID: chatID) { cont.resume() }
            }
        }
    }

    /// Rehydrate a chat's live state after (re)connect.
    public func chatSessionState(_ chatID: String) async throws -> ChatSessionState {
        try await withTimeout {
            let replyData = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                self.proxy.chatSessionState(chatID: chatID) { data in
                    cont.resume(returning: data)
                }
            }
            do {
                return try JSONDecoder().decode(ChatSessionState.self, from: replyData)
            } catch {
                throw DaemonXPCError.unexpectedReply
            }
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
