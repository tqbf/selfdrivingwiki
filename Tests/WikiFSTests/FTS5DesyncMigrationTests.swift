import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Regression tests for the FTS5 desync that made pre-v38 wikis unopenable.
///
/// `pages_fts` is an external-content FTS5 index over `pages`. Its
/// `pages_fts_au` trigger issues an FTS `'delete'` carrying the OLD row values;
/// when the index rows do not match the content table, FTS5 raises
/// `SQLITE_CORRUPT` ("database disk image is malformed") even though
/// `PRAGMA integrity_check` reports `ok` and no page content is damaged.
///
/// Before #634 an on-open `rebuildFTS()` resynced the index and hid any drift.
/// #634 removed that rebuild but left the v12→v13 step creating the triggers and
/// the v37→v38 step dropping them — so every ladder step in between ran against
/// a live, unrepaired trigger. Any such step that writes `pages` died, the
/// `user_version` stamp never landed, and the wiki could not be opened at all
/// (including for read-only commands, because the store migrates on open).
///
/// The fix drops the dead FTS5 objects in a pre-flight before ladder step 1, and
/// stops the v12→v13 step re-creating them. These tests pin both halves.
struct FTS5DesyncMigrationTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-fts5-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Run raw SQL on a closed DB file, bypassing the store — the same bypass
    /// `Phase5StoreCanonicalizationTests.buildRewoundV22DB()` uses to stage
    /// states the store's own API cannot produce.
    private func executeRaw(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) } ?? ""
        if message != nil { sqlite3_free(message) }
        #expect(rc == SQLITE_OK, "raw SQL failed (\(rc)): \(detail)")
    }

    private func scalar(_ sql: String, at url: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    /// The SQL the v12→v13 step used to run: an external-content `pages_fts`
    /// plus its three sync triggers. Created EMPTY and never rebuilt, which is
    /// precisely the desynced state — every `pages` row is missing from the
    /// index, so the first `UPDATE pages` fires an FTS `'delete'` that finds no
    /// matching index row.
    private static let legacyPagesFTSSQL = """
    CREATE VIRTUAL TABLE pages_fts USING fts5(
        title, body_markdown,
        content='pages', content_rowid='rowid',
        tokenize='porter');
    CREATE TRIGGER pages_fts_ai AFTER INSERT ON pages BEGIN
      INSERT INTO pages_fts(rowid, title, body_markdown)
        VALUES (new.rowid, new.title, new.body_markdown);
    END;
    CREATE TRIGGER pages_fts_ad AFTER DELETE ON pages BEGIN
      INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
        VALUES ('delete', old.rowid, old.title, old.body_markdown);
    END;
    CREATE TRIGGER pages_fts_au AFTER UPDATE ON pages BEGIN
      INSERT INTO pages_fts(pages_fts, rowid, title, body_markdown)
        VALUES ('delete', old.rowid, old.title, old.body_markdown);
      INSERT INTO pages_fts(rowid, title, body_markdown)
        VALUES (new.rowid, new.title, new.body_markdown);
    END;
    """

    /// Build a current-schema DB carrying one page with an uncanonicalized
    /// body, then rewind it to a pre-v38 `user_version` and re-plant a desynced
    /// `pages_fts`. Reopening must run the ladder from `version` upward with the
    /// broken index in place — the exact shape of the wikis found in the field
    /// (stamped v17 and v22, all with `pages_fts` present).
    private func buildDesyncedDB(rewoundTo version: Int) throws -> (url: URL, linkerID: PageID, targetID: PageID) {
        let url = tempDatabaseURL()
        let targetID: PageID
        let linkerID: PageID
        do {
            let store = try GRDBWikiStore(databaseURL: url)
            targetID = try PageUpsert.upsert(in: store, id: nil, title: "Target", body: "").id
            let linker = try store.createPage(title: "Linker")
            // Raw updatePage (no canonicalization) plants a legacy body, so the
            // v22→v23 sweep has real work to do and actually issues the
            // `UPDATE pages` that trips the trigger.
            try store.updatePage(id: linker.id, title: "Linker", body: "See [[Target]].")
            linkerID = linker.id
        } // store deinit closes the connection
        try executeRaw(Self.legacyPagesFTSSQL + "\nPRAGMA user_version=\(version);", at: url)
        return (url, linkerID, targetID)
    }

    /// The headline repro: a v22 DB with a desynced index opens and finishes the
    /// ladder instead of dying with "database disk image is malformed".
    @Test func desyncedPagesFTSAtV22StillMigrates() throws {
        let (url, linkerID, targetID) = try buildDesyncedDB(rewoundTo: 22)

        let reopened = try GRDBWikiStore(databaseURL: url)

        #expect(reopened.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        // The v22→v23 sweep ran to completion — this is the write that used to
        // raise SQLITE_CORRUPT through `pages_fts_au`.
        let migrated = try reopened.getPage(id: linkerID)
        #expect(migrated.bodyMarkdown.contains("[[page:\(targetID.rawValue)|Target]]"))
    }

    /// The v17 DBs found in the field die earlier in the ladder (the v17→v18
    /// name sanitize writes rows before v22→v23 ever runs), so pin that entry
    /// point too — a fix that only guarded the v23 step would leave these broken.
    @Test func desyncedPagesFTSAtV17StillMigrates() throws {
        let (url, linkerID, targetID) = try buildDesyncedDB(rewoundTo: 17)

        let reopened = try GRDBWikiStore(databaseURL: url)

        #expect(reopened.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        let migrated = try reopened.getPage(id: linkerID)
        #expect(migrated.bodyMarkdown.contains("[[page:\(targetID.rawValue)|Target]]"))
    }

    /// Page content was never damaged — the fault was confined to the derived
    /// index. Migrating must not drop or truncate any page.
    @Test func migrationPreservesPageContent() throws {
        let (url, linkerID, targetID) = try buildDesyncedDB(rewoundTo: 22)

        let reopened = try GRDBWikiStore(databaseURL: url)

        #expect(try reopened.getPage(id: targetID).title == "Target")
        #expect(try reopened.getPage(id: linkerID).title == "Linker")
        #expect(scalar("SELECT count(*) FROM pages;", at: url) == "2")
    }

    /// After migrating, no FTS5 virtual table or sync trigger survives. This is
    /// what makes the wiki stay fixed: a leftover trigger would re-break the
    /// next `UPDATE pages`.
    @Test func migrationLeavesNoFTS5ObjectsBehind() throws {
        let (url, _, _) = try buildDesyncedDB(rewoundTo: 22)

        _ = try GRDBWikiStore(databaseURL: url)

        let survivors = scalar("""
        SELECT COALESCE(group_concat(name), '') FROM sqlite_master
         WHERE name IN ('pages_fts', 'sources_fts', 'chats_fts',
                        'pages_fts_ai', 'pages_fts_ad', 'pages_fts_au',
                        'sources_fts_ai', 'sources_fts_ad', 'sources_fts_au',
                        'chats_fts_ai', 'chats_fts_ad', 'chats_fts_au');
        """, at: url)
        #expect(survivors == "")
    }

    /// WHY the v12→v13 step must no longer create `pages_fts`: a freshly-created
    /// external-content FTS5 index is EMPTY, so it is desynced from a populated
    /// `pages` by construction. This test pins the hazard itself — the first
    /// `UPDATE pages` after such a create raises `SQLITE_CORRUPT`, exactly the
    /// failure the field DBs hit.
    ///
    /// The pre-flight drop alone would NOT save a DB entering the ladder at or
    /// below v12, because the v13 re-create happens after the pre-flight runs.
    /// That is why the fix removes the create as well as adding the drop.
    @Test func freshlyCreatedExternalContentIndexBreaksTheNextPageWrite() throws {
        let url = tempDatabaseURL()
        do {
            let store = try GRDBWikiStore(databaseURL: url)
            _ = try store.createPage(title: "Target")
        }
        // Recreate exactly what the v13 step used to do, and nothing else — no
        // rebuild, matching the post-#634 world where `rebuildFTS()` is gone.
        try executeRaw(Self.legacyPagesFTSSQL, at: url)

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let rc = sqlite3_exec(db, "UPDATE pages SET title = 'Renamed';", nil, nil, nil)

        #expect(rc == SQLITE_CORRUPT,
                "an empty external-content pages_fts must poison the next UPDATE (got rc \(rc))")
    }

    /// `source_search` is NOT derived FTS state — it is an ordinary content
    /// sidecar still written by `upsertSourceSearch`/`renameSource`, so trimming
    /// the FTS5 half of the v12→v13 step must leave the sidecar in place.
    @Test func sourceSearchSidecarSurvivesTheFTS5Trim() throws {
        let (url, _, _) = try buildDesyncedDB(rewoundTo: 22)

        _ = try GRDBWikiStore(databaseURL: url)

        let sidecar = scalar(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='source_search';", at: url)
        #expect(sidecar == "1")
    }

    /// Reopening a repaired DB is a no-op, not a second migration.
    @Test func reopenAfterRepairIsIdempotent() throws {
        let (url, linkerID, _) = try buildDesyncedDB(rewoundTo: 22)

        let first = try GRDBWikiStore(databaseURL: url)
        let bodyAfterFirst = try first.getPage(id: linkerID).bodyMarkdown
        let versionAfterFirst = try first.getPage(id: linkerID).version

        let second = try GRDBWikiStore(databaseURL: url)
        #expect(try second.getPage(id: linkerID).bodyMarkdown == bodyAfterFirst)
        #expect(try second.getPage(id: linkerID).version == versionAfterFirst)
    }
}
