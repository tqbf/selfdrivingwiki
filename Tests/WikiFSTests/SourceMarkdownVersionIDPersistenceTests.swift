import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Persistence contract tests for `SourceMarkdownVersionID`. The SQLite schema,
/// `PRAGMA user_version`, and stored raw strings remain unchanged while Swift
/// APIs distinguish source entities, source content versions, and source
/// markdown versions.
struct SourceMarkdownVersionIDPersistenceTests {

    private let legacySourceID = "01JSMVSOURCE000000000000001"
    private let legacyPageID = "01JSMVPAGE00000000000000001"
    private let legacySourceVersionID = "01JSMVSRCVER0000000000001"
    private let legacyMarkdownVersionV1 = "01JSMVMDVER00000000000001"
    private let legacyMarkdownVersionV2 = "01JSMVMDVER00000000000002"
    private let legacyActivityID = "01JSMVACTIVITY000000000001"
    private let legacyAgentID = "01JSMVAGENT000000000000001"
    private let legacySourceBlob = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let legacyMarkdownBlobV1 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let legacyMarkdownBlobV2 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = repositoryRoot()
            .appendingPathComponent("tmp/source-markdown-version-id-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    private func withDatabase<T>(at databaseURL: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open source-markdown-version fixture database")
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

    private func seedLegacyFixture(at databaseURL: URL) throws -> String {
        let initialStore = try GRDBWikiStore(databaseURL: databaseURL)
        let schemaVersion = initialStore.pragmaValue("user_version")
        initialStore.close()

        try execute(
            """
            INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
            VALUES ('\(legacyPageID)', 'Legacy Page', 'legacy-page', '# Legacy Page', 1000, 1000, 1);

            INSERT INTO sources (
                id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
                display_name, content_hash, role
            ) VALUES (
                '\(legacySourceID)', 'legacy.pdf', 'pdf', 'application/pdf',
                12, 1000, 1000, 1, 'Legacy Source',
                '\(legacySourceBlob)', 'primary'
            );

            INSERT INTO blobs (hash, byte_size, content) VALUES
                ('\(legacySourceBlob)', 12, X'255044462D312E340A'),
                ('\(legacyMarkdownBlobV1)', 16, X'23204C65676163792076310A0A626F6479'),
                ('\(legacyMarkdownBlobV2)', 17, X'23204C65676163792076320A0A626F647921');

            INSERT INTO agents (id, kind, name) VALUES
                ('\(legacyAgentID)', 'software', 'claude');

            INSERT INTO activities (id, kind, agent_id, plan, started_at, ended_at) VALUES
                ('\(legacyActivityID)', 'extract', '\(legacyAgentID)', '{"backend":"anthropic"}', 1001, 1001);

            INSERT INTO source_versions (
                id, source_id, parent_id, blob_hash, mime_type, activity_id, fetched_at
            ) VALUES (
                '\(legacySourceVersionID)', '\(legacySourceID)', NULL, '\(legacySourceBlob)',
                'application/pdf', '\(legacyActivityID)', 1000
            );

            INSERT INTO source_markdown_versions (
                id, file_id, parent_id, origin, note, created_at,
                activity_id, source_version_id, blob_hash, mime_type, technique
            ) VALUES
                (
                    '\(legacyMarkdownVersionV1)', '\(legacySourceID)', NULL, 'extraction', 'legacy v1', 1002,
                    '\(legacyActivityID)', '\(legacySourceVersionID)', '\(legacyMarkdownBlobV1)', 'text/markdown', 'anthropic'
                ),
                (
                    '\(legacyMarkdownVersionV2)', '\(legacySourceID)', '\(legacyMarkdownVersionV1)', 'revert', 'legacy v2', 1003,
                    '\(legacyActivityID)', '\(legacySourceVersionID)', '\(legacyMarkdownBlobV2)', 'text/markdown', 'anthropic'
                );

            INSERT INTO refs (kind, owner_id, version_id, generation, updated_at) VALUES
                ('source-content', '\(legacySourceID)', '\(legacySourceVersionID)', 1, 1000),
                ('source-derived', '\(legacySourceID)', '\(legacyMarkdownVersionV2)', 2, 1003);

            INSERT INTO source_links (from_page_id, to_source_id, link_text, role, pinned_version_id)
            VALUES ('\(legacyPageID)', '\(legacySourceID)', 'Legacy Source', 'cite', '\(legacyMarkdownVersionV1)');
            """,
            at: databaseURL
        )

        return schemaVersion
    }

