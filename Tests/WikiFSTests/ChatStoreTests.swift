import Testing
import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
@testable import WikiFSCore

/// Store-level tests for persisted chat history (issue #119 phase 1): the
/// `chats` + `chat_messages` tables (schema v23), CRUD on `GRDBWikiStore`,
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

    private func tempStore() throws -> GRDBWikiStore {
        try GRDBWikiStore(databaseURL: tempDatabaseURL())
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
        let chat = try store.createChat(kind: .edit, title: "What does this page say?")
        let after = Date()

        #expect(chat.kind == .edit)
        #expect(chat.title == "What does this page say?")
        #expect(chat.messageCount == 0)
        #expect(chat.createdAt == chat.updatedAt)
        #expect(chat.createdAt >= before && chat.createdAt <= after)

        let all = try store.listChats()
        #expect(all.count == 1)
        #expect(all[0].id == chat.id)
        #expect(all[0].kind == .edit)
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
        let older = try store.createChat(kind: .edit, title: "Older")
        let newer = try store.createChat(kind: .edit, title: "Newer")

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
        let chat = try store.createChat(kind: .edit, title: "Conversation")
        let events: [AgentEvent] = [
            .userText("What does this page say?"),
            .systemInit(model: "claude-opus-4"),
            .assistantText("Here's the answer."),
            .toolUse(name: "Bash", inputSummary: "wikictl page add --title \"X\""),
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
        let chat = try store.createChat(kind: .edit, title: "Conversation")
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
        let chat = try store.createChat(kind: .edit, title: "Original")
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
        let chat = try store.createChat(kind: .edit, title: "Conversation")
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

        // Seed via the store, then explicitly close the connection before the
        // raw insert. Opening a second raw connection while the store's WAL-holding
        // connection is still live intermittently returned SQLITE_ERROR under CI
        // load (the raw INSERT can fail to acquire the write lock). Previous fixes
        // (#223, #234) relied on the store leaving a `do { }` scope to trigger
        // `deinit` — but ARC does not guarantee deinit timing, so the race
        // recurred. `store.close()` closes the connection synchronously:
        // `sqlite3_close` checkpoints + quiesces the WAL when it's the last open
        // connection, so the raw write runs against a clean file.
        let store = try GRDBWikiStore(databaseURL: url)
        let chat = try store.createChat(kind: .edit, title: "Conversation")
        let inserted = try store.appendChatMessages(chatID: chat.id, events: [
            .userText("before"), .assistantText("after"),
        ])
        #expect(inserted.count == 2)
        let chatID = chat.id
        store.close()

        // Hand-insert a corrupt row between the two valid ones via a raw
        // connection on the now-quiescent DB (a future/garbled event_json a
        // WikiStore method would never write, but a bad row should never brick
        // the rest of history).
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        sqlite3_busy_timeout(raw, 5000)
        sqlite3_exec(raw, "PRAGMA foreign_keys=OFF;", nil, nil, nil)
        let corruptSQL = """
        INSERT INTO chat_messages (id, chat_id, seq, role, event_json, text, created_at)
        VALUES ('01CORRUPTROW000000000000A', '\(chatID.rawValue)', 1_000,
                'assistant', '{not valid json', '', 999.0);
        """
        #expect(sqlite3_exec(raw, corruptSQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // Reopen and read: the corrupt row is skipped, the two valid ones survive.
        let reader = try GRDBWikiStore(databaseURL: url)
        let messages = try reader.chatMessages(chatID: chatID)
        #expect(messages.count == 2)
        #expect(messages.map(\.event) == [.userText("before"), .assistantText("after")])
    }

    // MARK: - ACP session ID (#830)

    /// AC.2: a fresh schema has the `acp_session_id` column on the chats table.
    @Test func freshSchemaHasChatAcpSessionIdColumn() throws {
        let store = try tempStore()
        #expect(GRDBWikiStore.schemaVersion == 44)
        let hasCol = store.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chats') WHERE name='acp_session_id';")
        #expect(hasCol == "1")
    }

    /// AC.3: round-trip write + read + clear of `acpSessionId`.
    @Test func updateChatAcpSessionIdRoundTrip() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Test")

        // Initially nil.
        #expect(try store.getChat(id: chat.id).acpSessionId == nil)

        // Write.
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: "acp-123")
        #expect(try store.getChat(id: chat.id).acpSessionId == "acp-123")

        // Clear.
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: nil)
        #expect(try store.getChat(id: chat.id).acpSessionId == nil)
    }

    /// AC.4: `listChats` includes the `acpSessionId` in the result set.
    @Test func listChatsIncludesAcpSessionId() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Test")
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: "acp-456")
        let listed = try store.listChats()
        #expect(listed.first(where: { $0.id == chat.id })?.acpSessionId == "acp-456")
    }

    /// AC.4b: `listAllChatsOrderedByID` includes the `acpSessionId`.
    @Test func listAllChatsIncludesAcpSessionId() throws {
        let store = try tempStore()
        let chat = try store.createChat(kind: .edit, title: "Test")
        try store.updateChatAcpSessionId(chatID: chat.id, acpSessionId: "acp-789")
        let listed = try store.listAllChatsOrderedByID()
        #expect(listed.first(where: { $0.id == chat.id })?.acpSessionId == "acp-789")
    }

    /// AC.1: migration v42→v43 adds the `acp_session_id` column to a DB
    /// that was at v42 without it. After the full ladder, the DB should be at
    /// version 44 (v43→v44 adds is_draft/draft_handle to chat_messages).
    @Test func chatAcpSessionIdMigrationAddsColumn() throws {
        let url = tempDatabaseURL()

        // Build a v42 DB by hand: chats + chat_messages tables WITHOUT
        // acp_session_id / is_draft / draft_handle, user_version=42.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, """
        CREATE TABLE chats (id TEXT PRIMARY KEY, kind TEXT, title TEXT,
            created_at REAL, updated_at REAL, summary TEXT, summary_at REAL);
        """, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(raw, """
        CREATE TABLE chat_messages (id TEXT PRIMARY KEY, chat_id TEXT, seq INTEGER,
            role TEXT, event_json TEXT, text TEXT, created_at REAL,
            summary TEXT, summary_kind TEXT, summary_at REAL);
        """, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "PRAGMA user_version = 42;", nil, nil, nil) == SQLITE_OK)

        // Open via GRDBWikiStore — triggers the migration ladder (v42→v43→v44).
        let store = try GRDBWikiStore(databaseURL: url)

        // After the full ladder, version is 44 and both migration steps ran.
        #expect(store.pragmaValue("user_version") == "44")
        let hasCol = store.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chats') WHERE name='acp_session_id';")
        #expect(hasCol == "1")
        let hasDraftCol = store.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chat_messages') WHERE name='is_draft';")
        #expect(hasDraftCol == "1")
    }
}
