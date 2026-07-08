import Testing
import Foundation
import SQLite3
@testable import WikiFSCore

/// Store-level tests for persisted chat history (issue #119 phase 1): the
/// `chats` + `chat_messages` tables (schema v23), CRUD on `SQLiteWikiStore`,
/// dense per-chat `seq` assignment, `event_json` round-tripping through the
/// exact same typed `AgentEvent` pipeline as the live transcript, and
/// tolerant reads that skip a corrupt row instead of failing the whole chat.
@Suite struct ChatStoreTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-store-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    /// `Date` round-tripped through `timeIntervalSince1970` → SQLite `REAL` →
    /// `Date(timeIntervalSince1970:)` loses a little precision to floating-point
    /// rounding (the epoch-offset addition/subtraction isn't bit-exact), so
    /// comparing timestamps read back from the store uses a tolerance instead
    /// of `==`.
    private func datesApproximatelyEqual(_ a: Date, _ b: Date, tolerance: TimeInterval = 0.001) -> Bool {
        abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < tolerance
    }

    // MARK: - create + list

    @Test func createAndListRoundTrip() throws {
        let store = try tempStore()
        let before = Date()
        let chat = try store.createChat(kind: .ask, title: "What does this page say?")
        let after = Date()

        #expect(chat.kind == .ask)
        #expect(chat.title == "What does this page say?")
        #expect(chat.messageCount == 0)
        #expect(chat.createdAt == chat.updatedAt)
        #expect(chat.createdAt >= before && chat.createdAt <= after)

        let all = try store.listChats()
        #expect(all.count == 1)
        #expect(all[0].id == chat.id)
        #expect(all[0].kind == .ask)
        #expect(all[0].title == chat.title)
        #expect(all[0].messageCount == 0)
        #expect(datesApproximatelyEqual(all[0].createdAt, chat.createdAt))
        #expect(datesApproximatelyEqual(all[0].updatedAt, chat.updatedAt))
    }

    // MARK: - append: dense seq + updated_at bump reorders the list

    @Test func appendAssignsDenseSeqStartingAtZero() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Conversation")
        let inserted = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("first"), .assistantText("second"), .result(isError: false, text: "third"),
        ])
        #expect(inserted.map(\.seq) == [0, 1, 2])

        // A second append continues the sequence, not restarting it.
        let more = try store.appendChatMessages(chatID: chat.id, events: [.userText("fourth")])
        #expect(more.map(\.seq) == [3])

        let all = try store.chatMessages(chatID: chat.id)
        #expect(all.map(\.seq) == [0, 1, 2, 3])
    }

    @Test func appendBumpsUpdatedAtSoOlderChatSortsFirstAfterAppend() throws {
        let store = try tempStore()
        let older = try store.createChat(kind: .ask, title: "Older")
        let newer = try store.createChat(kind: .ask, title: "Newer")

        // Freshly listed: newer chat (created later) sorts first.
        let beforeAppend = try store.listChats()
        #expect(beforeAppend.map(\.id) == [newer.id, older.id])

        // Appending to the OLDER chat bumps its updated_at past the newer
        // chat's — it must now sort first.
        _ = try store.appendChatMessages(chatID: older.id, events: [.userText("hello")])
        let afterAppend = try store.listChats()
        #expect(afterAppend.map(\.id) == [older.id, newer.id])
        #expect(afterAppend.first { $0.id == older.id }?.messageCount == 1)
    }

    // MARK: - event JSON round trip through chatMessages

    @Test func eventJSONRoundTripsForEveryPersistableCase() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .ask, title: "Conversation")
        let events: [AgentEvent] = [
            .userText("What does this page say?"),
            .systemInit(model: "claude-opus-4"),
            .assistantText("Here's the answer."),
            .toolUse(name: "Bash", inputSummary: "wikictl page upsert --title \"X\""),
            .toolResult(isError: true, summary: "command not found"),
            .subagent(subagentType: "source-reader", description: "Digest pages 1-20", isCompletion: true),
            .result(isError: false, text: "Done."),
        ]
        _ = try store.appendChatMessages(chatID: chat.id, events: events)

        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == events.count)
        #expect(messages.map(\.event) == events)
        #expect(messages.map(\.seq) == Array(0..<events.count))
        #expect(messages.allSatisfy { $0.chatID == chat.id })
    }

    // MARK: - append edge cases

    @Test func appendToUnknownChatThrowsNotFound() throws {
        let store = try tempStore()
        let unknownID = PageID(rawValue: "01UNKNOWNCHAT00000000000A")
        #expect(throws: WikiStoreError.self) {
            try store.appendChatMessages(chatID: unknownID, events: [.userText("hi")])
        }
    }

    @Test func appendEmptyEventsIsANoOpAndDoesNotBumpUpdatedAt() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .ask, title: "Conversation")
        let originalUpdatedAt = chat.updatedAt

        let inserted = try store.appendChatMessages(chatID: chat.id, events: [])
        #expect(inserted.isEmpty)

        let reloaded = try store.listChats().first { $0.id == chat.id }
        #expect(reloaded.map { datesApproximatelyEqual($0.updatedAt, originalUpdatedAt) } == true)
        #expect(reloaded?.messageCount == 0)
    }

    // MARK: - rename

    @Test func renameUpdatesTitle() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .ask, title: "Original")
        try store.renameChat(id: chat.id, to: "Renamed")
        let reloaded = try store.listChats().first { $0.id == chat.id }
        #expect(reloaded?.title == "Renamed")
    }

    @Test func renameUnknownChatThrowsNotFound() throws {
        let store = try tempStore()
        let unknownID = PageID(rawValue: "01UNKNOWNCHAT00000000000B")
        #expect(throws: WikiStoreError.self) {
            try store.renameChat(id: unknownID, to: "New Title")
        }
    }

    // MARK: - delete cascades

    @Test func deleteChatCascadesToMessages() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .ask, title: "Conversation")
        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("hello")])

        try store.deleteChat(id: chat.id)

        #expect(try store.listChats().isEmpty)
        #expect(try store.chatMessages(chatID: chat.id).isEmpty)
    }

    @Test func deleteUnknownChatDoesNotThrow() throws {
        let store = try tempStore()
        let unknownID = PageID(rawValue: "01UNKNOWNCHAT00000000000C")
        #expect(throws: Never.self) {
            try store.deleteChat(id: unknownID)
        }
    }

    // MARK: - tolerant read: corrupt event_json is skipped

    @Test func chatMessagesSkipsRowWithCorruptEventJSON() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let chat = try store.createChat(kind: .ask, title: "Conversation")
        let inserted = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("before"), .assistantText("after"),
        ])
        #expect(inserted.count == 2)

        // Hand-insert a corrupt row between the two valid ones via a raw
        // connection (a future/garbled event_json a WikiStore method would
        // never write, but a bad row should never brick the rest of history).
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let corruptSQL = """
        INSERT INTO chat_messages (id, chat_id, seq, role, event_json, text, created_at)
        VALUES ('01CORRUPTROW000000000000A', '\(chat.id.rawValue)', 1_000,
                'assistant', '{not valid json', '', 999.0);
        """
        #expect(sqlite3_exec(raw, corruptSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        let messages = try store.chatMessages(chatID: chat.id)
        #expect(messages.count == 2)
        #expect(messages.map(\.event) == [.userText("before"), .assistantText("after")])
    }
}
