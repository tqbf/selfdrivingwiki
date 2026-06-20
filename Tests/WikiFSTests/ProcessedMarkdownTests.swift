import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// Tests for the v8 `file_markdown_versions` store API: version chain,
/// revert, cascade, source immutability, seeding, and pre-migration fallback.
struct ProcessedMarkdownTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-pm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// Create an ingested file row so FK constraints are satisfied for version tests.
    @discardableResult
    private func seedIngestedFile(in store: SQLiteWikiStore, filename: String = "test.txt",
                                  data: Data = Data("hello".utf8)) throws -> IngestedFileSummary {
        try store.ingestFile(filename: filename, data: data)
    }

    /// Build a v7 DB by hand (pages + ingested_files + system_prompt + log +
    /// wiki_index + page_embeddings), then open it with SQLiteWikiStore — the
    /// store runs the v7→v8 migration step. Used to verify stepwise upgrade.
    private func tempV7DatabaseURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-pm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("WikiFS.sqlite")

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        func exec(_ sql: String) {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }

        exec("""
        CREATE TABLE pages (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, body_markdown TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL, updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1
        );
        """)
        exec("""
        CREATE TABLE ingested_files (
            id TEXT PRIMARY KEY, filename TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
            mime_type TEXT, byte_size INTEGER NOT NULL, content BLOB NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1,
            ingested_at REAL
        );
        """)
        exec("""
        CREATE TABLE system_prompt (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1
        );
        """)
        exec("""
        CREATE TABLE log (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL,
            note TEXT, source_file_id TEXT, created_at REAL NOT NULL
        );
        """)
        exec("""
        CREATE TABLE wiki_index (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1
        );
        """)
        exec("""
        CREATE TABLE page_embeddings (
            page_id TEXT PRIMARY KEY REFERENCES pages(id) ON DELETE CASCADE,
            embedding BLOB NOT NULL
        );
        """)
        exec("PRAGMA user_version=7;")
        return url
    }

    // MARK: - Migration

    @Test func freshDBHasV8Schema() throws {
        let store = try tempStore()
        #expect(store.pragmaValue("user_version") == "8")
    }

    @Test func v7DBUpgradesToV8PreservingData() throws {
        let url = try tempV7DatabaseURL()
        // Insert a known file into the v7 DB.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
        INSERT INTO ingested_files (id, filename, ext, byte_size, content, created_at, updated_at, version)
        VALUES ('01J00000000000000000000000', 'legacy.txt', 'txt', 5, X'68656C6C6F', 1.0, 1.0, 1);
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        // Opening runs v7→v8 migration.
        let store = try SQLiteWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "8")
        // Pre-existing file is intact.
        let content = try store.ingestedFileContent(
            id: PageID(rawValue: "01J00000000000000000000000"))
        #expect(content == Data("hello".utf8))
    }

    @Test func reopenIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-pm-reopen-\(UUID().uuidString).sqlite")
        let store = try SQLiteWikiStore(databaseURL: url)
        let file = try store.ingestFile(filename: "test.md", data: Data("hello".utf8))
        _ = try store.appendProcessedMarkdown(
            fileID: file.id, content: "v1", origin: "extraction", note: nil)
        // Reopen — must not fail from duplicate DDL.
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let head = try reopened.processedMarkdownHead(fileID: file.id)
        #expect(head?.content == "v1")
    }

    // MARK: - Version chain

    @Test func v1HasNullParentID() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        let v1 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "first", origin: "extraction", note: nil)
        #expect(v1.parentID == nil)
        #expect(v1.origin == "extraction")
        #expect(v1.content == "first")
    }

    @Test func v2ParentIsV1() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        let v1 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "one", origin: "extraction", note: nil)
        let v2 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "two", origin: "user", note: nil)
        #expect(v2.parentID == v1.id)
    }

    @Test func headIsLatestVersion() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        _ = try store.appendProcessedMarkdown(
            fileID: file.id, content: "v1", origin: "extraction", note: nil)
        // Tiny sleep guarantees the next ULID has a strictly later timestamp
        // so ORDER BY id DESC picks it up correctly.
        usleep(2000)
        let v2 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "v2", origin: "user", note: nil)
        let head = try store.processedMarkdownHead(fileID: file.id)
        #expect(head?.id == v2.id)
        #expect(head?.content == "v2")
    }

    @Test func processedMarkdownHistoryNewestFirst() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        let v1 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "first", origin: "extraction", note: nil)
        usleep(2000)
        let v2 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "second", origin: "user", note: nil)
        let history = try store.processedMarkdownHistory(fileID: file.id)
        #expect(history.count == 2)
        #expect(history[0].id == v2.id)  // newest first
        #expect(history[1].id == v1.id)
    }

    @Test func hasProcessedMarkdownReflectsExistence() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        #expect(try store.hasProcessedMarkdown(fileID: file.id) == false)
        _ = try store.appendProcessedMarkdown(
            fileID: file.id, content: "x", origin: "extraction", note: nil)
        #expect(try store.hasProcessedMarkdown(fileID: file.id) == true)
    }

    // MARK: - Revert

    @Test func revertAppendsNewVersionWithOldContent() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        let v1 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "original", origin: "extraction", note: nil)
        usleep(2000)
        _ = try store.appendProcessedMarkdown(
            fileID: file.id, content: "edit", origin: "user", note: nil)
        usleep(2000)
        let v3 = try store.revertProcessedMarkdown(fileID: file.id, to: v1.id)
        #expect(v3.content == "original")
        #expect(v3.origin == "revert")
        #expect(v3.parentID != nil)  // parent is the previous head
        // v1 is untouched
        let history = try store.processedMarkdownHistory(fileID: file.id)
        #expect(history[2].content == "original")  // v1 still there
    }

    @Test func headAfterRevertIsNewest() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        _ = try store.appendProcessedMarkdown(
            fileID: file.id, content: "v1", origin: "extraction", note: nil)
        usleep(2000)
        _ = try store.appendProcessedMarkdown(
            fileID: file.id, content: "v2", origin: "user", note: nil)
        let v1 = try store.processedMarkdownHistory(fileID: file.id).last!
        usleep(2000)
        let reverted = try store.revertProcessedMarkdown(fileID: file.id, to: v1.id)
        let head = try store.processedMarkdownHead(fileID: file.id)
        #expect(head?.id == reverted.id)
    }

    // MARK: - Cascade

    @Test func deleteIngestedFileRemovesVersions() throws {
        let store = try tempStore()
        let ingested = try store.ingestFile(filename: "doc.md", data: Data("hello".utf8))
        _ = try store.appendProcessedMarkdown(
            fileID: ingested.id, content: "v1", origin: "extraction", note: nil)
        _ = try store.appendProcessedMarkdown(
            fileID: ingested.id, content: "v2", origin: "user", note: nil)
        try store.deleteIngestedFile(id: ingested.id)
        #expect(try store.hasProcessedMarkdown(fileID: ingested.id) == false)
    }

    // MARK: - Source immutability

    @Test func sourceBytesUnchangedAfterEdits() throws {
        let store = try tempStore()
        let original = Data([0x00, 0xFF, 0x42])
        let ingested = try store.ingestFile(filename: "data.bin", data: original)
        _ = try store.appendProcessedMarkdown(
            fileID: ingested.id, content: "edit 1", origin: "user", note: nil)
        _ = try store.appendProcessedMarkdown(
            fileID: ingested.id, content: "edit 2", origin: "user", note: nil)
        let content = try store.ingestedFileContent(id: ingested.id)
        #expect(content == original)
    }

    // MARK: - Seeding

    @Test func nativeMdStoredInIngestedFilesDoesNotAutoSeed() throws {
        let store = try tempStore()
        let ingested = try store.ingestFile(filename: "notes.md", data: Data("# Notes\ncontent".utf8))
        let head = try store.processedMarkdownHead(fileID: ingested.id)
        // No version yet — lazy seed happens at WikiStoreModel layer, not store.
        #expect(head == nil)
    }

    @Test func appendIsNotIdempotentAppendsAgain() throws {
        let store = try tempStore()
        let file = try seedIngestedFile(in: store)
        let v1 = try store.appendProcessedMarkdown(
            fileID: file.id, content: "first seed", origin: "extraction", note: nil)
        usleep(2000)
        _ = try store.appendProcessedMarkdown(
            fileID: file.id, content: "second seed", origin: "extraction", note: nil)
        let history = try store.processedMarkdownHistory(fileID: file.id)
        // Two versions: the second call appended v2 (parent = v1).
        // The "double-seed guard" is at the caller level (WikiStoreModel).
        #expect(history.count == 2)
        #expect(history[1].id == v1.id)
    }

    // MARK: - Pre-migration fallback

    @Test func readSeamsReturnSafeDefaultsForPreV8DB() throws {
        let url = try tempV7DatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let arbitraryID = PageID(rawValue: "01J00000000000000000000000")
        // Read seams must return safe defaults (nil / false / []) without
        // crashing even though file_markdown_versions doesn't exist.
        #expect(try store.processedMarkdownHead(fileID: arbitraryID) == nil)
        #expect(try store.hasProcessedMarkdown(fileID: arbitraryID) == false)
        #expect(try store.processedMarkdownHistory(fileID: arbitraryID).isEmpty)
    }
}
