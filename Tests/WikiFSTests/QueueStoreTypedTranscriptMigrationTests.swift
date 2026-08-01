import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

struct QueueStoreTypedTranscriptMigrationTests {
    @Test func additiveMigrationCreatesTypedTranscriptTableAndKeepsLegacyEventTable() throws {
        let url = try temporaryDatabaseURL()
        let store = try QueueStore(databaseURL: url)
        store.close()

        #expect(try tableExists(named: "queue_item_transcript_items", in: url))
        #expect(try tableExists(named: "queue_item_events", in: url))
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
}
