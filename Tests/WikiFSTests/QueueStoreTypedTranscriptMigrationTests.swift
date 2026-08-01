import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

struct QueueStoreTypedTranscriptMigrationTests {
    @Test func finalMigrationCreatesTypedTranscriptTableAndDropsLegacyEventTable() throws {
        let url = try temporaryDatabaseURL()
        let store = try QueueStore(databaseURL: url)
        store.close()

        #expect(try tableExists(named: "queue_item_transcript_items", in: url))
        #expect(try tableExists(named: "queue_item_events", in: url) == false)
    }

    @Test func finalMigrationDropsOnlyLegacyTranscriptTableFromV4Fixture() throws {
        let url = try temporaryDatabaseURL()
        try createV4Fixture(at: url)
        let preservedTables = [
            "queue_items", "queue_state", "queue_item_activity",
            "chats", "chat_messages", "usage_data", "log_data",
            "debug_data", "progress_data",
        ]
        let before = try Dictionary(uniqueKeysWithValues: preservedTables.map { table in
            (table, try tableSnapshot(named: table, in: url))
        })

        let store = try QueueStore(databaseURL: url)
        store.close()

        #expect(try tableExists(named: "queue_item_events", in: url) == false)
        #expect(try tableExists(named: "queue_item_transcript_items", in: url))
        for table in preservedTables {
            #expect(try tableSnapshot(named: table, in: url) == before[table])
        }
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-typed-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("queue.sqlite")
    }

    private func tableExists(named tableName: String, in url: URL) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not open migration test database")
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not prepare table lookup")
        }
        defer { sqlite3_finalize(statement) }

        return try tableName.withCString { tableNamePointer in
            guard sqlite3_bind_text(statement, 1, tableNamePointer, -1, nil) == SQLITE_OK else {
                throw QueueStoreError.sqlite(code: -1, message: "Could not bind table name")
            }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    /// Seeds exactly the v4 queue schema plus unrelated chat and diagnostic
    /// tables. The nullable/non-default values make an accidental broad table
    /// rewrite visible in the raw SQL snapshots above.
    private func createV4Fixture(at url: URL) throws {
        try execute(sql: """
        CREATE TABLE queue_items (
            id TEXT PRIMARY KEY, queue TEXT NOT NULL, wiki_id TEXT NOT NULL,
            payload TEXT NOT NULL, state TEXT NOT NULL, ordering_key INTEGER NOT NULL,
            provider_id TEXT, attempt INTEGER NOT NULL DEFAULT 0, error TEXT,
            created_at INTEGER NOT NULL, started_at INTEGER, finished_at INTEGER
        );
        CREATE TABLE queue_state (queue TEXT PRIMARY KEY, state TEXT NOT NULL);
        CREATE TABLE queue_item_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT NOT NULL,
            seq INTEGER NOT NULL, event_json TEXT NOT NULL, created_at INTEGER NOT NULL
        );
        CREATE TABLE queue_item_activity (
            item_id TEXT PRIMARY KEY, usage_json TEXT, log_url TEXT, debug_url TEXT,
            progress_log TEXT, updated_at INTEGER NOT NULL
        );
        CREATE TABLE chats (id TEXT PRIMARY KEY, title TEXT, created_at INTEGER);
        CREATE TABLE chat_messages (chat_id TEXT, seq INTEGER, event_json TEXT, created_at INTEGER);
        CREATE TABLE usage_data (id TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE log_data (id TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE debug_data (id TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE progress_data (id TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);

        INSERT INTO queue_items VALUES (
            'fixture-item', 'extraction', 'fixture-wiki', '{"sourceIDs":["fixture-source"]}',
            'failed', 4200, NULL, 7, 'non-default failure', 111, NULL, 333
        );
        INSERT INTO queue_state VALUES ('extraction', 'queue-paused');
        INSERT INTO queue_state VALUES ('ingestion', 'queue-running');
        INSERT INTO queue_item_events (item_id, seq, event_json, created_at)
            VALUES ('fixture-item', 9, '{"assistantText":"legacy"}', 222);
        INSERT INTO queue_item_activity VALUES (
            'fixture-item', '{"inputTokens":7}', 'file:///fixture/run.jsonl', NULL,
            'first line\nsecond line', 444
        );
        INSERT INTO chats VALUES ('fixture-chat', NULL, 555);
        INSERT INTO chat_messages VALUES ('fixture-chat', 3, '{"userText":"keep"}', 556);
        INSERT INTO usage_data VALUES ('usage', 'non-default usage');
        INSERT INTO log_data VALUES ('log', 'non-default log');
        INSERT INTO debug_data VALUES ('debug', NULL);
        INSERT INTO progress_data VALUES ('progress', 'non-default progress');
        INSERT INTO grdb_migrations VALUES ('v1_create_queue_schema');
        INSERT INTO grdb_migrations VALUES ('v2_add_item_events');
        INSERT INTO grdb_migrations VALUES ('v3_namespace_run_state');
        INSERT INTO grdb_migrations VALUES ('v4_add_item_activity');
        """, in: url)
    }

    private func tableSnapshot(named tableName: String, in url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not open migration snapshot database")
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not prepare migration snapshot")
        }
        defer { sqlite3_finalize(statement) }
        let schema = try tableName.withCString { pointer -> String in
            guard sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK else {
                throw QueueStoreError.sqlite(code: -1, message: "Could not bind migration snapshot table")
            }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let schemaPointer = sqlite3_column_text(statement, 0)
            else {
                throw QueueStoreError.sqlite(code: -1, message: "Missing migration snapshot table \(tableName)")
            }
            return String(cString: schemaPointer)
        }

        let rowExpression: String
        switch tableName {
        case "queue_items":
            rowExpression = "quote(id) || '|' || quote(queue) || '|' || quote(wiki_id) || '|' || quote(payload) || '|' || quote(state) || '|' || quote(ordering_key) || '|' || quote(provider_id) || '|' || quote(attempt) || '|' || quote(error) || '|' || quote(created_at) || '|' || quote(started_at) || '|' || quote(finished_at)"
        case "queue_state":
            rowExpression = "quote(queue) || '|' || quote(state)"
        case "queue_item_activity":
            rowExpression = "quote(item_id) || '|' || quote(usage_json) || '|' || quote(log_url) || '|' || quote(debug_url) || '|' || quote(progress_log) || '|' || quote(updated_at)"
        case "chats":
            rowExpression = "quote(id) || '|' || quote(title) || '|' || quote(created_at)"
        case "chat_messages":
            rowExpression = "quote(chat_id) || '|' || quote(seq) || '|' || quote(event_json) || '|' || quote(created_at)"
        default:
            rowExpression = "quote(id) || '|' || quote(value)"
        }
        var rowStatement: OpaquePointer?
        let rowSQL = "SELECT COALESCE(group_concat(row_snapshot, char(30)), '') FROM (SELECT \(rowExpression) AS row_snapshot FROM \"\(tableName)\" ORDER BY rowid);"
        guard sqlite3_prepare_v2(database, rowSQL, -1, &rowStatement, nil) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not prepare migration row snapshot")
        }
        defer { sqlite3_finalize(rowStatement) }
        guard sqlite3_step(rowStatement) == SQLITE_ROW else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not read migration row snapshot")
        }
        let rows = sqlite3_column_text(rowStatement, 0).map { String(cString: $0) } ?? "NULL"
        return "\(schema)\n\(rows)"
    }

    private func execute(sql: String, in url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "Could not open fixture database")
        }
        defer { sqlite3_close(database) }

        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorPointer)
            throw QueueStoreError.sqlite(code: -1, message: message)
        }
    }
}
