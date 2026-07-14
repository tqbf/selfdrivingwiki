import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// Regression tests for the migration-time FTS5 self-heal.
///
/// A cross-host copy (rsync) can corrupt an FTS5 external-content shadow index
/// in a way `PRAGMA integrity_check` misses — it validates the main tables, not
/// the FTS5 shadow b-trees. The corruption only surfaces as `SQLITE_CORRUPT`
/// ("database disk image is malformed") when a migration step that touches the
/// index runs (e.g. the v22→23 link-canonicalization sweep, which reads through
/// the resolvers and writes page bodies, firing the FTS sync triggers).
///
/// Before the fix, that threw out of `bootstrapSchema`, and `WikiSession`'s
/// `catch` then hit `try! SQLiteWikiStore(":memory:")` → the whole app crashed.
/// The fix rebuilds the FTS indexes from their (intact) content tables and
/// retries the migration once, so an old-schema DB with a corrupt search index
/// opens and upgrades cleanly.
///
/// SQLite protects FTS5 shadow tables from direct writes (defensive mode) and
/// byte-scribbling the file hits the wrong b-trees, so the corrupt-write is
/// injected deterministically via `migrationCorruptFaultForTesting` rather than
/// reproduced from raw bytes. The fault fires the exact `SQLITE_CORRUPT` the
/// real corruption raises; the assertions prove the heal + retry recovers.
struct MigrationFTSSelfHealTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-fts-heal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    /// Build a healthy current-schema DB with pages, then rewind `user_version`
    /// to 22 so reopening runs the ladder from the v22→23 step.
    private func buildRewoundV22DB(pageCount: Int) throws -> URL {
        let url = tempDatabaseURL()
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            for i in 1...pageCount {
                _ = try store.createPage(title: "Page \(i) alpha beta gamma")
            }
        } // store deinit closes the connection
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "PRAGMA user_version=22;", nil, nil, nil) == SQLITE_OK)
        return url
    }

    @Test func migrationCorruptError_healsFTSAndRetries() throws {
        let url = try buildRewoundV22DB(pageCount: 20)

        // Arm the fault: the next migration throws SQLITE_CORRUPT before any
        // step, exactly as a corrupt FTS shadow index would when the v22→23
        // sweep first writes a page body. The store must catch it, rebuild the
        // FTS indexes, and retry the migration to completion.
        SQLiteWikiStore.migrationCorruptFaultForTesting = "database disk image is malformed"
        defer { SQLiteWikiStore.migrationCorruptFaultForTesting = nil }

        let store = try SQLiteWikiStore(databaseURL: url)

        // The fault was consumed (heal path ran), not left armed.
        #expect(SQLiteWikiStore.migrationCorruptFaultForTesting == nil)
        // Migrated to the current schema with all pages intact.
        #expect(store.pragmaValue("user_version") == "\(SQLiteWikiStore.currentSchemaVersion)")
        #expect(store.scalarText("SELECT COUNT(*) FROM pages;") == "20")
        // The rebuilt FTS index is usable — a MATCH returns every page.
        #expect(store.scalarText("SELECT COUNT(*) FROM pages_fts WHERE pages_fts MATCH 'alpha';") == "20")
    }

    /// A healthy old-schema DB still migrates normally — the self-heal path is
    /// only taken on the corrupt-write failure, never spuriously.
    @Test func healthyV22MigratesWithoutRebuild() throws {
        let url = try buildRewoundV22DB(pageCount: 1)
        let store = try SQLiteWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "\(SQLiteWikiStore.currentSchemaVersion)")
        #expect(store.scalarText("SELECT COUNT(*) FROM pages;") == "1")
    }
}
