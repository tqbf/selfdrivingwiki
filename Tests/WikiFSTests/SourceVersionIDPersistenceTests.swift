import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Persistence contract tests for `SourceVersionID`. The SQLite schema and raw
/// row payloads remain unchanged; only the Swift namespace crossing the store
/// boundary now distinguishes `source_versions.id` / `parent_id` from
/// `sources.id` and markdown-version `PageID`s.
struct SourceVersionIDPersistenceTests {

    private let currentSchemaVersion = "48"
    private let legacySourceID = "01JSOURCEVERSIONFIXTURE000001"
    private let legacyVersionV1 = "01JSOURCEVERSION000000000001"
    private let legacyVersionV2 = "01JSOURCEVERSION000000000002"
    private let legacyMarkdownVersionID = "01JMARKDOWNVERSION00000000001"
    private let legacyImportActivityID = "01JACTIVITYIMPORT000000000001"
    private let legacyRefreshActivityID = "01JACTIVITYREFRESH0000000001"
    private let legacyExtractActivityID = "01JACTIVITYEXTRACT0000000001"
    private let legacyImportAgentID = "01JAGENTIMPORT000000000000001"
    private let legacyRefreshAgentID = "01JAGENTREFRESH00000000000001"
    private let legacyExtractAgentID = "01JAGENTEXTRACT00000000000001"
    private let legacyBlobV1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let legacyBlobV2 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let legacyMarkdownBlob = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = repositoryRoot()
            .appendingPathComponent("tmp/source-version-id-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    private func withDatabase<T>(at databaseURL: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open source-version fixture database")
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

    private func pragmaValue(_ pragma: String, at databaseURL: URL) throws -> String {
        try #require(try normalizedRows("PRAGMA \(pragma);", at: databaseURL).first)
    }

    private func seedLegacyFixture(at databaseURL: URL) throws {
        let initialStore = try GRDBWikiStore(databaseURL: databaseURL)
        #expect(initialStore.pragmaValue("user_version") == currentSchemaVersion)
        initialStore.close()

        try execute(
            """
            INSERT INTO sources (
                id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
                display_name, content_hash, role
            ) VALUES (
                '\(legacySourceID)', 'legacy-source.html', 'html', 'text/html',
                11, 1000, 1002, 2, 'Legacy Source',
                '\(legacyBlobV2)', 'primary'
            );

            INSERT INTO blobs (hash, byte_size, content) VALUES
                ('\(legacyBlobV1)', 10, X'6F6C642D636F6E74656E74'),
                ('\(legacyBlobV2)', 11, X'6E65772D636F6E74656E7421'),
                ('\(legacyMarkdownBlob)', 10, X'23206C65676163790A');

            INSERT INTO agents (id, kind, name) VALUES
                ('\(legacyImportAgentID)', 'software', 'legacy-import'),
                ('\(legacyRefreshAgentID)', 'software', 'website'),
                ('\(legacyExtractAgentID)', 'software', 'claude');

            INSERT INTO activities (id, kind, agent_id, plan, external_ref, started_at, ended_at) VALUES
                ('\(legacyImportActivityID)', 'import', '\(legacyImportAgentID)', NULL, NULL, 1000, 1000),
                ('\(legacyRefreshActivityID)', 'fetch', '\(legacyRefreshAgentID)', 'https://example.com/legacy', 'https://example.com/legacy', 1002, 1002),
                ('\(legacyExtractActivityID)', 'extract', '\(legacyExtractAgentID)', '{"backend":"anthropic","model":"claude-x"}', NULL, 1003, 1003);

            INSERT INTO source_versions (
                id, source_id, parent_id, blob_hash, mime_type, activity_id, external_identity, fetched_at
            ) VALUES
                ('\(legacyVersionV1)', '\(legacySourceID)', NULL, '\(legacyBlobV1)', 'text/html', '\(legacyImportActivityID)', 'https://example.com/legacy', 1000),
                ('\(legacyVersionV2)', '\(legacySourceID)', '\(legacyVersionV1)', '\(legacyBlobV2)', 'text/html', '\(legacyRefreshActivityID)', 'https://example.com/legacy', 1002);

            INSERT INTO source_markdown_versions (
                id, file_id, parent_id, origin, note, created_at,
                activity_id, source_version_id, blob_hash, mime_type, technique
            ) VALUES (
                '\(legacyMarkdownVersionID)', '\(legacySourceID)', NULL, 'extraction', 'legacy extraction', 1003,
                '\(legacyExtractActivityID)', '\(legacyVersionV2)', '\(legacyMarkdownBlob)', 'text/markdown', 'anthropic'
            );

            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at) VALUES
                ('source-content', '\(legacySourceID)', '\(legacyVersionV2)', 2, 1002),
                ('source-derived', '\(legacySourceID)', '\(legacyMarkdownVersionID)', 1, 1003);
            """,
            at: databaseURL
        )
    }

