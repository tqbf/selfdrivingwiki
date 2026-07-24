#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// Tests for `WikiDaemon` event sink management. Covers both the weak-reference
/// fix for the session leak (#878) and the fan-out/delivery regressions (#871).
struct WikiDaemonEventSinkTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-sink-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeItem() -> QueueItem {
        QueueItem(
            id: "01ABCDEF", queue: .extraction, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0)
    }

    /// A mock event sink that captures all delivered payloads.
    final class MockEventSink: NSObject, WikiDaemonEventSink {
        var receivedPayloads: [Data] = []
        func deliverEvent(_ payload: Data) {
            receivedPayloads.append(payload)
        }
    }

    // MARK: - Weak retention (#878)

    /// The daemon holds sinks weakly — dropping the last strong reference must
    /// clear them from the registry (the #878 leak fix). `registeredEventSinks`
    /// filters dead weak refs via `compactMap`, so it must report empty once
    /// the sole strong owner is released.
    @Test func eventSinksAreHeldWeakly() async {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)

        var sink: MockEventSink? = MockEventSink()
        daemon.registerEventSink(sink!)

        #expect(daemon.registeredEventSinks.count == 1)

        // Drop our strong reference — the daemon's weak ref must go nil.
        sink = nil

        #expect(daemon.registeredEventSinks.isEmpty)
    }

    // MARK: - Delivery (#871)

    /// No sinks registered — must not crash, must not deliver.
    @Test func pushQueueEventIsSafeWithNoRegisteredSinks() {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)

        daemon.pushQueueEvent(.enqueued(makeItem()))
    }

    /// An event must be fanned out to EVERY registered sink (multiple app
    /// connections / windows), each receiving a correctly-encoded envelope
    /// (#871 — the silent-drop symptom this subsystem guards against).
    @Test func pushQueueEventFansOutToAllSinks() throws {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink1 = MockEventSink()
        let sink2 = MockEventSink()
        daemon.registerEventSink(sink1)
        daemon.registerEventSink(sink2)

        daemon.pushQueueEvent(.started(makeItem()))

        #expect(sink1.receivedPayloads.count == 1)
        #expect(sink2.receivedPayloads.count == 1)
        let env1 = try JSONDecoder().decode(QueueEventEnvelope.self, from: sink1.receivedPayloads[0])
        let env2 = try JSONDecoder().decode(QueueEventEnvelope.self, from: sink2.receivedPayloads[0])
        #expect(env1.kind == .started)
        #expect(env2.kind == .started)
    }

    /// `pushChatEnvelope` must deliver chat envelopes to registered sinks with
    /// a correctly-encoded payload (the chat event stream — same silent-drop
    /// surface as queue events, #871).
    @Test func pushChatEnvelopeDeliversToRegisteredSink() throws {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink = MockEventSink()
        daemon.registerEventSink(sink)

        let envelope = QueueEventEnvelope(kind: .chatEvent, chatID: "chat-1")
        daemon.pushChatEnvelope(envelope)

        #expect(sink.receivedPayloads.count == 1)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: sink.receivedPayloads[0])
        #expect(decoded.kind == .chatEvent)
        #expect(decoded.chatID == "chat-1")
    }
}
#endif
