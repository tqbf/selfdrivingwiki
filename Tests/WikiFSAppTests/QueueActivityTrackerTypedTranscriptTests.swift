import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

@MainActor
struct QueueActivityTrackerTypedTranscriptTests {
    @Test func liveEventsReduceAgainstAccumulatedItems() {
        let tracker = QueueActivityTracker()
        let item = queueItem(attempt: 0)
        let attempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        tracker.handleForTesting(.started(item))

        tracker.handleForTesting(.transcript(.init(
            attemptID: attempt,
            batchNumber: 0,
            changedItems: [message(id: "message", text: "partial")]
        )))
        tracker.handleForTesting(.transcript(.init(
            attemptID: attempt,
            batchNumber: 1,
            changedItems: [message(id: "message", text: "complete"), message(id: "later", text: "later")]
        )))

        #expect(messageTexts(tracker.transcript(for: item.id)) == ["complete", "later"])
    }

    @Test func retryChangesAttemptAndClearsLiveState() {
        let tracker = QueueActivityTracker()
        let firstItem = queueItem(attempt: 0)
        let firstAttempt = QueueAttemptID(itemID: firstItem.id, attempt: firstItem.attempt)
        tracker.handleForTesting(.started(firstItem))
        tracker.handleForTesting(.transcript(.init(
            attemptID: firstAttempt,
            batchNumber: 0,
            changedItems: [message(id: "old", text: "old output")]
        )))

        let retriedItem = queueItem(attempt: 1)
        let retryAttempt = QueueAttemptID(itemID: retriedItem.id, attempt: retriedItem.attempt)
        tracker.handleForTesting(.started(retriedItem))
        tracker.handleForTesting(.transcript(.init(
            attemptID: retryAttempt,
            batchNumber: 0,
            changedItems: [message(id: "new", text: "new output")]
        )))

        #expect(messageTexts(tracker.transcript(for: firstItem.id)) == ["new output"])
    }

    @Test func staleAttemptEventIsNotRendered() {
        let tracker = QueueActivityTracker()
        let item = queueItem(attempt: 1)
        let currentAttempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let staleAttempt = QueueAttemptID(itemID: item.id, attempt: 0)
        tracker.handleForTesting(.started(item))
        tracker.handleForTesting(.transcript(.init(
            attemptID: currentAttempt,
            batchNumber: 0,
            changedItems: [message(id: "current", text: "current")]
        )))
        tracker.handleForTesting(.transcript(.init(
            attemptID: staleAttempt,
            batchNumber: 1,
            changedItems: [message(id: "stale", text: "stale")]
        )))

        #expect(messageTexts(tracker.transcript(for: item.id)) == ["current"])
    }

    private func queueItem(attempt: Int) -> QueueItem {
        QueueItem(
            id: QueueItemID(rawValue: "activity-typed-item"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "activity-typed-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "source")]),
            state: .running,
            orderingKey: 1_000,
            attempt: attempt,
            createdAt: 0
        )
    }

    private func message(id: String, text: String) -> ChatTranscriptItem {
        .message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: id),
            turnID: ChatTurnID(rawValue: "activity-typed-turn"),
            role: .assistant,
            text: text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }

    private func messageTexts(_ items: [ChatTranscriptItem]) -> [String] {
        items.compactMap { item in
            guard case .message(let message) = item else { return nil }
            return message.text
        }
    }
}
