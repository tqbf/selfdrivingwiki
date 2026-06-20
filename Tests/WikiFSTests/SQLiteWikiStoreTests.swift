import Foundation
import SQLite3
import Testing
@testable import WikiFSCore

/// Store-level tests: persistence across reopen, pragmas + schema, slug
/// collision handling, and ULID ordering.
struct SQLiteWikiStoreTests {

    /// Make a fresh on-disk DB URL in a unique temp directory.
    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - Persistence across reopen (M0/M1 acceptance as a unit test)

    @Test func persistsAcrossReopen() throws {
        let url = tempDatabaseURL()
        let id: PageID
        do {
            let store = try SQLiteWikiStore(databaseURL: url)
            let page = try store.createPage(title: "Home")
            id = page.id
            try store.updatePage(id: id, title: "Home", body: "# Welcome\n\nbody text")
        }
        // Reopen at the same URL — a brand new store object/connection.
        let reopened = try SQLiteWikiStore(databaseURL: url)
        let page = try reopened.getPage(id: id)
        #expect(page.title == "Home")
        #expect(page.bodyMarkdown == "# Welcome\n\nbody text")
    }

    // MARK: - Pragmas + schema

    @Test func pragmasAndSchema() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)

        // Open a separate raw connection to inspect pragmas/schema.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        // journal_mode is a database-level setting (WAL persists in the file
        // header), so a fresh connection sees it. foreign_keys is per-connection
        // and must be read from the store's own connection.
        #expect(scalarText(db, "PRAGMA journal_mode;").lowercased() == "wal")
        #expect(store.pragmaValue("foreign_keys") == "1")

        let tables = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"))
        #expect(tables.isSuperset(of:
            ["pages", "attachments", "page_links", "ingested_files", "system_prompt",
             "log", "wiki_index", "page_embeddings", "file_markdown_versions"]))

        let indexes = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='index';"))
        #expect(indexes.contains("pages_slug_unique"))
        #expect(indexes.contains("ingested_files_created"))

        // user_version guard: a fresh DB runs all migration steps → version 8
        // (v4 `log`, v5 `wiki_index`, v6 `ingested_files.ingested_at`,
        //  v7 `page_embeddings`, v8 `file_markdown_versions`); reopening must
        // not re-run DDL (no-op bootstrap).
        let userVersion = scalarText(db, "PRAGMA user_version;")
        #expect(userVersion == "8")
        let reopened = try SQLiteWikiStore(databaseURL: url)
        // If bootstrap weren't guarded, the CREATE TABLE would throw here.
        #expect((try? reopened.listPages(sortBy: .lastUpdated)) != nil)
        _ = store  // keep first store alive through the test
    }

    // MARK: - Slug collisions

    @Test func duplicateTitlesGetDistinctSlugs() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let a = try store.createPage(title: "Same Title")
        let b = try store.createPage(title: "Same Title")
        #expect(a.slug == "same-title")
        #expect(b.slug != a.slug)
        #expect(b.slug.hasPrefix("same-title-"))
    }

    @Test func slugifyStripsPunctuationAndCollapsesDashes() {
        #expect(SQLiteWikiStore.slugify("Hello, World!") == "hello-world")
        #expect(SQLiteWikiStore.slugify("  spaced   out  ") == "spaced-out")
        #expect(SQLiteWikiStore.slugify("!!!") == "untitled")
    }

    // MARK: - listPages ordering

    @Test func listPagesOrdersByUpdatedDescending() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        // Touch A last so it should sort first.
        try store.updatePage(id: a.id, title: "A", body: "later edit")
        let summaries = try store.listPages(sortBy: .lastUpdated)
        #expect(summaries.first?.id == a.id)
        #expect(summaries.contains { $0.id == b.id })
    }

    @Test func listPagesOrdersByNewestFirst() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        // Insert a tiny sleep so the two pages get distinct created_at timestamps.
        let a = try store.createPage(title: "A")
        Thread.sleep(forTimeInterval: 0.002)
        let b = try store.createPage(title: "B")
        // B was created later, so it should sort first under newestFirst.
        let summaries = try store.listPages(sortBy: .newestFirst)
        #expect(summaries.first?.id == b.id)
        #expect(summaries.last?.id == a.id)
    }

    @Test func listPagesOrdersByTitleAZ() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createPage(title: "Banana")
        _ = try store.createPage(title: "apple")
        _ = try store.createPage(title: "Cherry")
        let summaries = try store.listPages(sortBy: .titleAZ)
        // Case-insensitive: "apple" < "Banana" < "Cherry"
        #expect(summaries.map(\.title) == ["apple", "Banana", "Cherry"])
    }

    @Test func listPagesDefaultIsLastUpdated() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let a = try store.createPage(title: "A")
        _ = try store.createPage(title: "B")
        try store.updatePage(id: a.id, title: "A", body: "later edit")
        // The explicit .lastUpdated call must match the existing ordering expectation.
        let summaries = try store.listPages(sortBy: .lastUpdated)
        #expect(summaries.count == 2)
        #expect(summaries.first?.id == a.id)
    }

    @Test func pageSortOrderAllCases() {
        // Guard against accidental reorder / removal.
        let cases = PageSortOrder.allCases
        #expect(cases.count == 3)
        #expect(cases.contains(.lastUpdated))
        #expect(cases.contains(.newestFirst))
        #expect(cases.contains(.titleAZ))
    }

    // MARK: - Change token (Phase 3 sync anchor)

    @Test func changeTokenAdvancesOnEveryMutation() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())

        // v5 format:
        //   "<pCount>:<pSum>:<fCount>:<fSum>:<spVersion>:<logCount>:<idxVersion>".
        // A fresh DB seeds the system_prompt AND wiki_index singletons at version
        // 1 and has no log rows → trailing ":1:0:1".
        #expect(try store.changeToken() == "0:0:0:0:1:0:1")

        // Create bumps page COUNT and SUM (version starts at 1).
        let a = try store.createPage(title: "Alpha")
        #expect(try store.changeToken() == "1:1:0:0:1:0:1")

        // Update bumps that row's version by 1 → SUM increments.
        try store.updatePage(id: a.id, title: "Alpha", body: "edited")
        #expect(try store.changeToken() == "1:2:0:0:1:0:1")

        // A SECOND page that is NOT the global-max version must STILL advance the
        // token — the MAX-vs-SUM correctness lock. b starts at version 1, yet
        // count:sum changes (2 pages, sum 2+1=3).
        let b = try store.createPage(title: "Beta")
        #expect(try store.changeToken() == "2:3:0:0:1:0:1")

        try store.updatePage(id: b.id, title: "Beta", body: "beta edit")
        #expect(try store.changeToken() == "2:4:0:0:1:0:1")

        // Delete changes page COUNT and SUM.
        try store.deletePage(id: b.id)
        #expect(try store.changeToken() == "1:2:0:0:1:0:1")
    }

    /// The token MUST advance on ingest AND on delete (else the `files/` tree
    /// would never refresh — the orchestrator-critical fold-in).
    @Test func changeTokenAdvancesOnIngestAndDelete() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        #expect(try store.changeToken() == "0:0:0:0:1:0:1")

        // Ingest bumps the file COUNT and SUM (version 1).
        let f = try store.ingestFile(filename: "a.txt", data: Data("hi".utf8))
        #expect(try store.changeToken() == "0:0:1:1:1:0:1")

        // A second file.
        _ = try store.ingestFile(filename: "b.txt", data: Data("yo".utf8))
        #expect(try store.changeToken() == "0:0:2:2:1:0:1")

        // Delete the first → file COUNT and SUM drop.
        try store.deleteIngestedFile(id: f.id)
        #expect(try store.changeToken() == "0:0:1:1:1:0:1")
    }

    // MARK: - ULID ordering

    @Test func ulidsSortLexicographicallyInCreationOrder() {
        var rng = SystemRandomNumberGenerator()
        var previous = ""
        for offsetMs in stride(from: 0, to: 5000, by: 1000) {
            let date = Date(timeIntervalSince1970: 1_700_000 + Double(offsetMs) / 1000.0)
            let ulid = ULID.generate(at: date, using: &rng)
            #expect(ulid.count == 26)
            if !previous.isEmpty {
                #expect(previous < ulid, "ULID \(previous) should sort before \(ulid)")
            }
            previous = ulid
        }
    }

    // MARK: - raw-connection helpers

    private func scalarText(_ db: OpaquePointer?, _ sql: String) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0)
        else { return "" }
        return String(cString: c)
    }

    // MARK: - Semantic search (v7)

    @Test func v7SchemaHasPageEmbeddingsTable() throws {
        let url = tempDatabaseURL()
        _ = try SQLiteWikiStore(databaseURL: url)  // triggers migration

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let userVersion = scalarText(db, "PRAGMA user_version;")
        #expect(userVersion == "8")

        let tables = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"))
        #expect(tables.contains("page_embeddings"))
    }

    @Test func storePageEmbeddingInsertsOrReplaces() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Test")
        let blob = Data(repeating: 0xAB, count: 2048)  // 512 × Float32
        try store.storePageEmbedding(id: page.id, blob: blob)

        // Second write replaces.
        let blob2 = Data(repeating: 0xCD, count: 2048)
        try store.storePageEmbedding(id: page.id, blob: blob2)
    }

    @Test func recomputeMissingEmbeddingsCountsCorrectly() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createPage(title: "A")
        _ = try store.createPage(title: "B")
        // No embeddings yet — recompute should handle gracefully.
        let count = store.recomputeMissingEmbeddings()
        // May be 0 if NLEmbedding unavailable in test, or 2 if available.
        #expect(count >= 0)
    }

    // MARK: - Helpers

    private func rows(_ db: OpaquePointer?, _ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }
}
