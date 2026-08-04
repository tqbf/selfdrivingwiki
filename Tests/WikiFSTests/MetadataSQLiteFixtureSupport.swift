import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
@testable import WikiFSCore

/// File-backed metadata fixtures deliberately use SQLite directly only at the
/// persistence boundary: they create legacy/corrupt states that public typed
/// APIs correctly make unrepresentable.
enum MetadataSQLiteFixtureSupport {
    static func fileURL(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent("tmp/\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    static func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open SQLite metadata fixture")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            let message = database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "unknown"
            throw WikiStoreError.sqlite(code: -1, message: message)
        }
    }

    /// Executes a deliberately-invalid fixture statement and returns SQLite's
    /// primary result code. Constraint tests use this instead of disabling
    /// enforcement or inferring behavior from `sqlite_master` text.
    static func executeResult(_ sql: String, at url: URL) throws -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open SQLite metadata fixture")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        return sqlite3_exec(database, sql, nil, nil, nil)
    }

    static func scalar(_ sql: String, at url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open SQLite metadata fixture")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WikiStoreError.sqlite(code: -1, message: "could not prepare SQLite metadata scalar")
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_finalize(statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw WikiStoreError.sqlite(code: -1, message: "missing SQLite metadata scalar")
        }
        return String(cString: value)
    }

    static func prepareV47(
        at url: URL,
        classificationFixture: ChatTurnsSchemaClassificationFixture = .exactV47
    ) throws {
        let fresh = try GRDBWikiStore(databaseURL: url)
        fresh.close()
        try SchemaV48FixtureFactory.apply(classificationFixture, at: url)
    }

    static func prepareV48(at url: URL) throws {
        let fresh = try GRDBWikiStore(databaseURL: url)
        fresh.close()
        try execute("""
        DROP TABLE IF EXISTS renderer_event_checkpoints;
        DROP TABLE IF EXISTS renderer_event_cursors;
        DROP INDEX IF EXISTS renderer_event_process_leases_subsystem;
        DROP TABLE IF EXISTS renderer_event_process_leases;
        DROP INDEX IF EXISTS renderer_event_journal_scope_sequence;
        DROP TABLE IF EXISTS renderer_event_journal;
        DROP TABLE IF EXISTS renderer_event_sequence;
        DROP INDEX IF EXISTS renderer_source_preferences_package;
        DROP TABLE IF EXISTS renderer_source_preferences;
        DROP TABLE IF EXISTS renderer_wiki_enablement;
        PRAGMA user_version = 48;
        """, at: url)
    }
}

enum ChatTurnsSchemaClassificationFixture: CaseIterable {
    case exactV47
    case exactV48
    case partialChatTurnsShape
    case unknownChatTurnsDefinition
}

/// Produces migration input from the production v47 definition, then derives
/// its expected classification with the production classifier. No test labels
/// a SQL shape independently of the code that will migrate it.
enum SchemaV48FixtureFactory {
    static func apply(_ fixture: ChatTurnsSchemaClassificationFixture, at url: URL) throws {
        let definition: String
        switch fixture {
        case .exactV47:
            definition = GRDBWikiStore.chatTurnsV47CreateSQL
        case .exactV48:
            definition = GRDBWikiStore.chatTurnsV48CreateSQL.replacingOccurrences(
                of: "chat_turns_v48", with: "chat_turns"
            )
        case .partialChatTurnsShape:
            definition = GRDBWikiStore.chatTurnsV47CreateSQL.replacingOccurrences(
                of: "PRIMARY KEY (chat_id, turn_id)",
                with: "provider_id TEXT, PRIMARY KEY (chat_id, turn_id)"
            )
        case .unknownChatTurnsDefinition:
            definition = "CREATE TABLE chat_turns (id TEXT PRIMARY KEY, note TEXT NOT NULL);"
        }
        try MetadataSQLiteFixtureSupport.execute("""
        DROP TABLE IF EXISTS page_version_sources;
        DROP TABLE IF EXISTS workspace_ref_sources;
        DROP TABLE chat_turns;
        \(definition)
        PRAGMA user_version = 47;
        """, at: url)
    }

    static func classification(at url: URL) throws -> GRDBWikiStore.ChatTurnsSchemaClassification {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open SQLite metadata fixture")
        }
        defer { sqlite3_close(database) }
        var columns: Set<String> = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(chat_turns)", -1, &statement, nil) == SQLITE_OK else {
            throw WikiStoreError.sqlite(code: -1, message: "could not inspect chat_turns")
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_finalize(statement)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        let sql = try scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'chat_turns'", database: database)
        return GRDBWikiStore.classifyChatTurnsSchema(
            columns: columns, normalizedSQL: GRDBWikiStore.normalizedSchemaSQL(sql)
        )
    }

    private static func scalar(_ sql: String, database: OpaquePointer?) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WikiStoreError.sqlite(code: -1, message: "could not inspect schema SQL")
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_finalize(statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw WikiStoreError.sqlite(code: -1, message: "missing schema SQL")
        }
        return String(cString: value)
    }
}
