#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for `QueueEventEnvelope` Codable round-trip. Each extraction-relevant
/// `QueueEvent` case must survive encode → decode → reconstruct.
struct QueueEventEnvelopeTests {

    private func makeItem() -> QueueItem {
        QueueItem(
            id: "01ABCDEF", queue: .extraction, wikiID: "wiki1",
            payload: QueueItemPayload(sourceIDs: [PageID(rawValue: "src1")]),
            state: .queued, orderingKey: 1000, attempt: 0, createdAt: 0)
    }

    @Test func lifecycleEventsRoundTrip() throws {
        let item = makeItem()
        let events: [QueueEvent] = [
            .enqueued(item),
            .started(item),
            .completed(item),
            .cancelled(item),
            .reordered(item),
        ]
        for event in events {
            let envelope = QueueEventEnvelope(from: event)
            #expect(envelope != nil)
            let data = try JSONEncoder().encode(envelope)
            let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
            let reconstructed = decoded.toQueueEvent()
            #expect(reconstructed != nil)
        }
    }

    @Test func failedEventRoundTrip() throws {
        let item = makeItem()
        let event = QueueEvent.failed(item, error: "something went wrong")
        let envelope = QueueEventEnvelope(from: event)
        #expect(envelope != nil)
        let data = try JSONEncoder().encode(envelope!)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        let reconstructed = decoded.toQueueEvent()
        #expect(reconstructed != nil)
        if case .failed(_, let error) = reconstructed! {
            #expect(error == "something went wrong")
        }
    }

    @Test func progressEventRoundTrip() throws {
        let event = QueueEvent.progress("item-1", line: "Converting…")
        let envelope = QueueEventEnvelope(from: event)
        let data = try JSONEncoder().encode(envelope!)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        let reconstructed = decoded.toQueueEvent()
        #expect(reconstructed != nil)
        if case .progress(let id, let line) = reconstructed! {
            #expect(id == "item-1")
            #expect(line == "Converting…")
        }
    }

    @Test func runStateChangedRoundTrip() throws {
        let event = QueueEvent.runStateChanged(queue: .extraction, state: .paused)
        let envelope = QueueEventEnvelope(from: event)
        let data = try JSONEncoder().encode(envelope!)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        let reconstructed = decoded.toQueueEvent()
        #expect(reconstructed != nil)
        if case .runStateChanged(let queue, let state) = reconstructed! {
            #expect(queue == .extraction)
            #expect(state == .paused)
        }
    }

    @Test func runPathsRoundTrip() throws {
        let logURL = URL(fileURLWithPath: "/tmp/log.jsonl")
        let event = QueueEvent.runPaths("item-1", logURL: logURL, debugURL: nil)
        let envelope = QueueEventEnvelope(from: event)
        let data = try JSONEncoder().encode(envelope!)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        let reconstructed = decoded.toQueueEvent()
        #expect(reconstructed != nil)
        if case .runPaths(let id, let log, let debug) = reconstructed! {
            #expect(id == "item-1")
            #expect(log == logURL)
            #expect(debug == nil)
        }
    }
}
#endif
