import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

struct QueueStoreTypedTranscriptTests {
    @Test func upsertPreservesSequenceForEachTaggedIdentityKind() throws {
        let store = try QueueStore(databaseURL: try temporaryDatabaseURL())
        let item = try enqueueItem(in: store)
        let attemptID = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let initialItems = transcriptItems(rawID: "all-kinds", text: "initial")

        try store.upsertTranscriptItems(attemptID: attemptID, items: initialItems)

        let replacements = transcriptItems(rawID: "all-kinds", text: "replacement").reversed()
        try store.upsertTranscriptItems(attemptID: attemptID, items: Array(replacements))

        #expect(try store.loadTranscriptItems(itemID: item.id) == transcriptItems(rawID: "all-kinds", text: "replacement"))
    }

    @Test func identicalRawIDsInDifferentKindsDoNotCollide() throws {
        let store = try QueueStore(databaseURL: try temporaryDatabaseURL())
        let item = try enqueueItem(in: store)
        let attemptID = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let sharedRawID = "shared-provider-id"
        let items = transcriptItems(rawID: sharedRawID, text: "first")

        try store.upsertTranscriptItems(attemptID: attemptID, items: items)

        #expect(try store.loadTranscriptItems(itemID: item.id) == items)
    }

    @Test func typedTranscriptOrderSurvivesDatabaseReopen() throws {
        let url = try temporaryDatabaseURL()
        let itemID: QueueItem.ID
        let expected = transcriptItems(rawID: "reopen", text: "stored")

        do {
            let store = try QueueStore(databaseURL: url)
            let item = try enqueueItem(in: store)
            itemID = item.id
            try store.upsertTranscriptItems(
                attemptID: QueueAttemptID(itemID: item.id, attempt: item.attempt),
                items: expected
            )
            store.close()
        }

        let reopened = try QueueStore(databaseURL: url)
        #expect(try reopened.loadTranscriptItems(itemID: itemID) == expected)
    }

