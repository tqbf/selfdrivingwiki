import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// System-prompt singleton tests (v3): the document is seeded on a fresh DB,
/// edits bump the version and advance the change token (so the projected
/// `CLAUDE.md`/`AGENTS.md` refresh), and the v2→3 migration adds + seeds the
/// table while preserving existing pages and ingested files.
struct SystemPromptTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-sysprompt-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func tempStore() throws -> SQLiteWikiStore {
        try SQLiteWikiStore(databaseURL: tempDatabaseURL())
    }

    // MARK: - Seeded default on a fresh DB

    @Test func freshDatabaseSeedsDefaultPrompt() throws {
        let store = try tempStore()
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == 1)
    }

    // MARK: - Update persists + bumps version

    @Test func updatePersistsBodyAndBumpsVersion() throws {
        let url = tempDatabaseURL()
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            try store.updateSystemPrompt(body: "Be concise.")
            let after = try store.getSystemPrompt()
            #expect(after.body == "Be concise.")
            #expect(after.version == 2)   // seeded at 1, +1 on edit
        }
        // Persists across reopen (a new connection).
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let prompt = try reopened.getSystemPrompt()
        #expect(prompt.body == "Be concise.")
        #expect(prompt.version == 2)
    }

    @Test func repeatedEditsKeepBumpingVersion() throws {
        let store = try tempStore()
        try store.updateSystemPrompt(body: "one")
        try store.updateSystemPrompt(body: "two")
        try store.updateSystemPrompt(body: "three")
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == "three")
        #expect(prompt.version == 4)   // 1 (seed) + 3 edits
    }

    // MARK: - Change token advances on a prompt-only edit

    @Test func changeTokenAdvancesOnSystemPromptEdit() throws {
        let store = try tempStore()
        // No pages, no files: only the system-prompt version moves.
        #expect(try store.changeToken() == "0:0:0:0:1:0:1")
        try store.updateSystemPrompt(body: "edited")
        #expect(try store.changeToken() == "0:0:0:0:2:0:1")
    }

    // MARK: - UPSERT recreates a missing singleton row (defensive)

    @Test func updateRecreatesRowIfDeleted() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)

        // Hard-delete the seeded row via a raw connection.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "DELETE FROM system_prompt;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // With no row, getSystemPrompt falls back to the default (version 0).
        #expect(try store.getSystemPrompt().version == 0)

        // UPSERT recreates it at version 1.
        try store.updateSystemPrompt(body: "rebuilt")
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == "rebuilt")
        #expect(prompt.version == 1)
    }

    // MARK: - v2 → v3 migration (table added + seeded, data preserved)

    @Test func migratesV2DatabaseToV3PreservingData() throws {
        let url = tempDatabaseURL()

        // Build a v2-shaped DB by hand: pages + slug index + ingested_files +
        // user_version=2, WITHOUT system_prompt. Seed one page and one file.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let v2SQL = """
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
        INSERT INTO pages (id, title, slug, body_markdown, created_at, updated_at, version)
          VALUES ('01PRESERVEDPAGE0000000000', 'Kept', 'kept', '# kept', 1, 1, 1);
        INSERT INTO ingested_files (id, filename, ext, mime_type, byte_size, content, created_at, updated_at, version)
          VALUES ('01PRESERVEDFILE0000000000', 'keep.txt', 'txt', 'text/plain', 4, x'6b656570', 1, 1, 1);
        PRAGMA user_version=2;
        """
        #expect(sqlite3_exec(raw, v2SQL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(raw)

        // Open via the store → runs the v2→3 step (and the later v3→4 + v4→5
        // steps up to head).
        let store = try SQLiteWikiStore(databaseURL: url)

        // system_prompt now exists, seeded with the default.
        let prompt = try store.getSystemPrompt()
        #expect(prompt.body == SystemPrompt.defaultBody)
        #expect(prompt.version == 1)

        // Pre-existing page + ingested file are intact.
        let page = try store.getPage(id: PageID(rawValue: "01PRESERVEDPAGE0000000000"))
        #expect(page.title == "Kept")
        let file = try store.getIngestedFile(id: PageID(rawValue: "01PRESERVEDFILE0000000000"))
        #expect(file.filename == "keep.txt")
        #expect(try store.ingestedFileContent(id: file.id) == Data("keep".utf8))

        // user_version is now 5 (migration runs through every step to head).
        var check: OpaquePointer?
        #expect(sqlite3_open(url.path, &check) == SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 5)
        _ = store
    }
}
