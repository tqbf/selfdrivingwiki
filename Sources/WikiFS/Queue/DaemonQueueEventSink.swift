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

    private let chatContinuation: AsyncStream<(String, QueueEventEnvelope)>.Continuation
    private let chatStream: AsyncStream<(String, QueueEventEnvelope)>

    override init() {
        var chatContinuation: AsyncStream<(String, QueueEventEnvelope)>.Continuation!
        self.chatStream = AsyncStream { c in chatContinuation = c }
        self.chatContinuation = chatContinuation
    }

    deinit {
        broadcaster.finish()
        chatContinuation.finish()
    }

    var events: AsyncStream<QueueEvent> { broadcaster.subscribe() }

    /// Chat envelopes from the daemon, demuxed by chatID. The app's chat
    /// session registry subscribes and routes each envelope to the matching
    /// `RemoteChatSession.ingest(_:)`.
    var chatEnvelopes: AsyncStream<(String, QueueEventEnvelope)> { chatStream }

    func deliverEvent(_ payload: Data) {
        guard let envelope = DebugLog.trying("decode queue event envelope", operation: { try JSONDecoder().decode(QueueEventEnvelope.self, from: payload) }) else { return }

        // Route chat envelopes to the chat stream.
        if envelope.isChatEnvelope, let chatID = envelope.chatID {
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
