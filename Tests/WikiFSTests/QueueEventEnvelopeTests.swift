#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for `QueueEventEnvelope` Codable round-trip. Each extraction-relevant
/// `QueueEvent` case must survive encode → decode → reconstruct.
struct QueueEventEnvelopeTests {
    private func normalizedJSONString(from object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func makeItem() -> QueueItem {
        QueueItem(
            id: QueueItem.ID(rawValue: "01ABCDEF"), queue: .extraction, wikiID: WikiID(rawValue: "wiki1"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "src1")]),
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

    @Test func sourceIDJSONContractIsUnchanged() throws {
        let legacyEvent = Data(#"{"kind":"enqueued","item":{"id":"legacy-item","queue":"extraction","wikiID":"legacy-wiki","payload":{"sourceIDs":["LEGACY-SOURCE-ID"]},"state":"queued","orderingKey":1000,"attempt":0,"createdAt":0}}"#.utf8)

        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: legacyEvent)
        let item = try #require(decoded.item)
        #expect(item.payload.sourceIDs == [SourceID(rawValue: "LEGACY-SOURCE-ID")])

        let reencoded = try JSONEncoder().encode(decoded)
        let legacyObject = try JSONSerialization.jsonObject(with: legacyEvent)
        let reencodedObject = try JSONSerialization.jsonObject(with: reencoded)
        #expect(try normalizedJSONString(from: legacyObject) == normalizedJSONString(from: reencodedObject))
    }

    @Test func queueEventEnvelopeJSONIntentionallyCarriesNoMarkdownVersionField() throws {
        let item = makeItem()
        let event = QueueEvent.enqueued(item)
        let envelope = try #require(QueueEventEnvelope(from: event))
        let data = try JSONEncoder().encode(envelope)
        let raw = try #require(String(data: data, encoding: .utf8))

        #expect(raw.contains(#""sourceIDs":["src1"]"#))
        #expect(!raw.contains("SourceMarkdownVersionID"))
        #expect(!raw.contains("markdownVersion"))
        #expect(!raw.contains(#""pin""#))
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
        let event = QueueEvent.progress(QueueItem.ID(rawValue: "item-1"), line: "Converting…")
        let envelope = QueueEventEnvelope(from: event)
        let data = try JSONEncoder().encode(envelope!)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        let reconstructed = decoded.toQueueEvent()
        #expect(reconstructed != nil)
        if case .progress(let id, let line) = reconstructed! {
            #expect(id.rawValue == "item-1")
            #expect(line == "Converting…")
        }
    }

    @Test func typedTranscriptUpdateRoundTripsWithAttemptAndBatch() throws {
        let item = makeItem()
        let attemptID = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let row = ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "message"), turnID: attemptID.chatTurnID,
            role: .assistant, text: "typed", createdAt: .now))
        let event = QueueEvent.transcript(.init(
            attemptID: attemptID, batchNumber: 7, changedItems: [row]))
        let envelope = try #require(QueueEventEnvelope(from: event))
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        guard case .transcript(let update) = try #require(decoded.toQueueEvent()) else {
            Issue.record("Expected typed transcript update")
            return
        }
        #expect(update.attemptID == attemptID)
        #expect(update.batchNumber == 7)
        #expect(update.changedItems == [row])
    }

    @Test func transcriptRejectsMissingAttemptIdentity() throws {
        let envelope = QueueEventEnvelope(kind: .transcript, itemID: makeItem().id)
        #expect(envelope.toQueueEvent() == nil)
    }

    @Test func transcriptRejectsMissingBatchNumber() throws {
        let item = makeItem()
        let payload = "{\"attemptID\":{\"itemID\":\"\(item.id.rawValue)\",\"attempt\":0},\"changedItems\":[]}"
        let envelope = QueueEventEnvelope(
            kind: .transcript, itemID: item.id,
            transcriptUpdateData: Data(payload.utf8))
        #expect(envelope.toQueueEvent() == nil)
    }

    @Test func transcriptEnvelopeContainsNoAgentEventPayload() throws {
        let item = makeItem()
        let update = QueueTranscriptUpdate(
            attemptID: .init(itemID: item.id, attempt: item.attempt),
            batchNumber: 0,
            changedItems: [])
        let envelope = try #require(QueueEventEnvelope(from: .transcript(update)))
        #expect(envelope.agentEventData == nil)
        #expect(envelope.transcriptUpdateData != nil)
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
        let event = QueueEvent.runPaths(QueueItem.ID(rawValue: "item-1"), logURL: logURL, debugURL: nil)
        let envelope = QueueEventEnvelope(from: event)
        let data = try JSONEncoder().encode(envelope!)
        let decoded = try JSONDecoder().decode(QueueEventEnvelope.self, from: data)
        let reconstructed = decoded.toQueueEvent()
        #expect(reconstructed != nil)
        if case .runPaths(let id, let log, let debug) = reconstructed! {
            #expect(id.rawValue == "item-1")
            #expect(log == logURL)
            #expect(debug == nil)
        }
    }
}
#endif