    @Test func nilToolOutputSurvivesDatabaseReopen() throws {
        let url = try temporaryDatabaseURL()
        let itemID: QueueItem.ID
        let expected = ChatTranscriptItem.toolCall(ChatTranscriptToolCallItem(
            toolCallID: ToolCallID(rawValue: "nil-output-tool"),
            turnID: ChatTurnID(rawValue: "nil-output-turn"),
            toolName: "Bash",
            status: .completed,
            detail: "echo hello",
            output: nil,
            permissionRequestID: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        do {
            let store = try QueueStore(databaseURL: url)
            let item = try enqueueItem(in: store)
            itemID = item.id
            try store.upsertTranscriptItems(
                attemptID: QueueAttemptID(itemID: item.id, attempt: item.attempt),
                items: [expected]
            )
            store.close()
        }

        let reopened = try QueueStore(databaseURL: url)
        #expect(try reopened.loadTranscriptItems(itemID: itemID) == [expected])
    }

    @Test func retryClearRemovesOnlyTheSelectedItemTranscript() throws {
        let store = try QueueStore(databaseURL: try temporaryDatabaseURL())
        let selectedItem = try enqueueItem(in: store)
        let preservedItem = try enqueueItem(in: store)
        let selectedItems = transcriptItems(rawID: "selected", text: "selected")
        let preservedItems = transcriptItems(rawID: "preserved", text: "preserved")

        try store.upsertTranscriptItems(
            attemptID: QueueAttemptID(itemID: selectedItem.id, attempt: selectedItem.attempt),
            items: selectedItems
        )
        try store.upsertTranscriptItems(
            attemptID: QueueAttemptID(itemID: preservedItem.id, attempt: preservedItem.attempt),
            items: preservedItems
        )
        try store.markRunning(id: selectedItem.id, providerID: ProviderID(rawValue: "test-provider"))
        try store.markFailed(id: selectedItem.id, error: "retry test")
        try store.retryItem(id: selectedItem.id)
        let retriedItem = try #require(try store.getItem(selectedItem.id))
        #expect(try store.loadTranscriptItems(itemID: selectedItem.id).isEmpty)
        try store.upsertTranscriptItems(
            attemptID: QueueAttemptID(itemID: retriedItem.id, attempt: retriedItem.attempt),
            items: transcriptItems(rawID: "selected-retry", text: "selected retry")
        )

        try store.deleteTranscriptItems(itemID: selectedItem.id)

        #expect(try store.loadTranscriptItems(itemID: selectedItem.id).isEmpty)
        #expect(try store.loadTranscriptItems(itemID: preservedItem.id) == preservedItems)
    }

    @Test func historyPruneCascadesTypedTranscriptRows() throws {
        let store = try QueueStore(databaseURL: try temporaryDatabaseURL())
        let item = try enqueueItem(in: store)
        try store.upsertTranscriptItems(
            attemptID: QueueAttemptID(itemID: item.id, attempt: item.attempt),
            items: transcriptItems(rawID: "prune", text: "prune")
        )
        try store.markRunning(id: item.id, providerID: ProviderID(rawValue: "test-provider"))
        try store.markCompleted(id: item.id)

        try store.pruneHistory(maxPerQueue: 0)

        #expect(try store.loadTranscriptItems(itemID: item.id).isEmpty)
    }

    @Test func staleAttemptBatchIsRejectedAtomically() throws {
        let store = try QueueStore(databaseURL: try temporaryDatabaseURL())
        let item = try enqueueItem(in: store)
        let currentAttempt = QueueAttemptID(itemID: item.id, attempt: item.attempt)
        let persistedItems = transcriptItems(rawID: "persisted", text: "persisted")
        try store.upsertTranscriptItems(attemptID: currentAttempt, items: persistedItems)
        try store.markRunning(id: item.id, providerID: ProviderID(rawValue: "test-provider"))
        try store.markFailed(id: item.id, error: "test failure")
        try store.retryItem(id: item.id)

        do {
            try store.upsertTranscriptItems(
                attemptID: currentAttempt,
                items: transcriptItems(rawID: "stale", text: "stale")
            )
            Issue.record("Expected stale attempt transcript batch to fail.")
        } catch QueueStoreError.staleAttempt(let rejectedAttempt, let currentAttempt) {
            #expect(rejectedAttempt.itemID == item.id)
            #expect(rejectedAttempt.attempt == item.attempt)
            #expect(currentAttempt == item.attempt + 1)
        }

        #expect(try store.loadTranscriptItems(itemID: item.id).isEmpty)
    }

    @Test func emptyTaggedIdentityIsRejectedBeforeWriting() throws {
        let store = try QueueStore(databaseURL: try temporaryDatabaseURL())
        let item = try enqueueItem(in: store)
        let invalidItem = ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: ""),
            turnID: ChatTurnID(rawValue: "invalid-identity-turn"),
            role: .assistant,
            text: "invalid",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        do {
            try store.upsertTranscriptItems(
                attemptID: QueueAttemptID(itemID: item.id, attempt: item.attempt),
                items: [invalidItem]
            )
            Issue.record("Expected an empty tagged identity to fail.")
        } catch QueueStoreError.invalidTranscriptIdentity(let kind) {
            #expect(kind == "message")
        }

        #expect(try store.loadTranscriptItems(itemID: item.id).isEmpty)
    }

    @Test func malformedStoredTypedItemIsLoggedAndSkipped() throws {
        let url = try temporaryDatabaseURL()
        let itemID: QueueItem.ID
        do {
            let store = try QueueStore(databaseURL: url)
            let item = try enqueueItem(in: store)
            itemID = item.id
            try store.upsertTranscriptItems(
                attemptID: QueueAttemptID(itemID: item.id, attempt: item.attempt),
                items: [transcriptItems(rawID: "malformed", text: "stored")[0]]
            )
            store.close()
        }
        try execute(
            sql: "UPDATE queue_item_transcript_items SET item_json = 'not-json' WHERE item_id = '\(itemID.rawValue)';",
            in: url
        )

        let reopened = try QueueStore(databaseURL: url)
        #expect(try reopened.loadTranscriptItems(itemID: itemID).isEmpty)
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-typed-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("queue.sqlite")
    }

    private func enqueueItem(in store: QueueStore) throws -> QueueItem {
        try store.enqueue(
            QueueItemRequest(
                queue: .extraction,
                wikiID: WikiID(rawValue: "typed-transcript-wiki"),
                payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "typed-transcript-source")])
            )
        )
    }

    private func transcriptItems(rawID: String, text: String) -> [ChatTranscriptItem] {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let turnID = ChatTurnID(rawValue: "turn-\(rawID)")
        return [
            .message(ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: rawID),
                turnID: turnID,
                role: .assistant,
                text: "message \(text)",
                createdAt: createdAt
            )),
            .toolCall(ChatTranscriptToolCallItem(
                toolCallID: ToolCallID(rawValue: rawID),
                turnID: turnID,
                toolName: "Bash",
                status: .completed,
                detail: "detail \(text)",
                output: "output \(text)",
                permissionRequestID: nil,
                updatedAt: createdAt
            )),
            .systemNotice(ChatTranscriptSystemNoticeItem(
                noticeID: ChatTranscriptNoticeID(rawValue: rawID),
                turnID: turnID,
                kind: .queue,
                title: "Notice \(text)",
                message: "notice \(text)",
                createdAt: createdAt
            )),
            .turnFailure(ChatTranscriptTurnFailureItem(
                failureID: ChatTranscriptFailureID(rawValue: rawID),
                turnID: turnID,
                category: .runtimeError,
                message: "failure \(text)",
                createdAt: createdAt
            )),
        ]
    }

    private func execute(sql: String, in url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not open typed transcript test database")
        }
        defer { sqlite3_close(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            throw QueueStoreError.sqlite(code: result, message: message)
        }
    }
}
