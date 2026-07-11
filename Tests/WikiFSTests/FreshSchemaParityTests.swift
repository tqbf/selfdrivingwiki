import Testing
import Foundation
import SQLite3
@testable import WikiFSCore

/// Guards the fresh-DB fast path (`createFreshSchemaV19`) against the stepwise
/// `migrate(from:)` ladder. The fast path duplicates the schema definition, so
/// any drift (a forgotten table/column/index/FK/trigger) would silently make
/// fresh dbs differ from upgraded ones. This forces a fresh db through the FULL
/// ladder and compares the two schema-identical.
@Suite(.tags(.integration))
struct FreshSchemaParityTests {

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshparity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("db.sqlite")
    }

    // MARK: - raw sqlite helpers

    private func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw WikiStoreError.unexpected("open failed")
        }
        return db
    }

    private func texts(_ db: OpaquePointer, _ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// First-row, first-column text value (empty string when no row / NULL).
    private func scalarText(_ db: OpaquePointer, _ sql: String) -> String {
        texts(db, sql).first ?? ""
    }

    private struct Col { let name, type, dflt: String; let notnull, pk: Int32 }

    private func columns(_ db: OpaquePointer, _ table: String) -> [Col] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Col] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func t(_ i: Int32) -> String {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, i))
            }
            out.append(Col(name: t(1), type: t(2), dflt: t(4),
                           notnull: sqlite3_column_int(stmt, 3),
                           pk: sqlite3_column_int(stmt, 5)))
        }
        return out
    }

    private struct FK { let table, from, to, onDelete: String }

    private func fks(_ db: OpaquePointer, _ table: String) -> [FK] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_list(\(table));", -1, &stmt, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [FK] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func t(_ i: Int32) -> String {
                sqlite3_column_type(stmt, i) == SQLITE_NULL ? "" : String(cString: sqlite3_column_text(stmt, i))
            }
            out.append(FK(table: t(2), from: t(3), to: t(4), onDelete: t(6)))
        }
        return out
    }

    /// FTS5 shadow tables (data/idx/content/config/docsize/rowids) are an
    /// implementation detail of the virtual tables; both paths create them, so
    /// they're filtered out of the comparison.
    private func isFTSShadow(_ name: String) -> Bool {
        ["_data", "_idx", "_content", "_config", "_docsize", "_rowids"].contains { name.hasSuffix($0) }
    }

    /// Canonical schema fingerprint: object inventory + per-table columns + FKs.
    private func fingerprint(at url: URL) throws -> String {
        let db = try open(url)
        defer { sqlite3_close(db) }
        var lines: [String] = []

        let tables = texts(db,
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
            .filter { !isFTSShadow($0) }
        let indexes = texts(db,
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
            .filter { !isFTSShadow($0) }
        let triggers = texts(db,
            "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name;")

        lines.append("tables: " + tables.joined(separator: ","))
        lines.append("indexes: " + indexes.joined(separator: ","))
        lines.append("triggers: " + triggers.joined(separator: ","))
        for t in tables {
            let cols = columns(db, t).map { "\($0.name):\($0.type):nn\($0.notnull):pk\($0.pk):\($0.dflt)" }
            lines.append("cols[\(t)]: " + cols.joined(separator: " | "))
            let fk = fks(db, t).map { "\($0.table).\($0.from)→\($0.to) ondel=\($0.onDelete)" }
            lines.append("fks[\(t)]: " + fk.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    @Test func freshFastPathMatchesStepwiseLadder() throws {
        let fastURL = tempURL()
        let ladderURL = tempURL()
        // Fast path (default): a fresh db builds the consolidated schema.
        _ = try SQLiteWikiStore(databaseURL: fastURL)
        // Ladder path: same fresh db forced through every migration step.
        _ = try SQLiteWikiStore(databaseURL: ladderURL, forceLadderMigration: true)

        let fast = try fingerprint(at: fastURL)
        let ladder = try fingerprint(at: ladderURL)

        // Both must report head version 22.
        #expect(try SQLiteWikiStore(databaseURL: fastURL).pragmaValue("user_version") == "31")
        #expect(try SQLiteWikiStore(databaseURL: ladderURL).pragmaValue("user_version") == "31")

        if fast != ladder {
            Issue.record("fresh fast-path schema drifted from the stepwise ladder:\n--- fast ---\n\(fast)\n--- ladder ---\n\(ladder)")
        }
        #expect(fast == ladder)
    }

    @Test func freshFastPathHasExpectedObjects() throws {
        let url = tempURL()
        _ = try SQLiteWikiStore(databaseURL: url)
        let db = try open(url)
        defer { sqlite3_close(db) }
        let tables = Set(texts(db,
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"))
        for expected in ["pages", "attachments", "page_links", "sources",
                         "source_markdown_versions", "source_links", "system_prompt",
                         "log", "wiki_index", "page_chunks", "source_chunks",
                         "source_search", "pages_fts", "sources_fts", "embedding_meta",
                         "bookmark_nodes", "chats", "chat_messages", "chat_chunks",
                         "chat_search", "chats_fts",
                         "blobs", "agents", "activities", "source_versions", "refs",
                         "page_versions",
                         "workspaces", "workspace_refs"] {
            #expect(tables.contains(expected), "missing table: \(expected)")
        }
        // The historical single-row embedding tables must NOT exist on a fresh db
        // (the fast path never creates them; the ladder creates-then-drops them).
        #expect(!tables.contains("page_embeddings"))
        #expect(!tables.contains("source_embeddings"))
        // Legacy index names survive the ladder's table renames → fast path reproduces them.
        let indexes = Set(texts(db,
            "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%';"))
        #expect(indexes.contains("ingested_files_created"))
        #expect(indexes.contains("file_markdown_versions_file"))
        #expect(indexes.contains("bookmark_nodes_parent"))
        // Seeded singletons present.
        #expect(texts(db, "SELECT body_markdown FROM system_prompt WHERE id=1;") == [SystemPrompt.defaultBody])
        #expect(texts(db, "SELECT body_markdown FROM wiki_index WHERE id=1;") == [WikiIndex.defaultBody])
    }

    /// Raw exec helper for setting up migration-fixture state.
    private func exec(_ db: OpaquePointer, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// AC.7 — v20→v21 migration is lossless: a legacy inline-content smv row
    /// gains a blob_hash + activity_id + source_version_id, its content is
    /// byte-identical when read back, and content is cleared to ''.
    @Test func v20ToV21MigrationLossless() throws {
        let url = tempURL()
        // 1. Fresh store (v21) + a PDF source (no self-seed) + its content version.
        let store = try SQLiteWikiStore(databaseURL: url)
        let pdf = try store.addSource(filename: "doc.pdf", data: Data("%PDF-1.4".utf8))
        let sourceID = pdf.id.rawValue
        let contentVersionID = try store.activeContentVersion(sourceID: pdf.id)?.id
        // Drop the store so we can manipulate the file with raw sqlite.
        _ = store

        // 2. Rewind to v20 and insert a legacy inline-content smv row.
        let db = try open(url)
        defer { sqlite3_close(db) }
        exec(db, "PRAGMA user_version=20;")
        // The fresh schema no longer has the `content` column (dropped at v24,
        // CAS-only). Re-create it to faithfully simulate a genuine v20-era smv
        // row with inline content, so the v20→v21 backfill has something to CAS.
        exec(db, "ALTER TABLE source_markdown_versions ADD COLUMN content TEXT NOT NULL DEFAULT '';")
        let legacyID = "01JLEGACY0000000000000000V"
        exec(db, """
        INSERT INTO source_markdown_versions (id, file_id, parent_id, content, origin, note, created_at)
        VALUES ('\(legacyID)', '\(sourceID)', NULL, '# Legacy\nbody bytes', 'extraction', NULL, 1000.0);
        """)
        // A second legacy row that is a USER EDIT (not an extraction). It must be
        // CAS'd like any row, but must NOT get a synthetic legacy-extraction
        // activity — a manual edit has no extraction provenance.
        let editID = "01JLEGACY0000000000000000U"
        exec(db, """
        INSERT INTO source_markdown_versions (id, file_id, parent_id, content, origin, note, created_at)
        VALUES ('\(editID)', '\(sourceID)', '\(legacyID)', 'edited body', 'user', NULL, 1001.0);
        """)

        // 3. Reopen → runs the v20→v21 backfill.
        sqlite3_close(db)
        let migrated = try SQLiteWikiStore(databaseURL: url)
        #expect(migrated.pragmaValue("user_version") == "31")

        // 4. The legacy extraction row was backfilled: blob_hash + activity_id + source_version_id set.
        #expect(migrated.scalarText(
            "SELECT blob_hash FROM source_markdown_versions WHERE id='\(legacyID)';") != "")
        #expect(migrated.scalarText(
            "SELECT activity_id FROM source_markdown_versions WHERE id='\(legacyID)';") != "")
        #expect(migrated.scalarText(
            "SELECT source_version_id FROM source_markdown_versions WHERE id='\(legacyID)';")
            == (contentVersionID ?? ""))
        // The inline `content` column is dropped entirely (v24, CAS-only): the
        // body lives only in `blobs`, so there is no per-row content to clear.
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('source_markdown_versions') WHERE name='content';") == "0")

        // 4b. The user-edit row IS CAS'd (blob_hash set, content cleared) but has
        //     NO activity_id — it must not be mislabeled as a legacy extraction.
        #expect(migrated.scalarText(
            "SELECT blob_hash FROM source_markdown_versions WHERE id='\(editID)';") != "")
        // (The edit row's inline `content` is gone with the column — asserted
        // DB-wide above; its body is in `blobs` like every other row.)
        #expect(migrated.scalarText(
            "SELECT activity_id FROM source_markdown_versions WHERE id='\(editID)';") == "")

        // 5. Content is byte-identical when read back through the resolved reader.
        let head = try migrated.processedMarkdownHead(sourceID: pdf.id)
        #expect(head?.content == "# Legacy\nbody bytes")
    }

    // MARK: - v22 (graph-model Phase 4 foundation): sources.role + source_links rebuild

    /// Strip v22 schema to simulate a genuine v21 DB, so reopening triggers the
    /// v21→v22 migration. Drops `sources.role` and rebuilds `source_links` to the
    /// v11 composite-PK shape (no role/pin columns). Used by the v22 tests below.
    private func rewindToV21(_ db: OpaquePointer) {
        exec(db, "PRAGMA user_version=21;")
        exec(db, "ALTER TABLE sources DROP COLUMN role;")
        exec(db, "DROP INDEX IF EXISTS source_links_edge;")
        exec(db, "DROP TABLE source_links;")
        exec(db, """
        CREATE TABLE source_links (
            from_page_id TEXT NOT NULL REFERENCES pages(id),
            to_source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
            link_text    TEXT NOT NULL,
            PRIMARY KEY (from_page_id, to_source_id)
        );
        """)
    }

    /// AC.1 — On a migrated DB, `sources.role` exists (NOT NULL, default
    /// `'primary'`), and `user_version` reports 22.
    @Test func v21ToV22AddsSourcesRole() throws {
        let url = tempURL()
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            _ = try store.addSource(filename: "seed.pdf", data: Data("%PDF".utf8))
        }
        let db = try open(url)
        rewindToV21(db)
        sqlite3_close(db)

        let migrated = try SQLiteWikiStore(databaseURL: url)
        #expect(migrated.pragmaValue("user_version") == "31")
        let db2 = try open(url)
        defer { sqlite3_close(db2) }
        let roleCol = columns(db2, "sources").first { $0.name == "role" }
        #expect(roleCol != nil, "sources.role column missing after migration")
        #expect(roleCol?.notnull == 1, "sources.role must be NOT NULL")
        // Default verified through behavior: addSource without role → 'primary'.
        let test = try migrated.addSource(filename: "def.txt", data: Data("x".utf8))
        #expect(test.role == .primary)
    }

    /// AC.2 — The v21→v22 migration is data-preserving: every source that existed
    /// pre-migration reads back with `role='primary'` and unchanged identity.
    @Test func v21ToV22MigrationPreservesSources() throws {
        let url = tempURL()
        let before: [(id: String, filename: String, displayName: String?, version: Int)]
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            let s1 = try store.addSource(filename: "a.pdf", data: Data("%PDF".utf8))
            let s2 = try store.addSource(filename: "b.txt", data: Data("hello".utf8))
            before = [
                (s1.id.rawValue, s1.filename, s1.displayName, s1.version),
                (s2.id.rawValue, s2.filename, s2.displayName, s2.version),
            ]
        }

        let db = try open(url)
        rewindToV21(db)
        sqlite3_close(db)

        let migrated = try SQLiteWikiStore(databaseURL: url)
        let db2 = try open(url)
        defer { sqlite3_close(db2) }
        for (id, filename, displayName, version) in before {
            #expect(scalarText(db2, "SELECT role FROM sources WHERE id='\(id)';") == "primary")
            #expect(scalarText(db2, "SELECT filename FROM sources WHERE id='\(id)';") == filename)
            #expect(scalarText(db2, "SELECT coalesce(display_name,'') FROM sources WHERE id='\(id)';")
                    == (displayName ?? ""))
            #expect(scalarText(db2, "SELECT version FROM sources WHERE id='\(id)';")
                    == String(version))
        }
        let count = scalarText(db2, "SELECT COUNT(*) FROM sources;")
        #expect(count == String(before.count))
        _ = migrated
    }

    /// AC.3 — source_links is rebuilt to the §4.4 shape and is byte-identical in
    /// behavior: (a) rows copy as role='cite'/pinned NULL, (b) index exists,
    /// (c) cascade still works, (d) dedup still collapses, (e) backlinks match.
    @Test func v22SourceLinksRebuildIsByteIdentical() throws {
        let url = tempURL()
        let pageID: String
        let sourceID: String
        let page: WikiPage
        let source: SourceSummary
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            page = try store.createPage(title: "Source Page")
            source = try store.addSource(filename: "ref.txt", data: Data("ref".utf8))
            pageID = page.id.rawValue
            sourceID = source.id.rawValue
        }

        // Rewind to v21 (source_links back to v11 composite-PK shape).
        let db = try open(url)
        rewindToV21(db)
        // Seed two source_links rows in v11 shape.
        exec(db, """
        INSERT INTO source_links (from_page_id, to_source_id, link_text)
        VALUES ('\(pageID)', '\(sourceID)', 'seeded link');
        """)
        sqlite3_close(db)

        // Reopen → v22 migration rebuilds source_links.
        let migrated = try SQLiteWikiStore(databaseURL: url)
        #expect(migrated.pragmaValue("user_version") == "31")
        let db2 = try open(url)
        defer { sqlite3_close(db2) }

        // (a) Pre-migration rows copied with role='cite', pinned_version_id NULL.
        #expect(scalarText(db2, "SELECT COUNT(*) FROM source_links WHERE to_source_id='\(sourceID)';") == "1")
        #expect(scalarText(db2, "SELECT role FROM source_links WHERE to_source_id='\(sourceID)' LIMIT 1;") == "cite")
        #expect(scalarText(db2, "SELECT COUNT(*) FROM source_links WHERE pinned_version_id IS NOT NULL;") == "0")

        // (b) source_links_edge unique index exists.
        #expect(scalarText(db2,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='source_links_edge';") != "0")

        // (e) Backlinks query returns the same page.
        let backlinks = try migrated.sourceLinkingPages(to: source.id)
        #expect(backlinks == [page.id])

        // (d) Dedup: replaceLinks with two links to the same source → 1 row.
        let dedupPage = try migrated.createPage(title: "Dedup")
        try migrated.replaceLinks(from: dedupPage.id, parsedLinks: [
            .init(linkType: .source, target: source.filename, linkText: "one"),
            .init(linkType: .source, target: source.filename, linkText: "two"),
        ])
        #expect(scalarText(db2,
            "SELECT COUNT(*) FROM source_links WHERE from_page_id='\(dedupPage.id.rawValue)';") == "1")

        // (c) Cascade: deleting the source removes all its source_links rows.
        try migrated.deleteSource(id: source.id)
        #expect(scalarText(db2,
            "SELECT COUNT(*) FROM source_links WHERE to_source_id='\(sourceID)';") == "0")
    }

    // MARK: - v27 (issue #242): bookmark timestamps

    /// v26→v27 migration adds `created_at`/`updated_at` to `bookmark_nodes` and
    /// backfills every legacy row to the migration time (legacy nodes have no
    /// recorded creation time). AC: columns appear NOT NULL DEFAULT 0 (matching
    /// the fresh-path def — parity), and a pre-existing row's timestamps are
    /// non-epoch and ~now after reopening.
    @Test func v26ToV27AddsAndBackfillsBookmarkTimestamps() throws {
        let url = tempURL()
        let nodeID: String
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            let node = try store.createBookmarkNode(
                parentID: nil, position: 0, kind: .folder, label: "Legacy", targetID: nil)
            nodeID = node.id
        }

        // Simulate a genuine v26 DB: the fresh schema already has the columns,
        // so drop them and rewind the stamp to before #242.
        let db = try open(url)
        exec(db, "ALTER TABLE bookmark_nodes DROP COLUMN created_at;")
        exec(db, "ALTER TABLE bookmark_nodes DROP COLUMN updated_at;")
        exec(db, "PRAGMA user_version=26;")
        sqlite3_close(db)

        let reopenStart = Date()
        let migrated = try SQLiteWikiStore(databaseURL: url)
        #expect(migrated.pragmaValue("user_version") == "31")
        let db2 = try open(url)
        defer { sqlite3_close(db2) }

        // Columns exist, NOT NULL, default 0 (matches the fresh-path CREATE
        // TABLE byte-for-byte — the parity test compares defaults).
        let createdCol = columns(db2, "bookmark_nodes").first { $0.name == "created_at" }
        #expect(createdCol?.notnull == 1, "bookmark_nodes.created_at must be NOT NULL")
        #expect(createdCol?.dflt == "0")
        let updatedCol = columns(db2, "bookmark_nodes").first { $0.name == "updated_at" }
        #expect(updatedCol?.notnull == 1, "bookmark_nodes.updated_at must be NOT NULL")
        #expect(updatedCol?.dflt == "0")

        // The legacy row was backfilled: both timestamps equal (migration
        // time), non-epoch, and within a tight window of the reopen.
        let nodes = try migrated.listBookmarkNodes()
        let reloaded = try #require(nodes.first { $0.id == nodeID })
        #expect(reloaded.createdAt == reloaded.updatedAt)
        #expect(reloaded.createdAt.timeIntervalSince1970 > 0)
        #expect(reloaded.createdAt > reopenStart.addingTimeInterval(-5))
        #expect(reloaded.createdAt < Date().addingTimeInterval(5))
    }
}
