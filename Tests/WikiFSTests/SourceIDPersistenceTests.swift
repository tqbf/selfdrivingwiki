import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Persistence contract tests for `SourceID`. SQLite continues to contain the
/// legacy raw ULID text; only the Swift value crossing the store boundary is
/// now namespaced.
struct SourceIDPersistenceTests {

    private let legacyRawSourceID = "01HSOURCEIDENTIFIER00000000"

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-id-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WikiFS.sqlite")
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw WikiStoreError.open("could not open source fixture database")
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw WikiStoreError.sqlite(code: -1, message: "could not write source fixture")
        }
    }

    private func insertLegacySourceRow(at databaseURL: URL) throws {
        let now = Date().timeIntervalSince1970
        try execute(
            """
            INSERT INTO sources (id, filename, byte_size, created_at, updated_at, display_name, role)
            VALUES ('\(legacyRawSourceID)', 'legacy-source.pdf', 0, \(now), \(now), 'Legacy source', 'primary');
            """,
            at: databaseURL
        )
    }

    @Test func legacySourceRowsDecodeWithoutMigration() throws {
        let databaseURL = try temporaryDatabaseURL()
        let initialStore = try GRDBWikiStore(databaseURL: databaseURL)
        let schemaVersionBefore = initialStore.pragmaValue("user_version")
        initialStore.close()

        try insertLegacySourceRow(at: databaseURL)

        let reopened = try GRDBWikiStore(databaseURL: databaseURL)
        let source = try #require(try reopened.listSources().first { $0.id.rawValue == legacyRawSourceID })

        #expect(source.id == SourceID(rawValue: legacyRawSourceID))
        #expect(reopened.pragmaValue("user_version") == schemaVersionBefore)
        #expect(schemaVersionBefore == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func sourceWritePreservesRawIdentifier() throws {
        let databaseURL = try temporaryDatabaseURL()
        let initialStore = try GRDBWikiStore(databaseURL: databaseURL)
        initialStore.close()
        try insertLegacySourceRow(at: databaseURL)

        let store = try GRDBWikiStore(databaseURL: databaseURL)
        let sourceID = SourceID(rawValue: legacyRawSourceID)
        try store.setSourceDisplayName(id: sourceID, displayName: "Renamed legacy source")

        #expect(store.scalarText(
            "SELECT id FROM sources WHERE display_name = 'Renamed legacy source';"
        ) == legacyRawSourceID)
        #expect(try store.listSources().contains { $0.id == sourceID })
    }
}