    @Test func legacySchemaAndRowsRemainRawStringCompatible() throws {
        let databaseURL = try temporaryDatabaseURL()
        try seedLegacyFixture(at: databaseURL)

        #expect(try pragmaValue("user_version", at: databaseURL) == currentSchemaVersion)
        #expect(try normalizedRows(
            """
            SELECT cid, name, type, "notnull", dflt_value, pk
            FROM pragma_table_info('source_versions')
            WHERE name IN ('id', 'parent_id')
            ORDER BY cid;
            """,
            at: databaseURL
        ) == [
            "0|id|TEXT|0|NULL|1",
            "2|parent_id|TEXT|0|NULL|0",
        ])
        #expect(try normalizedRows(
            """
            SELECT cid, name, type, "notnull", dflt_value, pk
            FROM pragma_table_info('source_markdown_versions')
            WHERE name = 'source_version_id';
            """,
            at: databaseURL
        ) == [
            "7|source_version_id|TEXT|0|NULL|0",
        ])
        #expect(try normalizedRows(
            """
            SELECT cid, name, type, "notnull", dflt_value, pk
            FROM pragma_table_info('refs')
            WHERE name = 'version_id';
            """,
            at: databaseURL
        ) == [
            "2|version_id|TEXT|1|NULL|0",
        ])
        #expect(try normalizedRows(
            """
            SELECT id, parent_id, source_id, blob_hash
            FROM source_versions
            WHERE source_id = '\(legacySourceID)'
            ORDER BY id;
            """,
            at: databaseURL
        ) == [
            "\(legacyVersionV1)|NULL|\(legacySourceID)|\(legacyBlobV1)",
            "\(legacyVersionV2)|\(legacyVersionV1)|\(legacySourceID)|\(legacyBlobV2)",
        ])
        #expect(try normalizedRows(
            """
            SELECT kind, owner_id, version_id, generation
            FROM refs
            WHERE owner_id = '\(legacySourceID)'
            ORDER BY kind;
            """,
            at: databaseURL
        ) == [
            "source-content|\(legacySourceID)|\(legacyVersionV2)|2",
            "source-derived|\(legacySourceID)|\(legacyMarkdownVersionID)|1",
        ])
        #expect(try normalizedRows(
            """
            SELECT id, source_version_id, activity_id, technique
            FROM source_markdown_versions
            WHERE file_id = '\(legacySourceID)';
            """,
            at: databaseURL
        ) == [
            "\(legacyMarkdownVersionID)|\(legacyVersionV2)|\(legacyExtractActivityID)|anthropic",
        ])
    }

    @Test func legacySourceVersionRowsDecodeWithoutMigration() throws {
        let databaseURL = try temporaryDatabaseURL()
        try seedLegacyFixture(at: databaseURL)

        let reopened = try GRDBWikiStore(databaseURL: databaseURL)
        let sourceID = SourceID(rawValue: legacySourceID)
        let active = try #require(try reopened.activeContentVersion(sourceID: sourceID))
        let history = try reopened.contentVersionHistory(sourceID: sourceID)
        let origin = try #require(try reopened.sourceOrigin(sourceID: sourceID))
        let markdownHead = try #require(try reopened.processedMarkdownHead(sourceID: sourceID))

        #expect(active.id == SourceVersionID(rawValue: legacyVersionV2))
        #expect(active.parentID == SourceVersionID(rawValue: legacyVersionV1))
        #expect(history.map(\.id) == [
            SourceVersionID(rawValue: legacyVersionV2),
            SourceVersionID(rawValue: legacyVersionV1),
        ])
        #expect(origin.versionID == SourceVersionID(rawValue: legacyVersionV2))
        #expect(origin.agentName == "website")
        #expect(origin.activityKind == "fetch")
        #expect(origin.plan == "https://example.com/legacy")
        #expect(markdownHead.id == SourceMarkdownVersionID(rawValue: legacyMarkdownVersionID))
        #expect(markdownHead.sourceVersionID == SourceVersionID(rawValue: legacyVersionV2))
        #expect(reopened.pragmaValue("user_version") == currentSchemaVersion)
    }

    @Test func liveSourceVersionWritesPreserveRawSQLiteStrings() throws {
        let databaseURL = try temporaryDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let source = try store.addSource(filename: "live.txt", data: Data("v1".utf8))
        let versionV1 = try #require(try store.activeContentVersion(sourceID: source.id))
        let versionV2 = try store.appendContentVersion(sourceID: source.id, data: Data("v2".utf8))
        let markdown = try store.recordMarkdownExtraction(
            sourceID: source.id,
            content: "# extracted",
            backend: .anthropic,
            sourceVersionID: versionV2.id,
            note: "explicit lineage",
            modelVersion: "claude-x"
        )

        #expect(try normalizedRows(
            """
            SELECT id, parent_id
            FROM source_versions
            WHERE source_id = '\(source.id.rawValue)'
            ORDER BY id;
            """,
            at: databaseURL
        ) == [
            "\(versionV1.id.rawValue)|NULL",
            "\(versionV2.id.rawValue)|\(versionV1.id.rawValue)",
        ])
        #expect(try normalizedRows(
            """
            SELECT kind, version_id
            FROM refs
            WHERE owner_id = '\(source.id.rawValue)'
            ORDER BY kind;
            """,
            at: databaseURL
        ) == [
            "source-content|\(versionV2.id.rawValue)",
        ])
        #expect(try normalizedRows(
            """
            SELECT id, source_version_id
            FROM source_markdown_versions
            WHERE id = '\(markdown.id.rawValue)';
            """,
            at: databaseURL
        ) == [
            "\(markdown.id.rawValue)|\(versionV2.id.rawValue)",
        ])
    }
}
