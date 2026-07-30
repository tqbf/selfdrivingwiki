#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

/// The app's `WikiDaemonEventSink` conformer. Receives JSON-encoded
/// `QueueEventEnvelope`s from the daemon and re-yields them:
/// - **Queue events** → a local `AsyncStream<QueueEvent>` for
///   `QueueActivityTracker` / `OperationNotifier`.
/// - **Chat envelopes** → a local `AsyncStream<(chatID, envelope)>` for
///   per-chat `RemoteChatSession` demux.
///
/// RC7: uses a `QueueEventBroadcaster` for queue events (multicast to all
/// subscribers — Tracker, MenuBar, Notifier) and its own `AsyncStream` for
/// chat envelopes.
final class DaemonQueueEventSink: NSObject, WikiDaemonEventSink, @unchecked Sendable {
    private let broadcaster = QueueEventBroadcaster()

    private let chatContinuation: AsyncStream<(ChatID, QueueEventEnvelope)>.Continuation
    private let chatStream: AsyncStream<(ChatID, QueueEventEnvelope)>

    override init() {
        let chatComponents = Self.makeChatStream()
        self.chatStream = chatComponents.stream
        self.chatContinuation = chatComponents.continuation
    }

    private static func makeChatStream() -> (
        stream: AsyncStream<(ChatID, QueueEventEnvelope)>,
        continuation: AsyncStream<(ChatID, QueueEventEnvelope)>.Continuation
    ) {
        var continuation: AsyncStream<(ChatID, QueueEventEnvelope)>.Continuation?
        let stream = AsyncStream<(ChatID, QueueEventEnvelope)> { continuation = $0 }
        guard let continuation else {
            preconditionFailure("AsyncStream must synchronously provide its continuation.")
        }
        return (stream, continuation)
    }

    deinit {
        broadcaster.finish()
        chatContinuation.finish()
    }

    var events: AsyncStream<QueueEvent> { broadcaster.subscribe() }

    /// Chat envelopes from the daemon, demuxed by chatID. The app's chat
    /// session registry subscribes and routes each envelope to the matching
    /// `RemoteChatSession.ingest(_:)`.
    var chatEnvelopes: AsyncStream<(ChatID, QueueEventEnvelope)> { chatStream }

    func deliverEvent(_ payload: Data) {
        guard let envelope = DebugLog.trying("decode queue event envelope", operation: { try JSONDecoder().decode(QueueEventEnvelope.self, from: payload) }) else { return }

        // Route chat envelopes to the chat stream.
        if envelope.isChatEnvelope {
            guard let chatID = envelope.chatID else {
                DebugLog.agent("DaemonQueueEventSink rejected chat envelope without chatID kind=\(envelope.kind.rawValue)")
                return
            }
            guard envelope.kind == .chatSyncUpdate else {
                DebugLog.agent("DaemonQueueEventSink rejected legacy chat envelope kind=\(envelope.kind.rawValue) chat=\(chatID.rawValue)")
                return
            }
            do {
                _ = try envelope.decodedChatSyncUpdate()
            } catch {
                DebugLog.agent("DaemonQueueEventSink rejected malformed chat sync update chat=\(chatID.rawValue): \(error)")
                return
            }
            chatContinuation.yield((chatID, envelope))
            return
        }

        // Route queue events to the queue broadcaster.
        if let event = envelope.toQueueEvent() {
            broadcaster.yield(event)
        }
    }
}
#endif