    @Test func schemaUserVersionAndRawIDsAreUnchanged() throws {
        let databaseURL = try temporaryDatabaseURL()
        let schemaVersion = try seedLegacyFixture(at: databaseURL)

        let reopened = try GRDBWikiStore(databaseURL: databaseURL)
        #expect(reopened.pragmaValue("user_version") == schemaVersion)
        reopened.close()

        #expect(try normalizedRows(
            """
            SELECT cid, name, type, "notnull", dflt_value, pk
            FROM pragma_table_info('source_markdown_versions')
            WHERE name IN ('id', 'parent_id', 'source_version_id')
            ORDER BY cid;
            """,
            at: databaseURL
        ) == [
            "0|id|TEXT|0|NULL|1",
            "2|parent_id|TEXT|0|NULL|0",
            "7|source_version_id|TEXT|0|NULL|0",
        ])

        #expect(try normalizedRows(
            """
            SELECT id, parent_id, file_id, source_version_id
            FROM source_markdown_versions
            WHERE file_id = '\(legacySourceID)'
            ORDER BY id;
            """,
            at: databaseURL
        ) == [
            "\(legacyMarkdownVersionV1)|NULL|\(legacySourceID)|\(legacySourceVersionID)",
            "\(legacyMarkdownVersionV2)|\(legacyMarkdownVersionV1)|\(legacySourceID)|\(legacySourceVersionID)",
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
            "source-content|\(legacySourceID)|\(legacySourceVersionID)|1",
            "source-derived|\(legacySourceID)|\(legacyMarkdownVersionV2)|2",
        ])

        #expect(try normalizedRows(
            """
            SELECT from_page_id, to_source_id, role, pinned_version_id
            FROM source_links
            WHERE from_page_id = '\(legacyPageID)';
            """,
            at: databaseURL
        ) == [
            "\(legacyPageID)|\(legacySourceID)|cite|\(legacyMarkdownVersionV1)",
        ])
    }

    @Test func legacyRowsParentsAndActiveRefRoundTripWithoutMigration() throws {
        let databaseURL = try temporaryDatabaseURL()
        let schemaVersion = try seedLegacyFixture(at: databaseURL)

        let reopened = try GRDBWikiStore(databaseURL: databaseURL)
        let sourceID = SourceID(rawValue: legacySourceID)
        let pageID = PageID(rawValue: legacyPageID)
        let v1 = SourceMarkdownVersionID(rawValue: legacyMarkdownVersionV1)
        let v2 = SourceMarkdownVersionID(rawValue: legacyMarkdownVersionV2)

        let head = try #require(try reopened.processedMarkdownHead(sourceID: sourceID))
        let history = try reopened.processedMarkdownHistory(sourceID: sourceID)
        let singleVersion = try #require(try reopened.processedMarkdownVersion(id: v1))
        let chains = try reopened.sourceDerivedChains()
        let names = try reopened.processedMarkdownAgentNames(sourceID: sourceID)
        let alternatives = try reopened.processedMarkdownAlternatives(sourceID: sourceID)
        let producer = try reopened.processedMarkdownProducer(versionID: v2)
        let pinned = try reopened.sourceLinkPin(from: pageID, to: sourceID)

        #expect(head.id == v2)
        #expect(head.parentID == v1)
        #expect(history.map(\.id) == [v2, v1])
        #expect(singleVersion.id == v1)
        #expect(singleVersion.parentID == nil)
        #expect(singleVersion.sourceID == sourceID)
        #expect(singleVersion.sourceVersionID == SourceVersionID(rawValue: legacySourceVersionID))
        #expect(chains[sourceID] == [v1, v2])
        #expect(names[v1] == "claude")
        #expect(names[v2] == "claude")
        #expect(alternatives.map(\.id) == [v2, v1])
        #expect(alternatives.first?.isActive == true)
        #expect(producer?.name == "claude")
        #expect(pinned == v1)
        #expect(reopened.pragmaValue("user_version") == schemaVersion)
    }

    @Test func liveWritesPreserveTypedMarkdownVersionRawStrings() throws {
        let databaseURL = try temporaryDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let source = try store.addSource(filename: "paper.pdf", data: Data("%PDF-1.4".utf8))
        let v1 = try store.appendProcessedMarkdown(sourceID: source.id, content: "first", origin: .extraction, note: nil)
        let v2 = try store.appendProcessedMarkdown(sourceID: source.id, content: "second", origin: .extraction, note: nil)
        let page = try store.createPage(title: "Paper Notes")
        try store.setActiveMarkdown(sourceID: source.id, to: v2.id)
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.id.rawValue, linkText: "paper", versionPin: "2")
        ])

        #expect(store.scalarText(
            "SELECT parent_id FROM source_markdown_versions WHERE id = '\(v2.id.rawValue)';"
        ) == v1.id.rawValue)
        #expect(store.scalarText(
            "SELECT version_id FROM refs WHERE kind = 'source-derived' AND owner_id = '\(source.id.rawValue)';"
        ) == v2.id.rawValue)
        #expect(store.scalarText(
            "SELECT pinned_version_id FROM source_links WHERE from_page_id = '\(page.id.rawValue)' AND to_source_id = '\(source.id.rawValue)' AND role = 'cite';"
        ) == v2.id.rawValue)
    }
}
