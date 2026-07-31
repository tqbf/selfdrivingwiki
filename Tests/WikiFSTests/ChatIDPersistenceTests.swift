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

    /// Freeze the literal pre-#957 persisted-chat schema version here rather
    /// than reading `GRDBWikiStore.schemaVersion`. Migration history records
    /// v44→v45 as the last chat-schema change before the nominal `ChatID`
    /// refactor (chat model override columns on `chats`), so this work must
    /// keep the legacy fixture at user_version 45.
    private let preChatIDRefactorSchemaVersion = "45"
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

    private func pragmaValue(_ pragma: String, at databaseURL: URL) throws -> String {
        try #require(try normalizedRows("PRAGMA \(pragma);", at: databaseURL).first)
    }

    private func createPreChatIDRefactorFixture(at databaseURL: URL) throws {
        try execute(
            """
            PRAGMA foreign_keys = ON;

            CREATE TABLE chats (
                id                 TEXT PRIMARY KEY,
                kind               TEXT NOT NULL,
                title              TEXT NOT NULL,
                created_at         REAL NOT NULL,
                updated_at         REAL NOT NULL,
                summary            TEXT,
                summary_at         REAL,
                acp_session_id     TEXT,
                model_provider_id  TEXT,
                model_id           TEXT
            );
            CREATE INDEX chats_updated ON chats(updated_at);

            CREATE TABLE chat_messages (
                id           TEXT PRIMARY KEY,
                chat_id      TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                seq          INTEGER NOT NULL,
                role         TEXT NOT NULL,
                event_json   TEXT NOT NULL,
                text         TEXT NOT NULL DEFAULT '',
                created_at   REAL NOT NULL,
                summary      TEXT,
                summary_kind TEXT,
                summary_at   REAL,
                is_draft     INTEGER NOT NULL DEFAULT 0,
                draft_handle TEXT
            );
            CREATE UNIQUE INDEX chat_messages_seq ON chat_messages(chat_id, seq);
            CREATE UNIQUE INDEX chat_messages_draft_handle
                ON chat_messages(draft_handle) WHERE draft_handle IS NOT NULL;

            CREATE TABLE chat_chunks (
                chat_id   TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                chunk_idx INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                PRIMARY KEY (chat_id, chunk_idx)
            ) WITHOUT ROWID;

            CREATE TABLE chat_search (
                chat_id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
                title   TEXT NOT NULL,
                body    TEXT NOT NULL
            );

            PRAGMA user_version = \(preChatIDRefactorSchemaVersion);

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

    private func assertPreChatIDRefactorSchemaLayout(at databaseURL: URL) throws {
        #expect(try pragmaValue("user_version", at: databaseURL) == preChatIDRefactorSchemaVersion)
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

    @Test func phase2MigrationDeletesLegacyChatRows() throws {
        let databaseURL = try temporaryDatabaseURL()
        try createPreChatIDRefactorFixture(at: databaseURL)
        #expect(try pragmaValue("user_version", at: databaseURL) == preChatIDRefactorSchemaVersion)

        let reopened = try GRDBWikiStore(databaseURL: databaseURL)
        #expect(reopened.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(try reopened.listChats().isEmpty)
        #expect(try reopened.chatMessages(chatID: ChatID(rawValue: legacyChatID)).isEmpty)
    }

    @Test func phase2MigrationClearsLegacyChatOwnedTables() throws {
        let databaseURL = try temporaryDatabaseURL()
        try createPreChatIDRefactorFixture(at: databaseURL)

        _ = try GRDBWikiStore(databaseURL: databaseURL)
        #expect(try normalizedRows(
            "SELECT COUNT(*) FROM chats;",
            at: databaseURL
        ) == ["0"])
        #expect(try normalizedRows(
            "SELECT COUNT(*) FROM chat_messages;",
            at: databaseURL
        ) == ["0"])
        #expect(try normalizedRows(
            "SELECT COUNT(*) FROM chat_chunks;",
            at: databaseURL
        ) == ["0"])
        #expect(try normalizedRows(
            "SELECT COUNT(*) FROM chat_search;",
            at: databaseURL
        ) == ["0"])
        #expect(try normalizedRows(
            "SELECT COUNT(*) FROM chat_turns;",
            at: databaseURL
        ) == ["0"])
        #expect(try normalizedRows(
            "SELECT COUNT(*) FROM chat_transcript_items;",
            at: databaseURL
        ) == ["0"])
    }

    @Test func postMigrationChatWritesUseRawIdentifiersAtV46() throws {
        let databaseURL = try temporaryDatabaseURL()
        try createPreChatIDRefactorFixture(at: databaseURL)
        #expect(try pragmaValue("user_version", at: databaseURL) == preChatIDRefactorSchemaVersion)

        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let chat = try store.createChat(kind: .edit, title: "Fresh Chat")
        _ = try store.appendChatMessages(chatID: chat.id, events: [.assistantText("follow up")])

        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(try normalizedRows(
            "SELECT id FROM chats WHERE id = '\(chat.id.rawValue)';",
            at: databaseURL
        ) == [chat.id.rawValue])
        #expect(try normalizedRows(
            "SELECT chat_id || '|' || seq || '|' || role FROM chat_messages ORDER BY seq;",
            at: databaseURL
        ) == [
            "\(chat.id.rawValue)|0|assistant",
        ])
    }

    @Test func phase2MigrationCreatesDurableTurnAndTranscriptTables() throws {
        let databaseURL = try temporaryDatabaseURL()
        try createPreChatIDRefactorFixture(at: databaseURL)
        try assertPreChatIDRefactorSchemaLayout(at: databaseURL)

        let store = try GRDBWikiStore(databaseURL: databaseURL)
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(try normalizedRows("PRAGMA table_info('chat_turns');", at: databaseURL) == [
            "0|chat_id|TEXT|1|NULL|1",
            "1|turn_id|TEXT|1|NULL|2",
            "2|command_id|TEXT|1|NULL|0",
            "3|ordinal|INTEGER|1|NULL|0",
            "4|state|TEXT|1|NULL|0",
            "5|user_text|TEXT|1|NULL|0",
            "6|context_refs_json|TEXT|1|NULL|0",
            "7|submitted_at|REAL|1|NULL|0",
            "8|edited_at|REAL|0|NULL|0",
            "9|claim_id|TEXT|0|NULL|0",
            "10|claimed_at|REAL|0|NULL|0",
            "11|provider_submitted_at|REAL|0|NULL|0",
            "12|provider_session_id|TEXT|0|NULL|0",
            "13|terminal_message|TEXT|0|NULL|0",
            "14|provider_id|TEXT|0|NULL|0",
            "15|model_id|TEXT|0|NULL|0",
            "16|finished_at|REAL|0|NULL|0",
            "17|input_tokens|INTEGER|0|NULL|0",
            "18|output_tokens|INTEGER|0|NULL|0",
            "19|thought_tokens|INTEGER|0|NULL|0",
            "20|cache_read_tokens|INTEGER|0|NULL|0",
            "21|cache_write_tokens|INTEGER|0|NULL|0",
            "22|cost_decimal|TEXT|0|NULL|0",
            "23|currency|TEXT|0|NULL|0",
        ])
        #expect(try normalizedRows("PRAGMA table_info('chat_transcript_items');", at: databaseURL) == [
            "0|chat_id|TEXT|1|NULL|1",
            "1|cursor|INTEGER|1|NULL|2",
            "2|item_kind|TEXT|1|NULL|0",
            "3|item_json|TEXT|1|NULL|0",
            "4|projected_event_json|TEXT|0|NULL|0",
            "5|projected_text|TEXT|1|''|0",
            "6|created_at|REAL|1|NULL|0",
        ])
    }
}
