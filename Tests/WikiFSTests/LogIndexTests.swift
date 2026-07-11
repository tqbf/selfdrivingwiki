import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// Phase B store + rendering tests: the v3→4 (`log`) and v4→5 (`wiki_index`)
/// migrations preserve prior data and seed the index default; `appendLog` writes
/// a correct row and `LogRenderer` produces the grep-able `log.md` lines;
/// `updateWikiIndex` UPSERTs (version bumps, body persists, recreates a deleted
/// row); and the change token advances on a log-only AND an index-only write (the
/// load-bearing regression — else the projected `log.md` / `index.md` would never
/// refresh).
struct LogIndexTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-logindex-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    // MARK: - Seeded defaults on a fresh DB

    @Test func freshDatabaseSeedsDefaultIndexAndEmptyLog() throws {
        let store = try tempStore()
        let index = try store.getWikiIndex()
        #expect(index.body == WikiIndex.defaultBody)
        #expect(index.version == 1)
        #expect(try store.listAllLogEntriesOrderedByID().isEmpty)
    }

    // MARK: - log append

    @Test func appendLogWritesRowWithCorrectFields() throws {
        let store = try tempStore()
        let entry = try store.appendLog(kind: .ingest, title: "Article Title", note: "a note")
        #expect(entry.kind == .ingest)
        #expect(entry.title == "Article Title")
        #expect(entry.note == "a note")

        let all = try store.listAllLogEntriesOrderedByID()
        #expect(all.count == 1)
        #expect(all[0].id == entry.id)
        #expect(all[0].kind == .ingest)
        #expect(all[0].title == "Article Title")
        #expect(all[0].note == "a note")
    }

    @Test func appendLogPersistsNilNoteAsAbsent() throws {
        let store = try tempStore()
        _ = try store.appendLog(kind: .query, title: "no note here", note: nil)
        let all = try store.listAllLogEntriesOrderedByID()
        #expect(all.count == 1)
        #expect(all[0].note == nil)
    }

    @Test func logEntriesOrderChronologicallyByULID() throws {
        let store = try tempStore()
        _ = try store.appendLog(kind: .ingest, title: "first", note: nil)
        _ = try store.appendLog(kind: .lint, title: "second", note: nil)
        _ = try store.appendLog(kind: .query, title: "third", note: nil)
        let all = try store.listAllLogEntriesOrderedByID()
        #expect(all.map(\.title) == ["first", "second", "third"])
    }

    // MARK: - log.md rendering (grep-able prefix format)

    @Test func renderProducesGrepablePrefixLines() throws {
        // A fixed UTC date so the "[YYYY-MM-DD]" stamp is deterministic.
        let date = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15 UTC
        let entries = [
            LogEntry(id: PageID(rawValue: "01A"), timestamp: date, kind: .ingest,
                     title: "Article Title", note: nil),
            LogEntry(id: PageID(rawValue: "01B"), timestamp: date, kind: .query,
                     title: "\"How does X compare to Y?\"", note: "answered as a page"),
        ]
        let rendered = LogRenderer.render(entries)

        // The doc's recipe `grep "^## \[" log.md` must match each heading line.
        let headings = rendered.split(separator: "\n").filter { $0.hasPrefix("## [") }
        #expect(headings.count == 2)
        #expect(rendered.contains("## [2025-06-15] ingest | Article Title"))
        #expect(rendered.contains("## [2025-06-15] query | \"How does X compare to Y?\""))
        // The note rides on its own line under the heading.
        #expect(rendered.contains("answered as a page"))
    }

    @Test func renderEmptyLogIsEmptyDocument() {
        #expect(LogRenderer.render([]).isEmpty)
    }

    @MainActor
    @Test func modelCurrentLogMarkdownUsesProjectionRenderer() throws {
        let store = try tempStore()
        _ = try store.appendLog(kind: .query, title: "What changed?", note: "The agent answered from the wiki.")
        let model = WikiStoreModel(store: store)
        let markdown = model.currentLogMarkdown()

        #expect(markdown.contains("## ["))
        #expect(markdown.contains("query | What changed?"))
        #expect(markdown.contains("The agent answered from the wiki."))
    }

    // MARK: - index set (UPSERT)

    @Test func updateWikiIndexPersistsAndBumpsVersion() throws {
        let url = tempDatabaseURL()
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            try store.updateWikiIndex(body: "# My Catalog")
            let after = try store.getWikiIndex()
            #expect(after.body == "# My Catalog")
            #expect(after.version == 2)  // seeded at 1, +1 on write
        }
        // Persists across reopen.
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let index = try reopened.getWikiIndex()
        #expect(index.body == "# My Catalog")
        #expect(index.version == 2)
    }

    @Test func repeatedIndexWritesKeepBumpingVersion() throws {
        let store = try tempStore()
        try store.updateWikiIndex(body: "one")
        try store.updateWikiIndex(body: "two")
        try store.updateWikiIndex(body: "three")
        let index = try store.getWikiIndex()
        #expect(index.body == "three")
        #expect(index.version == 4)  // 1 (seed) + 3 writes
    }

    @Test func updateWikiIndexRecreatesRowIfDeleted() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)

        // Hard-delete the seeded row via a raw connection.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "DELETE FROM wiki_index;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // With no row, getWikiIndex falls back to the default (version 0).
        #expect(try store.getWikiIndex().version == 0)

        // UPSERT recreates it at version 1.
        try store.updateWikiIndex(body: "rebuilt")
        let index = try store.getWikiIndex()
        #expect(index.body == "rebuilt")
        #expect(index.version == 1)
    }

    // MARK: - changeToken folds (the load-bearing regression)

    @Test func changeTokenAdvancesOnLogOnlyWrite() throws {
        let store = try tempStore()
        // Fresh DB: no pages/files, system_prompt + wiki_index at v1, no log rows.
        #expect(try store.changeToken() == "0:0:0:0:1:0:1:0:0:0:0:0:0:0")
        // Appending ONLY a log entry must still advance the token (logCount fold).
        _ = try store.appendLog(kind: .ingest, title: "x", note: nil)
        #expect(try store.changeToken() == "0:0:0:0:1:1:1:0:0:0:0:0:0:0")
        _ = try store.appendLog(kind: .lint, title: "y", note: nil)
        #expect(try store.changeToken() == "0:0:0:0:1:2:1:0:0:0:0:0:0:0")
    }

    @Test func changeTokenAdvancesOnIndexOnlyWrite() throws {
        let store = try tempStore()
        #expect(try store.changeToken() == "0:0:0:0:1:0:1:0:0:0:0:0:0:0")
        // Editing ONLY the index must still advance the token (idxVersion fold).
        try store.updateWikiIndex(body: "edited")
        #expect(try store.changeToken() == "0:0:0:0:1:0:2:0:0:0:0:0:0:0")
    }

    // MARK: - v3 → v4 → v5 migration (preserves prior data, seeds index)

    @Test func migratesV3DatabaseToV5PreservingData() throws {
        let url = tempDatabaseURL()

        // Build a v3-shaped DB by hand: pages + slug index + sources +
        // system_prompt + user_version=3, WITHOUT log / wiki_index. Seed one page,
        // one file, and a non-default system_prompt body so we can prove all three
        // ride through the v3→4→5 steps untouched.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let v3SQL = """
        CREATE TABLE pages (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, slug TEXT NOT NULL,
            body_markdown TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL,
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1);
        CREATE UNIQUE INDEX pages_slug_unique ON pages(slug);
        CREATE TABLE ingested_files (
            id TEXT PRIMARY KEY, filename TEXT NOT NULL, ext TEXT NOT NULL DEFAULT '',
            mime_type TEXT, byte_size INTEGER NOT NULL, content BLOB NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1);
        CREATE INDEX ingested_files_created ON ingested_files(created_at);
        CREATE TABLE system_prompt (
            id INTEGER PRIMARY KEY CHECK (id = 1), body_markdown TEXT NOT NULL DEFAULT '',
            updated_at REAL NOT NULL, version INTEGER NOT NULL DEFAULT 1);
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
          VALUES ('01PRESERVEDPAGE0000000000', 'Kept', 'kept', '# kept', 1, 1, 1);
        INSERT INTO ingested_files (id, filename, ext, mime_type, byte_size, content, created_at, updated_at, version)
          VALUES ('01PRESERVEDFILE0000000000', 'keep.txt', 'txt', 'text/plain', 4, x'6b656570', 1, 1, 1);
        INSERT INTO system_prompt (id, body_markdown, updated_at, version)
          VALUES (1, 'kept prompt', 1, 7);
        PRAGMA user_version=3;
        """
        #expect(sqlite3_exec(raw, v3SQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // Open via the store → runs ONLY the v3→4 + v4→5 steps.
        let store = try SQLiteWikiStore(databaseURL: url)

        // wiki_index now exists, seeded with the default; log exists and is empty.
        let index = try store.getWikiIndex()
        #expect(index.body == WikiIndex.defaultBody)
        #expect(index.version == 1)
        #expect(try store.listAllLogEntriesOrderedByID().isEmpty)

        // Pre-existing page, ingested file, AND system_prompt are intact.
        let page = try store.getPage(id: PageID(rawValue: "01PRESERVEDPAGE0000000000"))
        #expect(page.title == "Kept")
        let file = try store.getSource(id: PageID(rawValue: "01PRESERVEDFILE0000000000"))
        #expect(file.filename == "keep.txt")
        #expect(try store.sourceContent(id: file.id) == Data("keep".utf8))
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == "kept prompt")
        #expect(prompt.version == 7)

        // user_version advances through every migration step to head (v9).
        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 32)
        _ = store
    }
}
