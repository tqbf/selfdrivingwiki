#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSEngine

/// The app's `WikiDaemonEventSink` conformer. Receives JSON-encoded
/// `QueueEventEnvelope`s from the daemon and re-yields them as `QueueEvent`s
/// onto a local `AsyncStream` that the app's `QueueActivityTracker` /
/// `OperationNotifier` consume — so existing `for await event in engine.events`
/// loops work unchanged.
///
/// RC7: uses its own `AsyncStream<QueueEvent>` + continuation (NOT a
/// `QueueEventBroadcaster`, which does not exist as a reusable type).
final class DaemonQueueEventSink: NSObject, WikiDaemonEventSink, @unchecked Sendable {
    private let continuation: AsyncStream<QueueEvent>.Continuation
    private let stream: AsyncStream<QueueEvent>

    override init() {
        var continuation: AsyncStream<QueueEvent>.Continuation!
        self.stream = AsyncStream { c in continuation = c }
        self.continuation = continuation
    }

    var events: AsyncStream<QueueEvent> { stream }

    func deliverEvent(_ payload: Data) {
        guard let envelope = try? JSONDecoder().decode(QueueEventEnvelope.self, from: payload),
              let event = envelope.toQueueEvent() else { return }
        continuation.yield(event)
    }
}
#endif
