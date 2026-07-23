#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// Tests for the `WikiDaemonEventSink` protocol — the reverse-channel
/// mechanism the daemon uses to push live workload events to the app.
///
/// Phase 0 verifies:
/// 1. The protocol is `@objc` + `AnyObject` (XPC proxy-able).
/// 2. `deliverEvent` can JSON-round-trip a `QueueSnapshot` payload (the
///    simplest event type; Phase A adds `QueueEvent` envelopes).
/// 3. The daemon captures registered event sinks.
///
/// See `plans/daemon-workloads.md` Phase 0 + correction C5.
struct WikiDaemonEventSinkTests {

    // MARK: - Protocol shape

    @Test func eventSinkProtocolIsObjcAndAnyObject() {
        // NSXPCInterface requires an @objc protocol — if it constructs
        // successfully, the protocol is @objc-compatible (XPC-proxy-able).
        let _ = NSXPCInterface(with: WikiDaemonEventSink.self)
    }

    // MARK: - JSON round-trip via deliverEvent

    @Test func deliverEventRoundTripsQueueSnapshot() throws {
        let snapshot = QueueSnapshot(
            activeItems: [],
            recentItems: [],
            runStates: [.extraction: .running, .ingestion: .running],
            providerCounts: ["test-provider": 1],
            activeIngestionWikis: ["wiki-1"]
        )

        // Encode as JSON (the daemon's path: encode → deliverEvent).
        let encoded = try JSONEncoder().encode(snapshot)

        // Deliver via the sink.
        let sink = TestEventSink()
        sink.deliverEvent(encoded)

        // Decode (the app's path: deliverEvent → decode).
        #expect(sink.receivedPayloads.count == 1)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: sink.receivedPayloads[0])
        #expect(decoded.runStates[.extraction] == .running)
        #expect(decoded.providerCounts["test-provider"] == 1)
        #expect(decoded.activeIngestionWikis.contains("wiki-1"))
    }

    @Test func deliverEventHandlesEmptySnapshot() throws {
        let snapshot = QueueSnapshot()
        let encoded = try JSONEncoder().encode(snapshot)

        let sink = TestEventSink()
        sink.deliverEvent(encoded)

        #expect(sink.receivedPayloads.count == 1)
        let decoded = try JSONDecoder().decode(QueueSnapshot.self, from: sink.receivedPayloads[0])
        #expect(decoded.activeItems.isEmpty)
        #expect(decoded.recentItems.isEmpty)
    }

    @Test func deliverEventHandlesInvalidJSON() {
        let sink = TestEventSink()
        sink.deliverEvent(Data("not json".utf8))

        #expect(sink.receivedPayloads.count == 1)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(QueueSnapshot.self, from: sink.receivedPayloads[0])
        }
    }

    // MARK: - Daemon sink registration

    @Test func daemonRegistersEventSink() throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink = TestEventSink()

        #expect(daemon.registeredEventSinks.isEmpty)
        daemon.registerEventSink(sink)
        #expect(daemon.registeredEventSinks.count == 1)
    }

    @Test func daemonRegistersMultipleEventSinks() throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink1 = TestEventSink()
        let sink2 = TestEventSink()

        daemon.registerEventSink(sink1)
        daemon.registerEventSink(sink2)
        #expect(daemon.registeredEventSinks.count == 2)
    }

    // MARK: - pushChatEnvelope logging paths (#872)

    /// With no sinks registered, `pushChatEnvelope` hits the unconditional
    /// "no sinks registered (drop)" `DebugLog.store` path and must not crash.
    /// This is the #871 diagnostic — events produced with nowhere to go — and
    /// it stays unconditional precisely so it surfaces in Console.app.
    @Test func pushChatEnvelopeWithNoSinksDoesNotCrash() throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let envelope = QueueEventEnvelope(kind: .chatEvent, chatID: "chat-1")

        daemon.pushChatEnvelope(envelope)
        // No crash / no throw => the empty-sinks drop path executed cleanly.
    }

    // MARK: - Event delivery (#871): events must reach registered sinks

    /// Regression for #871: `pushQueueEvent` must deliver every lifecycle
    /// event to a registered sink, encoded as a decodable envelope. The bug
    /// was that failures in envelope construction / JSON encoding were
    /// swallowed by silent `guard`/`try?` with no logging, so the app spun
    /// forever with no diagnostic.
    @Test func pushQueueEventDeliversLifecycleEventsToRegisteredSink() throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink = TestEventSink()
        daemon.registerEventSink(sink)

        let item = makeItem()
        let events: [QueueEvent] = [
            .enqueued(item),
            .started(item),
            .completed(item),
            .failed(item, error: "boom"),
            .cancelled(item),
        ]
        for event in events {
            daemon.pushQueueEvent(event)
        }

        #expect(sink.receivedPayloads.count == events.count)

        let decodedKinds = try sink.receivedPayloads.map {
            try JSONDecoder().decode(QueueEventEnvelope.self, from: $0).kind
        }
        #expect(decodedKinds == [.enqueued, .started, .completed, .failed, .cancelled])

        // Each envelope must round-trip back to a QueueEvent carrying the
        // original item (decode succeeds, item id survives).
        for payload in sink.receivedPayloads {
            let envelope = try JSONDecoder().decode(QueueEventEnvelope.self, from: payload)
            let reconstructed = try #require(envelope.toQueueEvent())
            #expect(reconstructed.item?.id == item.id)
        }
    }

    /// Regression for #871: with no sinks registered, `pushQueueEvent` must
    /// not crash (it logs the empty-sink count and returns). This is the
    /// silent-drop condition where the app's sink never reached the daemon.
    @Test func pushQueueEventIsSafeWithNoRegisteredSinks() {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)

        // No sinks registered — must not crash, must not deliver.
        daemon.pushQueueEvent(.enqueued(makeItem()))
    }

    /// Regression for #871: an event must be fanned out to EVERY registered
    /// sink (multiple app connections / windows).
    @Test func pushQueueEventFansOutToAllSinks() throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink1 = TestEventSink()
        let sink2 = TestEventSink()
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

    /// Regression for #871: `pushChatEnvelope` must deliver chat envelopes to
    /// registered sinks (the chat event stream — same silent-drop surface).
    @Test func pushChatEnvelopeDeliversToRegisteredSink() throws {
        let dir = makeTempDir()
        let daemon = WikiDaemon(containerDirectory: dir)
        let sink = TestEventSink()
        daemon.registerEventSink(sink)

        let envelope = QueueEventEnvelope(kind: .chatEvent, chatID: "chat-1")
        daemon.pushChatEnvelope(envelope)

        #expect(sink.receivedPayloads.count == 1)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: sink.receivedPayloads[0])
        #expect(decoded.kind == .chatEvent)
        #expect(decoded.chatID == "chat-1")
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
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
}

/// A test `WikiDaemonEventSink` conformer that captures all delivered payloads.
private final class TestEventSink: NSObject, WikiDaemonEventSink {
    var receivedPayloads: [Data] = []

    func deliverEvent(_ payload: Data) {
        receivedPayloads.append(payload)
    }
}
#endif
