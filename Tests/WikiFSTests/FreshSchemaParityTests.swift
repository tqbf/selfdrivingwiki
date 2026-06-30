import Testing
import Foundation
import SQLite3
@testable import WikiFSCore

/// Guards the fresh-DB fast path (`createFreshSchemaV14`) against the stepwise
/// `migrate(from:)` ladder. The fast path duplicates the schema definition, so
/// any drift (a forgotten table/column/index/FK/trigger) would silently make
/// fresh dbs differ from upgraded ones. This forces a fresh db through the FULL
/// ladder and compares the two schema-identical.
@Suite struct FreshSchemaParityTests {

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

    private struct Col { let name, type, dflt: String; let notnull, pk: Int32 }

    private func columns(_ db: OpaquePointer, _ table: String) -> [Col] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info \(table);", -1, &stmt, nil) == SQLITE_OK
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
        guard sqlite3_prepare_v2(db, "PRAGMA foreign_key_list \(table);", -1, &stmt, nil) == SQLITE_OK
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

        // Both must report head version 14.
        #expect(try SQLiteWikiStore(databaseURL: fastURL).pragmaValue("user_version") == "15")
        #expect(try SQLiteWikiStore(databaseURL: ladderURL).pragmaValue("user_version") == "15")

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
                         "source_search", "pages_fts", "sources_fts", "embedding_meta"] {
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
        // Seeded singletons present.
        #expect(texts(db, "SELECT body_markdown FROM system_prompt WHERE id=1;") == [SystemPrompt.defaultBody])
        #expect(texts(db, "SELECT body_markdown FROM wiki_index WHERE id=1;") == [WikiIndex.defaultBody])
    }
}
