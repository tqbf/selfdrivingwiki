import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// v37 → v38 migration tests (#634 — drop FTS5).
///
/// Verifies that an existing DB at v37 (with the FTS5 virtual tables + their
/// sync triggers + the `source_search`/`chats_search` sidecars) migrates
/// cleanly to v38 (where all of those are gone because Tantivy is the sole
/// BM25 search path). Also verifies a fresh DB at v38 never creates them in
/// the first place.
struct DropFTS5MigrationTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-drop-fts5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    private func scalarInt(_ db: OpaquePointer?, _ sql: String) -> Int32 {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(stmt, 0)
    }

    private func tableExists(_ db: OpaquePointer?, _ name: String) -> Bool {
        scalarInt(
            db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)';") == 1
    }

    private func triggerExists(_ db: OpaquePointer?, _ name: String) -> Bool {
        scalarInt(
            db, "SELECT 1 FROM sqlite_master WHERE type='trigger' AND name='\(name)';") == 1
    }

    /// A fresh DB opens at v38 with NONE of the FTS5 tables/triggers/sidecars.
    @Test func freshDBHasNoFTS5TablesOrTriggers() throws {
        let url = tempDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: url)
        _ = store

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        #expect(scalarInt(db, "PRAGMA user_version;") == 38)

        // FTS5 virtual tables dropped at v38.
        #expect(!tableExists(db, "pages_fts"))
        #expect(!tableExists(db, "sources_fts"))
        #expect(!tableExists(db, "chats_fts"))
        // FTS5 backing sidecars dropped at v38.
        #expect(!tableExists(db, "source_search"))
        #expect(!tableExists(db, "chat_search"))
        // FTS5 sync triggers dropped at v38.
        #expect(!triggerExists(db, "pages_fts_ai"))
        #expect(!triggerExists(db, "pages_fts_ad"))
        #expect(!triggerExists(db, "pages_fts_au"))
        #expect(!triggerExists(db, "sources_fts_ai"))
        #expect(!triggerExists(db, "sources_fts_ad"))
        #expect(!triggerExists(db, "sources_fts_au"))
        #expect(!triggerExists(db, "chats_fts_ai"))
        #expect(!triggerExists(db, "chats_fts_ad"))
        #expect(!triggerExists(db, "chats_fts_au"))

        // The semantic cosine leg (`page_chunks`/`source_chunks`/`chat_chunks`)
        // is unchanged — sqlite-vec stays.
        #expect(tableExists(db, "page_chunks"))
        #expect(tableExists(db, "source_chunks"))
        #expect(tableExists(db, "chat_chunks"))
    }

    /// An existing v37 DB (with FTS5 tables present) upgrades cleanly to v38
    /// and drops the FTS5 layer. Builds a v37 DB by hand from a fresh DB
    /// (create the FTS5 tables/triggers), stamps it back to v37, then reopens.
    @Test func existingV37DBMigratesAndDropsFTS5() throws {
        let url = tempDatabaseURL()

        // 1. Build a fresh v38 DB (the easy way to get all the v1–v37 tables).
        let store = try GRDBWikiStore(databaseURL: url)
        // Seed a page so the FTS table we create below has a rowid to sync.
        let page = try store.createPage(title: "Drop FTS5 Test")
        try store.updatePage(id: page.id, title: "Drop FTS5 Test", body: "alpha beta gamma")
        _ = store  // keep alive until close
        store.close()

        // 2. Re-open the file with raw sqlite3 and recreate the historical v13
        //    FTS5 layer (the createFreshSchema path skipped it; v38 drops it,
        //    so we have to add it back to prove the DROP runs on upgrade).
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let exec: (String) -> Void = { sql in
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        exec("""
        CREATE VIRTUAL TABLE pages_fts USING fts5(
            title, body_markdown,
            content='pages', content_rowid='rowid',
            tokenize='porter');
        """)
        exec("""
        CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
          INSERT INTO pages_fts(rowid, title, body_markdown)
            VALUES (new.rowid, new.title, new.body_markdown);
        END;
        """)
        exec("INSERT INTO pages_fts(pages_fts) VALUES ('rebuild');")
        // Sanity: the FTS table is populated.
        #expect(scalarInt(db, "SELECT COUNT(*) FROM pages_fts WHERE pages_fts MATCH 'alpha';") == 1)
        // Rewind to v37 so reopening runs the v37→v38 step.
        exec("PRAGMA user_version=37;")
        #expect(scalarInt(db, "PRAGMA user_version;") == 37)

        // 3. Reopen via GRDBWikiStore — runs the migration ladder from v37.
        let reopened = try GRDBWikiStore(databaseURL: url)
        _ = reopened

        // 4. Verify v38 + the FTS5 layer is gone.
        #expect(scalarInt(db, "PRAGMA user_version;") == 38)
        #expect(!tableExists(db, "pages_fts"))
        #expect(!triggerExists(db, "pages_fts_ai"))
        // Content table is untouched.
        #expect(scalarInt(db, "SELECT COUNT(*) FROM pages;") == 1)
        #expect(scalarInt(db, "SELECT COUNT(*) FROM pages WHERE title='Drop FTS5 Test';") == 1)
    }

    /// A DB that never had FTS5 (a fresh fixture stamped to v37) still stamps
    /// v38 idempotently — the DROP IF EXISTS guards make the step a no-op.
    @Test func stampingV38OnFTS5lessDBIsIdempotent() throws {
        let url = tempDatabaseURL()
        let store = try GRDBWikiStore(databaseURL: url)
        _ = store
        store.close()

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        // Rewind to v37 with no FTS5 tables present (the createFreshSchema
        // path never created them).
        sqlite3_exec(db, "PRAGMA user_version=37;", nil, nil, nil)

        let reopened = try GRDBWikiStore(databaseURL: url)
        _ = reopened
        #expect(scalarInt(db, "PRAGMA user_version;") == 38)
        // No FTS5 tables were created in the first place; the DROP IF EXISTS
        // path is a no-op.
        #expect(!tableExists(db, "pages_fts"))
    }
}
