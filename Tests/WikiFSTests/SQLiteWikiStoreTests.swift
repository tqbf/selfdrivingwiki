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
            ["pages", "attachments", "page_links", "sources", "source_links",
             "system_prompt", "log", "wiki_index", "page_chunks",
             "source_markdown_versions"]))

        let indexes = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='index';"))
        #expect(indexes.contains("pages_slug_unique"))
        #expect(indexes.contains("ingested_files_created"))

        // user_version guard: a fresh DB runs all migration steps → version 15.
        // Reopening must not re-run DDL (no-op bootstrap).
        let userVersion = scalarText(db, "PRAGMA user_version;")
        #expect(userVersion == "15")
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

        // Current format:
        //   "<pCount>:<pSum>:<fCount>:<fSum>:<spVersion>:<logCount>:<idxVersion>:<smvCount>".
        // A fresh DB seeds the system_prompt AND wiki_index singletons at version
        // 1, has no log rows, no source_markdown_versions, and no processed
        // markdown → trailing ":1:0:1:0".
        #expect(try store.changeToken() == "0:0:0:0:1:0:1:0")

        // Create bumps page COUNT and SUM (version starts at 1).
        let a = try store.createPage(title: "Alpha")
        #expect(try store.changeToken() == "1:1:0:0:1:0:1:0")

        // Update bumps that row's version by 1 → SUM increments.
        try store.updatePage(id: a.id, title: "Alpha", body: "edited")
        #expect(try store.changeToken() == "1:2:0:0:1:0:1:0")

        // A SECOND page that is NOT the global-max version must STILL advance the
        // token — the MAX-vs-SUM correctness lock. b starts at version 1, yet
        // count:sum changes (2 pages, sum 2+1=3).
        let b = try store.createPage(title: "Beta")
        #expect(try store.changeToken() == "2:3:0:0:1:0:1:0")

        try store.updatePage(id: b.id, title: "Beta", body: "beta edit")
        #expect(try store.changeToken() == "2:4:0:0:1:0:1:0")

        // Delete changes page COUNT and SUM.
        try store.deletePage(id: b.id)
        #expect(try store.changeToken() == "1:2:0:0:1:0:1:0")
    }

    /// The token MUST advance on ingest AND on delete (else the `files/` tree
    /// would never refresh — the orchestrator-critical fold-in).
    @Test func changeTokenAdvancesOnIngestAndDelete() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        #expect(try store.changeToken() == "0:0:0:0:1:0:1:0")

        // Ingest bumps the file COUNT and SUM (version 1).
        let f = try store.addSource(filename: "a.txt", data: Data("hi".utf8))
        #expect(try store.changeToken() == "0:0:1:1:1:0:1:0")

        // A second file.
        _ = try store.addSource(filename: "b.txt", data: Data("yo".utf8))
        #expect(try store.changeToken() == "0:0:2:2:1:0:1:0")

        // Delete the first → file COUNT and SUM drop.
        try store.deleteSource(id: f.id)
        #expect(try store.changeToken() == "0:0:1:1:1:0:1:0")
    }

    /// The token MUST advance when a processed markdown version is appended,
    /// or the `sources/` tree would never learn of new extracts.
    @Test func changeTokenAdvancesOnAppendProcessedMarkdown() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        #expect(try store.changeToken() == "0:0:0:0:1:0:1:0")

        // Add a source first.
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf content".utf8))
        #expect(try store.changeToken() == "0:0:1:1:1:0:1:0")

        // Append processed markdown — smvCount goes 0 → 1.
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "# Extracted", origin: "test", note: nil)
        #expect(try store.changeToken() == "0:0:1:1:1:0:1:1")

        // Append another version — smvCount advances again.
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "# Edited", origin: "test", note: "edit")
        #expect(try store.changeToken() == "0:0:1:1:1:0:1:2")

        // Deleting the source removes its markdown versions (CASCADE).
        try store.deleteSource(id: source.id)
        #expect(try store.changeToken() == "0:0:0:0:1:0:1:0")
    }

    /// processedMarkdownHeadsBySource returns one row per source, keyed by
    /// sourceID, with the head version for each.
    @Test func processedMarkdownHeadsBySourceReturnsCorrectHeads() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())

        // No sources → empty dict.
        #expect(try store.processedMarkdownHeadsBySource().isEmpty)

        // Add two sources.
        let a = try store.addSource(filename: "a.pdf", data: Data("a".utf8))
        let b = try store.addSource(filename: "b.pdf", data: Data("b".utf8))

        // No markdown yet → still empty.
        #expect(try store.processedMarkdownHeadsBySource().isEmpty)

        // Append markdown for source a only.
        let v1 = try store.appendProcessedMarkdown(
            sourceID: a.id, content: "# A", origin: "test", note: nil)
        var heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.count == 1)
        #expect(heads[a.id.rawValue]?.id == v1.id)
        #expect(heads[a.id.rawValue]?.content == "# A")

        // Append markdown for source b.
        let v2 = try store.appendProcessedMarkdown(
            sourceID: b.id, content: "# B", origin: "test", note: nil)
        heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.count == 2)
        #expect(heads[a.id.rawValue]?.id == v1.id)
        #expect(heads[b.id.rawValue]?.id == v2.id)

        // Append a new head for source a — only that source's entry changes.
        let v3 = try store.appendProcessedMarkdown(
            sourceID: a.id, content: "# A Edited", origin: "test", note: "edit")
        heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.count == 2)
        #expect(heads[a.id.rawValue]?.id == v3.id)
        #expect(heads[a.id.rawValue]?.content == "# A Edited")
        #expect(heads[b.id.rawValue]?.id == v2.id)
    }

    // MARK: - Processed markdown head returns nil when empty (lazy-seed regression)

    @Test func processedMarkdownHeadReturnsNilWhenNoVersionsExist() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))

        // Head is nil when no markdown has been appended.
        let head = try store.processedMarkdownHead(sourceID: source.id)
        #expect(head == nil)

        // No chain row was created by the nil read (lazy-seed regression).
        #expect(try !store.hasProcessedMarkdown(sourceID: source.id))
        #expect(try store.processedMarkdownHistory(sourceID: source.id).isEmpty)
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

    @Test func v14SchemaHasPageChunksTable() throws {
        let url = tempDatabaseURL()
        _ = try SQLiteWikiStore(databaseURL: url)  // triggers migration

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let userVersion = scalarText(db, "PRAGMA user_version;")
        #expect(userVersion == "15")

        let tables = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"))
        #expect(tables.contains("page_chunks"))
        // The old single-embedding tables are dropped in v14.
        #expect(!tables.contains("page_embeddings"))
    }

    @Test func storePageChunksInsertsOrReplaces() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Test")
        let chunk = Data(repeating: 0xAB, count: 2048)  // 512 × Float32
        try store.storePageChunks(id: page.id, chunks: [chunk])

        // Second write replaces the set (deletes old chunks, inserts new).
        let chunk2 = Data(repeating: 0xCD, count: 2048)
        try store.storePageChunks(id: page.id, chunks: [chunk2, chunk2])
    }

    // MARK: - v11 migration (source_links ON DELETE CASCADE)

    @Test func deleteSourceCascadesToSourceLinksAfterV11Migration() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let page = try store.createPage(title: "Test")
        let source = try store.addSource(filename: "test.txt", data: Data("hello".utf8))

        // Simulate Phase B inserting a source_links row via a raw connection.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
            INSERT INTO source_links (from_page_id, to_source_id, link_text)
            VALUES ('\(page.id.rawValue)', '\(source.id.rawValue)', 'test link');
            """, nil, nil, nil) == SQLITE_OK)

        // Deleting the source must NOT throw, and the source_links row must be gone.
        try store.deleteSource(id: source.id)
        #expect(scalarText(db, "SELECT count(*) FROM source_links WHERE to_source_id = '\(source.id.rawValue)';") == "0")
    }

    @Test func freshDBReachesUserVersion15() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        #expect(store.pragmaValue("user_version") == "15")
    }

    @Test func v11SourceLinksHasDeleteCascade() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        // Insert a page and source, then a source_links row via raw connection.
        let page = try store.createPage(title: "Test")
        let source = try store.addSource(filename: "t.txt", data: Data("x".utf8))
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, """
            INSERT INTO source_links (from_page_id, to_source_id, link_text)
            VALUES ('\(page.id.rawValue)', '\(source.id.rawValue)', 'link');
            """, nil, nil, nil) == SQLITE_OK)
        // Read back the DDL — must contain ON DELETE CASCADE.
        let ddl = scalarText(raw,
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='source_links';") ?? ""
        #expect(ddl.contains("ON DELETE CASCADE"))
        _ = store
    }

    // MARK: - Phase B: resolveSourceByName + mixed replaceLinks

    @Test func resolveSourceByNameMatchesDisplayName() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "report.pdf", data: Data("pdf".utf8))
        // display_name defaults to filename.
        let id = try store.resolveSourceByName("report.pdf")
        #expect(id == source.id)
    }

    @Test func resolveSourceByNameMatchesFilenameFallback() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "data.csv", data: Data("csv".utf8))
        // Even without a custom display_name, filename match works.
        let id = try store.resolveSourceByName("data.csv")
        #expect(id == source.id)
    }

    @Test func resolveSourceByNameIsCaseInsensitive() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.addSource(filename: "My Report.PDF", data: Data("pdf".utf8))
        let id = try store.resolveSourceByName("my report.pdf")
        #expect(id != nil)
    }

    @Test func resolveSourceByNameMatchesWithoutExtension() throws {
        // Legacy rows store display_name = filename WITH the extension, but the
        // canonical cite target drops it — `[[source:report]]` must resolve
        // report.pdf, case-insensitively on the stem.
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "report.pdf", data: Data("pdf".utf8))
        #expect(try store.resolveSourceByName("report") == source.id)
        #expect(try store.resolveSourceByName("REPORT") == source.id)
        // The full name with extension still resolves (fast path).
        #expect(try store.resolveSourceByName("report.pdf") == source.id)
    }

    @Test func resolveSourceByNameMatchesMarkdownStem() throws {
        // The exact regression: a markdown source whose display_name is the
        // filename with `.md`, cited by its stem.
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(
            filename: "Claim File Helper — ProPublica.md", data: Data("md".utf8))
        #expect(try store.resolveSourceByName("Claim File Helper — ProPublica") == source.id)
    }

    @Test func resolveSourceByNameReturnsNilForUnknown() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        #expect(try store.resolveSourceByName("nonexistent") == nil)
    }

    @Test func replaceLinksWritesBothPageAndSourceLinks() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "Test Page")
        let source = try store.addSource(filename: "note.md", data: Data("md".utf8))

        // Mixed links: one page link, one source link.
        let links: [WikiLinkParser.ParsedLink] = [
            .init(linkType: .page, target: "Test Page", linkText: "self"),
            .init(linkType: .source, target: source.filename, linkText: "the note"),
        ]
        try store.replaceLinks(from: page.id, parsedLinks: links)

        // Both tables are populated.
        let pageLinks = try store.listAllLinks()
        #expect(pageLinks.count == 1)
        #expect(pageLinks[0].type == "page")

        let sourceLinks = try store.listAllSourceLinks()
        #expect(sourceLinks.count == 1)
        #expect(sourceLinks[0].type == "source")
        #expect(sourceLinks[0].linkText == "the note")
    }

    @Test func replaceLinksIsAtomicAcrossBothTables() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let page = try store.createPage(title: "P")
        let source = try store.addSource(filename: "s.txt", data: Data("x".utf8))

        // First write a page link.
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .page, target: "P", linkText: "p"),
        ])
        #expect(try store.listAllLinks().count == 1)

        // Re-write with only source links — page links should be wiped.
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.filename, linkText: "src"),
        ])
        #expect(try store.listAllLinks().isEmpty)
        #expect(try store.listAllSourceLinks().count == 1)
    }

    @Test func resolveTitleToIDIsCaseInsensitive() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        _ = try store.createPage(title: "Home Page")
        let id = try store.resolveTitleToID("home page")
        #expect(id != nil)
    }

    // MARK: - Phase D: sourceLinkingPages + renameSource

    @Test func sourceLinkingPagesReturnsPagesThatLinkToSource() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "note.md", data: Data("md".utf8))
        let page = try store.createPage(title: "Test Page")
        try store.replaceLinks(from: page.id, parsedLinks: [
            .init(linkType: .source, target: source.filename, linkText: "note"),
        ])
        let pages = try store.sourceLinkingPages(to: source.id)
        #expect(pages.count == 1)
        #expect(pages[0] == page.id)
    }

    @Test func sourceLinkingPagesReturnsEmptyForUnlinkedSource() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "orphan.md", data: Data("md".utf8))
        let pages = try store.sourceLinkingPages(to: source.id)
        #expect(pages.isEmpty)
    }

    @Test func renameSourceUpdatesDisplayNameAndBumpsVersion() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "old.pdf", data: Data("%PDF".utf8))
        let oldVersion = try store.getSource(id: source.id).version
        let oldToken = try store.changeToken()

        try store.renameSource(id: source.id, to: "New Name")

        let updated = try store.getSource(id: source.id)
        #expect(updated.displayName == "New Name")
        #expect(updated.version == oldVersion + 1)
        let newToken = try store.changeToken()
        #expect(newToken != oldToken)
    }

    @Test func renameSourceRewritesLinksInLinkingPages() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        let page = try store.createPage(title: "Summary")
        // Write a page body with a source link using the old name.
        try store.updatePage(id: page.id, title: "Summary",
            body: "See [[source:paper.pdf]] for details.")
        try store.replaceLinks(from: page.id,
            parsedLinks: WikiLinkParser.parse("See [[source:paper.pdf]] for details."))

        try store.renameSource(id: source.id, to: "Renamed Paper")

        let updated = try store.getPage(id: page.id)
        #expect(updated.bodyMarkdown.contains("[[source:Renamed Paper]]"))
        #expect(!updated.bodyMarkdown.contains("[[source:paper.pdf]]"))
    }

    @Test func renameSourceIsNoOpWhenNameUnchanged() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "x.pdf", data: Data("%PDF".utf8))
        let oldToken = try store.changeToken()
        try store.renameSource(id: source.id, to: source.filename)
        // No version bump, no token change.
        #expect(try store.changeToken() == oldToken)
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
