import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Persistence contract tests for `ChatID`. The stored SQLite schema and raw
/// ULID text remain unchanged; only the Swift namespace at the store boundary
/// moved from chat-valued `PageID` to `ChatID`.
struct ChatIDPersistenceTests {

    private let legacyChatID = "01JCHATLEGACY0000000000000"
    private let legacyMessageID = "01JMSGLEGACY00000000000000"
    private let legacyAcpSessionID = "acp-legacy-session"

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-id-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    private func withDatabase<T>(at databaseURL: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open chat fixture database")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        try withDatabase(at: databaseURL) { database in
            sqlite3_busy_timeout(database, 5000)
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
                throw WikiStoreError.sqlite(code: -1, message: message)
            }
        }
    }

    private func normalizedRows(_ sql: String, at databaseURL: URL) throws -> [String] {
        try withDatabase(at: databaseURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
                throw WikiStoreError.sqlite(code: -1, message: message)
            }
            defer { sqlite3_finalize(statement) }

            var rows: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let columns = Int(sqlite3_column_count(statement))
                let values = (0..<columns).map { column -> String in
                    switch sqlite3_column_type(statement, Int32(column)) {
                    case SQLITE_INTEGER:
                        return String(sqlite3_column_int64(statement, Int32(column)))
                    case SQLITE_FLOAT:
                        return String(sqlite3_column_double(statement, Int32(column)))
                    case SQLITE_TEXT:
                        guard let text = sqlite3_column_text(statement, Int32(column)) else { return "NULL" }
                        return String(cString: text)
                    case SQLITE_NULL:
                        return "NULL"
                    case SQLITE_BLOB:
                        let bytes = sqlite3_column_blob(statement, Int32(column))
                        let count = Int(sqlite3_column_bytes(statement, Int32(column)))
                        guard let bytes, count > 0 else { return "" }
                        let data = Data(bytes: bytes, count: count)
                        return data.map { String(format: "%02X", $0) }.joined()
                    default:
                        return "NULL"
                    }
                }
                rows.append(values.joined(separator: "|"))
            }
            return rows
        }
    }

    private func normalizedIndexSQL(named names: [String], at databaseURL: URL) throws -> [String] {
        let nameList = names.map { "'\($0)'" }.joined(separator: ", ")
        return try normalizedRows(
            """
            SELECT name, TRIM(sql)
            FROM sqlite_master
            WHERE type = 'index' AND name IN (\(nameList))
            ORDER BY name;
            """,
            at: databaseURL
        ).map { row in
            let parts = row.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return row }
            let normalizedSQL = parts[1]
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return "\(parts[0])|\(normalizedSQL)"
        }
    }

    private func seedLegacyChatFixture(at databaseURL: URL) throws {
        try execute(
            """
            INSERT INTO chats (
                id, kind, title, created_at, updated_at, summary, summary_at,
                acp_session_id, model_provider_id, model_id
            ) VALUES (
                '\(legacyChatID)', 'edit', 'Legacy Chat', 1000, 1000,
                'Legacy summary', 1001, '\(legacyAcpSessionID)',
                'legacy-provider', 'legacy-model'
            );

            INSERT INTO chat_messages (
                id, chat_id, seq, role, event_json, text, created_at,
                summary, summary_kind, summary_at, is_draft, draft_handle
            ) VALUES (
                '\(legacyMessageID)', '\(legacyChatID)', 0, 'user',
                '{"userText":{"_0":"legacy hello"}}',
                'You:' || char(10) || 'legacy hello',
                1000,
                NULL, NULL, NULL, 0, NULL
            );

            INSERT INTO chat_chunks (chat_id, chunk_idx, embedding)
            VALUES ('\(legacyChatID)', 0, X'0102');

            INSERT INTO chat_search (chat_id, title, body)
            VALUES ('\(legacyChatID)', 'Legacy Chat', 'legacy hello');
            """,
            at: databaseURL
        )
    }

    @Test func legacyChatRowsDecodeWithoutMigration() throws {
        let databaseURL = try temporaryDatabaseURL()
        let initialStore = try GRDBWikiStore(databaseURL: databaseURL)
        let schemaVersionBefore = initialStore.pragmaValue("user_version")
        initialStore.close()

        try seedLegacyChatFixture(at: databaseURL)

        let reopened = try GRDBWikiStore(databaseURL: databaseURL)
        let chat = try #require(try reopened.listChats().first { $0.id.rawValue == legacyChatID })

        #expect(chat.id == ChatID(rawValue: legacyChatID))
        #expect(chat.title == "Legacy Chat")
        #expect(chat.acpSessionId == AcpSessionID(rawValue: legacyAcpSessionID))
        #expect(reopened.pragmaValue("user_version") == schemaVersionBefore)
        #expect(schemaVersionBefore == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func legacyChatMessageRowsPreserveTypedRelationship() throws {
        let databaseURL = try temporaryDatabaseURL()
        let initialStore = try GRDBWikiStore(databaseURL: databaseURL)
        initialStore.close()
        try seedLegacyChatFixture(at: databaseURL)

        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let messages = try store.chatMessages(chatID: ChatID(rawValue: legacyChatID))
        #expect(messages.count == 1)
        let message = try #require(messages.first)

        #expect(message.chatID == ChatID(rawValue: legacyChatID))
        #expect(message.id == PageID(rawValue: legacyMessageID))
        #expect(message.event == .userText("legacy hello"))

        #expect(try normalizedRows(
            "SELECT chat_id || '|' || chunk_idx || '|' || hex(embedding) FROM chat_chunks;",
            at: databaseURL
        ) == ["\(legacyChatID)|0|0102"])
        #expect(try normalizedRows(
            "SELECT chat_id || '|' || title || '|' || body FROM chat_search;",
            at: databaseURL
        ) == ["\(legacyChatID)|Legacy Chat|legacy hello"])
    }

    @Test func chatWritesPreserveRawIdentifiersAndSchemaVersion() throws {
        let databaseURL = try temporaryDatabaseURL()
        let initialStore = try GRDBWikiStore(databaseURL: databaseURL)
        let schemaVersionBefore = initialStore.pragmaValue("user_version")
        initialStore.close()
        try seedLegacyChatFixture(at: databaseURL)

        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let chatID = ChatID(rawValue: legacyChatID)
        _ = try store.appendChatMessages(chatID: chatID, events: [.assistantText("follow up")])
        try store.renameChat(id: chatID, to: "Renamed Legacy Chat")
        try store.storeChatChunks(id: chatID, chunks: [Data([0xAA, 0xBB, 0xCC]), Data([0xDD])])

        #expect(store.pragmaValue("user_version") == schemaVersionBefore)
        #expect(try normalizedRows(
            "SELECT id FROM chats WHERE id = '\(legacyChatID)';",
            at: databaseURL
        ) == [legacyChatID])
        #expect(try normalizedRows(
            "SELECT chat_id || '|' || seq || '|' || role FROM chat_messages ORDER BY seq;",
            at: databaseURL
        ) == [
            "\(legacyChatID)|0|user",
            "\(legacyChatID)|1|assistant",
        ])
        #expect(try normalizedRows(
            "SELECT chat_id || '|' || chunk_idx || '|' || hex(embedding) FROM chat_chunks ORDER BY chunk_idx;",
            at: databaseURL
        ) == [
            "\(legacyChatID)|0|AABBCC",
            "\(legacyChatID)|1|DD",
        ])
        #expect(try normalizedRows(
            "SELECT chat_id || '|' || title FROM chat_search;",
            at: databaseURL
        ) == ["\(legacyChatID)|Renamed Legacy Chat"])
    }

    @Test func chatIdentifierRefactorPreservesSchemaLayout() throws {
        let databaseURL = try temporaryDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: databaseURL)

        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(try normalizedRows("PRAGMA table_info('chats');", at: databaseURL) == [
            "0|id|TEXT|0|NULL|1",
            "1|kind|TEXT|1|NULL|0",
            "2|title|TEXT|1|NULL|0",
            "3|created_at|REAL|1|NULL|0",
            "4|updated_at|REAL|1|NULL|0",
            "5|summary|TEXT|0|NULL|0",
            "6|summary_at|REAL|0|NULL|0",
            "7|acp_session_id|TEXT|0|NULL|0",
            "8|model_provider_id|TEXT|0|NULL|0",
            "9|model_id|TEXT|0|NULL|0",
        ])
        #expect(try normalizedRows("PRAGMA table_info('chat_messages');", at: databaseURL) == [
            "0|id|TEXT|0|NULL|1",
            "1|chat_id|TEXT|1|NULL|0",
            "2|seq|INTEGER|1|NULL|0",
            "3|role|TEXT|1|NULL|0",
            "4|event_json|TEXT|1|NULL|0",
            "5|text|TEXT|1|''|0",
            "6|created_at|REAL|1|NULL|0",
            "7|summary|TEXT|0|NULL|0",
            "8|summary_kind|TEXT|0|NULL|0",
            "9|summary_at|REAL|0|NULL|0",
            "10|is_draft|INTEGER|1|0|0",
            "11|draft_handle|TEXT|0|NULL|0",
        ])
        #expect(try normalizedRows("PRAGMA table_info('chat_chunks');", at: databaseURL) == [
            "0|chat_id|TEXT|1|NULL|1",
            "1|chunk_idx|INTEGER|1|NULL|2",
            "2|embedding|BLOB|1|NULL|0",
        ])
        #expect(try normalizedRows("PRAGMA table_info('chat_search');", at: databaseURL) == [
            "0|chat_id|TEXT|0|NULL|1",
            "1|title|TEXT|1|NULL|0",
            "2|body|TEXT|1|NULL|0",
        ])
        #expect(try normalizedRows("PRAGMA foreign_key_list('chat_messages');", at: databaseURL) == [
            "0|0|chats|chat_id|id|NO ACTION|CASCADE|NONE",
        ])
        #expect(try normalizedRows("PRAGMA foreign_key_list('chat_chunks');", at: databaseURL) == [
            "0|0|chats|chat_id|id|NO ACTION|CASCADE|NONE",
        ])
        #expect(try normalizedRows("PRAGMA foreign_key_list('chat_search');", at: databaseURL) == [
            "0|0|chats|chat_id|id|NO ACTION|CASCADE|NONE",
        ])
        #expect(try normalizedIndexSQL(
            named: ["chats_updated", "chat_messages_draft_handle", "chat_messages_seq"],
            at: databaseURL
        ) == [
            "chat_messages_draft_handle|CREATE UNIQUE INDEX chat_messages_draft_handle ON chat_messages(draft_handle) WHERE draft_handle IS NOT NULL",
            "chat_messages_seq|CREATE UNIQUE INDEX chat_messages_seq ON chat_messages(chat_id, seq)",
            "chats_updated|CREATE INDEX chats_updated ON chats(updated_at)",
        ])
    }
}
