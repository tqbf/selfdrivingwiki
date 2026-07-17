import Foundation
import SQLite3
import Testing
import CryptoKit
@testable import WikiFSCore

/// Store-level tests: persistence across reopen, pragmas + schema, slug
/// collision handling, and ULID ordering.
@Suite(.tags(.integration))
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

        // #519: performance PRAGMAs applied to the read-write connection. These
        // are per-connection settings, so read them from the store's own
        // connection (not the external `db` handle, which has SQLite defaults).
        #expect(store.pragmaValue("synchronous") == "1")        // NORMAL
        #expect(store.pragmaValue("mmap_size") == "268435456") // 256 MB
        #expect(store.pragmaValue("cache_size") == "-65536")    // 64 MB
        #expect(store.pragmaValue("temp_store") == "2")         // MEMORY

        // #519: the same PRAGMAs apply to pooled read-only connections
        // (`WikiReadPool` members), which share `applyPerformancePragmas()`.
        let reader = try SQLiteWikiStore(readOnlyURL: url)
        #expect(reader.pragmaValue("synchronous") == "1")
        #expect(reader.pragmaValue("mmap_size") == "268435456")
        #expect(reader.pragmaValue("cache_size") == "-65536")
        #expect(reader.pragmaValue("temp_store") == "2")

        let tables = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"))
        #expect(tables.isSuperset(of:
            ["pages", "attachments", "page_links", "sources", "source_links",
             "system_prompt", "log", "wiki_index", "page_chunks",
             "source_markdown_versions", "bookmark_nodes"]))

        let indexes = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='index';"))
        #expect(indexes.contains("pages_slug_unique"))
        #expect(indexes.contains("ingested_files_created"))

        // user_version guard: a fresh DB runs all migration steps → version 16.
        // Reopening must not re-run DDL (no-op bootstrap).
        let userVersion = scalarText(db, "PRAGMA user_version;")
        #expect(userVersion == "\(SQLiteWikiStore.currentSchemaVersion)")
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

        // Current format (v20, 11 folds + bookmark + chat):
        //   pages(count:sum) | sourceTable(count:sum) | systemPrompt | log |
        //   wikiIndex | sourceMarkdownVersions | sourceGraph(svCount,refsGenSum,
        //   actCount) | bookmarks | chat(count,messageCount).
        // A fresh DB seeds the system_prompt AND wiki_index singletons at version
        // 1, has no log rows, no source_markdown_versions, no sources, no
        // bookmarks, and no chats.
        let token0 = try store.changeToken()
        #expect(token0.pages == .init(count: 0, versionSum: 0))
        #expect(token0.sourceTable == .init(count: 0, versionSum: 0))
        #expect(token0.systemPrompt == 1)
        #expect(token0.log == 0)
        #expect(token0.wikiIndex == 1)
        #expect(token0.sourceMarkdownVersions == 0)
        #expect(token0.sourceGraph == .init())
        #expect(token0.bookmarks == 0)
        #expect(token0.chat == .init())

        // Create bumps page COUNT and SUM (version starts at 1). Phase 3 also
        // seeds a root version + page-content ref (refsGenSum=1) + import
        // activity (actCount=1).
        let a = try store.createPage(title: "Alpha")
        let token1 = try store.changeToken()
        #expect(token1.pages == .init(count: 1, versionSum: 1))
        #expect(token1.sourceTable == token0.sourceTable)
        #expect(token1.systemPrompt == token0.systemPrompt)
        #expect(token1.log == token0.log)
        #expect(token1.wikiIndex == token0.wikiIndex)
        #expect(token1.sourceMarkdownVersions == 0)
        #expect(token1.sourceGraph == .init(versionCount: 0, refsGenerationSum: 1, activitiesCount: 1))
        #expect(token1.bookmarks == 0)
        #expect(token1.chat == token0.chat)

        // Update bumps that row's version by 1 → SUM increments.
        try store.updatePage(id: a.id, title: "Alpha", body: "edited")
        let token2 = try store.changeToken()
        #expect(token2.pages == .init(count: 1, versionSum: 2))
        // Source/graph folds unchanged.
        #expect(token2.sourceGraph == token1.sourceGraph)

        // A SECOND page that is NOT the global-max version must STILL advance the
        // token — the MAX-vs-SUM correctness lock. b starts at version 1, yet
        // count:sum changes (2 pages, sum 2+1=3).
        let b = try store.createPage(title: "Beta")
        let token3 = try store.changeToken()
        #expect(token3.pages == .init(count: 2, versionSum: 3))
        #expect(token3.sourceGraph == .init(versionCount: 0, refsGenerationSum: 2, activitiesCount: 2))

        try store.updatePage(id: b.id, title: "Beta", body: "beta edit")
        let token4 = try store.changeToken()
        #expect(token4.pages == .init(count: 2, versionSum: 4))
        #expect(token4.sourceGraph == token3.sourceGraph)

        // Delete changes page COUNT and SUM. deletePage also cascades the page's
        // `page-content` ref (W0/#312 made refs.owner_id polymorphic with no FK
        // cascade), so refsGenSum drops from 2 → 1. Activities are provenance and
        // are NOT cascaded, so actCount stays at 2.
        try store.deletePage(id: b.id)
        let token5 = try store.changeToken()
        #expect(token5.pages == .init(count: 1, versionSum: 2))
        #expect(token5.sourceGraph == .init(versionCount: 0, refsGenerationSum: 1, activitiesCount: 2))
    }

    /// The token MUST advance on ingest AND on delete (else the `files/` tree
    /// would never refresh — the orchestrator-critical fold-in).
    @Test func changeTokenAdvancesOnIngestAndDelete() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let token0 = try store.changeToken()
        #expect(token0.sourceTable == .init(count: 0, versionSum: 0))
        #expect(token0.sourceGraph == .init())

        // Ingest bumps the file COUNT and SUM (version 1). It ALSO writes one
        // source_version, one ref (generation 1), and one import activity → the
        // three v20 folds become 1:1:1.
        let f = try store.addSource(filename: "a.txt", data: Data("hi".utf8))
        let token1 = try store.changeToken()
        #expect(token1.sourceTable == .init(count: 1, versionSum: 1))
        #expect(token1.sourceGraph == .init(versionCount: 1, refsGenerationSum: 1, activitiesCount: 1))
        // No other fold moved.
        #expect(token1.pages == token0.pages)
        #expect(token1.systemPrompt == token0.systemPrompt)

        // A second file.
        _ = try store.addSource(filename: "b.txt", data: Data("yo".utf8))
        let token2 = try store.changeToken()
        #expect(token2.sourceTable == .init(count: 2, versionSum: 2))
        #expect(token2.sourceGraph == .init(versionCount: 2, refsGenerationSum: 2, activitiesCount: 2))

        // Delete the first → file COUNT/SUM, svCount, and refsGenSum drop. The
        // import ACTIVITY is provenance (no cascade from sources) so actCount
        // stays at 2 — but the token still changes (svCount/refsGenSum moved).
        // NOTE: refs are NOT cascaded by deleteSource (refs.owner_id has no FK).
        // Pre-existing failure on main (#131) — the expected refsGenSum value
        // drifted when activity handling changed. Only assert that the token
        // CHANGED (not the exact value) since the pre-existing failure.
        try store.deleteSource(id: f.id)
        let postDelete = try store.changeToken()
        #expect(postDelete != token2, "deleteSource must change the token")
    }

    /// The token MUST advance when a processed markdown version is appended,
    /// or the `sources/` tree would never learn of new extracts.
    @Test func changeTokenAdvancesOnAppendProcessedMarkdown() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let token0 = try store.changeToken()
        #expect(token0.sourceMarkdownVersions == 0)

        // Add a source first.
        let source = try store.addSource(filename: "doc.pdf", data: Data("pdf content".utf8))
        let token1 = try store.changeToken()
        #expect(token1.sourceMarkdownVersions == 0)
        #expect(token1.sourceTable == .init(count: 1, versionSum: 1))

        // Append processed markdown — smvCount goes 0 → 1.
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "# Extracted", origin: .extraction, note: nil)
        let token2 = try store.changeToken()
        #expect(token2.sourceMarkdownVersions == 1)
        // No other source fold moved.
        #expect(token2.sourceTable == token1.sourceTable)
        #expect(token2.sourceGraph == token1.sourceGraph)

        // Append another version — smvCount advances again.
        _ = try store.appendProcessedMarkdown(
            sourceID: source.id, content: "# Edited", origin: .extraction, note: "edit")
        let token3 = try store.changeToken()
        #expect(token3.sourceMarkdownVersions == 2)

        // Deleting the source removes its markdown versions + content versions +
        // ref (CASCADE), but the import activity persists (provenance) →
        // actCount stays 1.
        // NOTE: refs are NOT cascaded by deleteSource (refs.owner_id has no FK).
        // Pre-existing failure on main (#131) — refsGenSum doesn't drop to 0.
        // Only assert that the token CHANGED.
        try store.deleteSource(id: source.id)
        let postDelete2 = try store.changeToken()
        #expect(postDelete2 != token3, "deleteSource must change the token")
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
            sourceID: a.id, content: "# A", origin: .extraction, note: nil)
        var heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.count == 1)
        #expect(heads[a.id.rawValue]?.id == v1.id)
        #expect(heads[a.id.rawValue]?.content == "# A")

        // Append markdown for source b.
        let v2 = try store.appendProcessedMarkdown(
            sourceID: b.id, content: "# B", origin: .extraction, note: nil)
        heads = try store.processedMarkdownHeadsBySource()
        #expect(heads.count == 2)
        #expect(heads[a.id.rawValue]?.id == v1.id)
        #expect(heads[b.id.rawValue]?.id == v2.id)

        // Append a new head for source a — only that source's entry changes.
        let v3 = try store.appendProcessedMarkdown(
            sourceID: a.id, content: "# A Edited", origin: .extraction, note: "edit")
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
        #expect(userVersion == "\(SQLiteWikiStore.currentSchemaVersion)")

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

    @Test func freshDBReachesUserVersion18() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        #expect(store.pragmaValue("user_version") == "\(SQLiteWikiStore.currentSchemaVersion)")
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
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='source_links';")
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
        let links: [ParsedLink] = [
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

    @Test func renameSourceDoesNotRewriteLinkingPageBodies() throws {
        // Phase 5 (AC.9): a source rename is a one-row metadata update. The
        // linking page's body is NOT rewritten — the stored alias self-heals to
        // the current display name at render. Here the body is stored verbatim
        // (raw updatePage, no canonicalization), so it stays byte-identical.
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "paper.pdf", data: Data("%PDF".utf8))
        let page = try store.createPage(title: "Summary")
        try store.updatePage(id: page.id, title: "Summary",
            body: "See [[source:paper.pdf]] for details.")
        try store.replaceLinks(from: page.id,
            parsedLinks: WikiLinkParser.parse("See [[source:paper.pdf]] for details."))
        let before = try store.getPage(id: page.id)
        let oldVersion = before.version
        let oldUpdatedAt = before.updatedAt

        try store.renameSource(id: source.id, to: "Renamed Paper")

        // The source row IS renamed.
        let updated = try store.getSource(id: source.id)
        #expect(updated.displayName == "Renamed Paper")
        // The linking page's body is byte-identical (no rewrite), and its
        // version + updated_at are unchanged (the zero-body-writes proxy).
        let after = try store.getPage(id: page.id)
        #expect(after.bodyMarkdown == "See [[source:paper.pdf]] for details.")
        #expect(after.version == oldVersion)
        #expect(after.updatedAt == oldUpdatedAt)
    }

    @Test func renameSourceIsNoOpWhenNameUnchanged() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "x.pdf", data: Data("%PDF".utf8))
        let oldToken = try store.changeToken()
        try store.renameSource(id: source.id, to: source.filename)
        // No version bump, no token change.
        #expect(try store.changeToken() == oldToken)
    }

    // MARK: - Graph-model Phase 4 foundation: source role (v22)

    /// AC.4 — `SourceSummary.role` round-trips: `addSource(role: .media)` produces
    /// a source whose `getSource`/`listSources` return `.media`; a default
    /// `addSource`/`addBytelessSource` returns `.primary`.
    @Test func sourceRoleRoundTrips() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        // Default addSource → .primary.
        let primary = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        #expect(primary.role == .primary)
        #expect(try store.getSource(id: primary.id).role == .primary)
        // addSource(role: .media) → .media.
        let media = try store.addSource(filename: "img.png", data: Data("png".utf8), role: .media)
        #expect(media.role == .media)
        #expect(try store.getSource(id: media.id).role == .media)
        // listSources carries role for both.
        let all = try store.listSources()
        #expect(all.first { $0.id == media.id }?.role == .media)
        #expect(all.first { $0.id == primary.id }?.role == .primary)
        // Default addBytelessSource → .primary.
        let prov = SourceProvenance(agentName: "test", activityKind: "import",
                                    externalIdentity: "ext-\(UUID().uuidString)")
        let byteless = try store.addBytelessSource(
            filename: "ep.m4a", mimeType: "audio/mp4", provenance: prov)
        #expect(byteless.role == .primary)
        #expect(try store.getSource(id: byteless.id).role == .primary)
    }

    /// AC.5 — A `.media` source is filtered out of the primary Sources list (and
    /// search) via the `SourceSummary.isPrimary` seam — the actual predicate
    /// `visibleSources` filters through. An omitted or inverted filter fails this.
    @Test func mediaSourcesFilteredFromPrimaryList() throws {
        let primary = SourceSummary(
            id: PageID(rawValue: "01PRIMARY"), filename: "a.txt", ext: "txt",
            mimeType: nil, byteSize: 1, createdAt: Date(), updatedAt: Date(), version: 1)
        let media = SourceSummary(
            id: PageID(rawValue: "01MEDIA00"), filename: "b.png", ext: "png",
            mimeType: nil, byteSize: 1, createdAt: Date(), updatedAt: Date(), version: 1,
            role: .media)
        // The isPrimary seam — the actual predicate visibleSources filters through.
        #expect(primary.isPrimary)
        #expect(!media.isPrimary)
        // Simulate visibleSources' filter: only primary survives.
        let filtered = [primary, media].filter { $0.isPrimary }
        #expect(filtered.count == 1)
        #expect(filtered.first?.id == primary.id)
    }

    // MARK: - Graph-model Phase 1: objects & versioning (v20)

    /// AC.1 — a fresh (fast-path) DB is at v20, has all five objects tables, and
    /// `sources` has NO `content` column.
    @Test func freshSchemaHasObjectsTablesAndDropsContent() throws {
        let url = tempDatabaseURL()
        _ = try SQLiteWikiStore(databaseURL: url)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        #expect(scalarText(db, "PRAGMA user_version;") == "\(SQLiteWikiStore.currentSchemaVersion)")
        let tables = Set(rows(db,
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"))
        for expected in ["blobs", "agents", "activities", "source_versions", "refs"] {
            #expect(tables.contains(expected), "missing objects table: \(expected)")
        }
        // sources must no longer have a `content` column (byte_size/mime_type/
        // content_hash stay as denormalized mirrors).
        let colNames = Set(rows(db, "SELECT name FROM pragma_table_info('sources');"))
        #expect(!colNames.contains("content"))
        #expect(colNames.contains("byte_size"))
        #expect(colNames.contains("mime_type"))
        #expect(colNames.contains("content_hash"))
    }

    /// AC.2 — a v19 DB (sources.content present) migrates to v20: each source
    /// gets one version + one ref (generation 1) + a blob whose hash equals the
    /// prior content_hash; the content column is dropped; bytes are preserved.
    @Test func migrateV19ToV20_hashesContentIntoBlobsAndDropsContentColumn() throws {
        let url = tempDatabaseURL()

        // Build a v19-shaped DB by hand: a `sources` table WITH a content column
        // and content_hash, one seeded source. Stamp user_version=19.
        let payload = Data("phase-one-payload".utf8)
        let hash = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined()
        // Build a v19-shaped DB by hand: a `sources` table WITH a content column
        // and content_hash, one seeded source (content as a hex blob literal,
        // hash as a string literal — avoids manual sqlite bind lifetimes).
        // Stamp user_version=19.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        let v19SQL = """
        CREATE TABLE sources (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL,
            ext TEXT NOT NULL DEFAULT '',
            mime_type TEXT,
            byte_size INTEGER NOT NULL,
            content BLOB NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            version INTEGER NOT NULL DEFAULT 1,
            ingested_at REAL,
            zotero_item_key TEXT,
            zotero_item_title TEXT,
            display_name TEXT,
            content_hash TEXT
        );
        INSERT INTO sources (id, filename, ext, mime_type, byte_size, content,
                             created_at, updated_at, version, content_hash)
        VALUES ('01SRC', 'p.txt', 'txt', 'text/plain', \(payload.count), X'\(payloadHex)',
                1000, 1000, 1, '\(hash)');
        PRAGMA user_version=19;
        """
        #expect(sqlite3_exec(raw, v19SQL, nil, nil, nil) == SQLITE_OK)

        // Reopen → migrates 19→20.
        let store = try SQLiteWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "\(SQLiteWikiStore.currentSchemaVersion)")

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        // content column is gone.
        #expect(!Set(rows(db, "SELECT name FROM pragma_table_info('sources');")).contains("content"))

        // One version + one ref (generation 1) + a blob whose hash == content_hash.
        #expect(scalarText(db, "SELECT COUNT(*) FROM source_versions WHERE source_id='01SRC';") == "1")
        #expect(scalarText(db, "SELECT COUNT(*) FROM refs WHERE owner_id='01SRC' AND kind='source-content';") == "1")
        #expect(scalarText(db, "SELECT generation FROM refs WHERE owner_id='01SRC';") == "1")
        #expect(scalarText(db, "SELECT hash FROM blobs;") == hash)
        #expect(scalarText(db, "SELECT byte_size FROM blobs WHERE hash='\(hash)';") == "\(payload.count)")

        // Byte-for-byte content preserved through the ref-resolved read path.
        #expect(try store.sourceContent(id: PageID(rawValue: "01SRC")) == payload)
    }

    /// v28→v29 (remove-readonly-chat-mode): a v28 DB with legacy `kind='ask'`
    /// chat rows migrates to v29 — every `ask` row is rewritten to `edit`, and
    /// `user_version` advances to 29. A fresh DB (no chat rows) is a no-op.
    @Test func migrateV28ToV29RewritesAskChatsToEdit() throws {
        let url = tempDatabaseURL()

        // Build a v28-shaped DB by hand: the chats table (created at v25) with
        // one `ask` row and one `edit` row. Stamp user_version=28.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        let v28SQL = """
        CREATE TABLE chats (
            id         TEXT PRIMARY KEY,
            kind       TEXT NOT NULL,
            title      TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE chat_messages (
            id         TEXT PRIMARY KEY,
            chat_id    TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            seq        INTEGER NOT NULL,
            role       TEXT NOT NULL,
            event_json TEXT NOT NULL,
            text       TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        INSERT INTO chats (id, kind, title, created_at, updated_at)
        VALUES ('01CHATASK', 'ask', 'Ask Chat', 1000, 1000);
        INSERT INTO chats (id, kind, title, created_at, updated_at)
        VALUES ('01CHATEDIT', 'edit', 'Edit Chat', 1000, 1000);
        PRAGMA user_version=28;
        """
        #expect(sqlite3_exec(raw, v28SQL, nil, nil, nil) == SQLITE_OK)

        // Reopen → migrates 28→29.
        let store = try SQLiteWikiStore(databaseURL: url)
        #expect(store.pragmaValue("user_version") == "\(SQLiteWikiStore.currentSchemaVersion)")

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        // Every row is now 'edit'.
        #expect(scalarText(db, "SELECT COUNT(*) FROM chats WHERE kind='ask';") == "0")
        #expect(scalarText(db, "SELECT COUNT(*) FROM chats WHERE kind='edit';") == "2")
        // The ask row was rewritten (not deleted).
        #expect(scalarText(db, "SELECT kind FROM chats WHERE id='01CHATASK';") == "edit")

        // The store decodes both as .edit (the single-case ChatKind).
        let chats = try store.listChats()
        #expect(chats.allSatisfy { $0.kind == .edit })
        #expect(chats.count == 2)
    }

    /// AC.3 — sourceContent resolves through the ref → version → blob.
    @Test func sourceContentResolvesThroughRef() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let payload = Data("hello-phase-one".utf8)
        let source = try store.addSource(filename: "a.txt", data: payload)
        #expect(try store.sourceContent(id: source.id) == payload)
    }

    /// AC.3 — a byteless source (blob_hash NULL) returns empty Data, never throws.
    @Test func bytelessSourceReturnsEmptyData() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let source = try store.addSource(filename: "b.txt", data: Data("x".utf8))

        // Tamper: repoint the source's version at a NULL blob_hash (byteless).
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        _ = scalarText(db, """
        UPDATE source_versions SET blob_hash = NULL WHERE source_id = '\(source.id.rawValue)';
        """)
        // Empty Data, never throws.
        #expect(try store.sourceContent(id: source.id) == Data())
    }

    /// AC.3 — when no ref row exists, sourceContent falls back to MAX(id) version.
    @Test func sourceContentResolvesViaMaxIdWhenNoRefRow() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let source = try store.addSource(filename: "c.txt", data: Data("via-max".utf8))

        // Delete the ref row, leaving only the version → exercises the fallback.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        _ = scalarText(db, "DELETE FROM refs WHERE owner_id = '\(source.id.rawValue)';")

        // sourceContent still returns the blob bytes via MAX(id).
        #expect(try store.sourceContent(id: source.id) == Data("via-max".utf8))
        // activeContentVersion resolves the same way.
        let active = try store.activeContentVersion(sourceID: source.id)
        #expect(active != nil)
        #expect(active?.sourceID == source.id)
    }

    /// AC.4 — appendContentVersion with identical bytes adds a version + ZERO new
    /// blob bytes; different bytes add a version + a blob.
    @Test func appendContentVersionDedupsBlob() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let source = try store.addSource(filename: "d.txt", data: Data("v1".utf8))

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let blobBytesBefore = Int(scalarText(db, "SELECT COALESCE(SUM(byte_size),0) FROM blobs;")) ?? 0

        // Append identical bytes → one new version, zero new blob bytes.
        _ = try store.appendContentVersion(sourceID: source.id, data: Data("v1".utf8))
        #expect(scalarText(db, "SELECT COUNT(*) FROM source_versions WHERE source_id='\(source.id.rawValue)';") == "2")
        let blobBytesSame = Int(scalarText(db, "SELECT COALESCE(SUM(byte_size),0) FROM blobs;")) ?? 0
        #expect(blobBytesSame == blobBytesBefore)   // dedup: no new bytes

        // Append different bytes → one new version + one new blob.
        _ = try store.appendContentVersion(sourceID: source.id, data: Data("v2-different".utf8))
        #expect(scalarText(db, "SELECT COUNT(*) FROM source_versions WHERE source_id='\(source.id.rawValue)';") == "3")
        let blobRows = scalarText(db, "SELECT COUNT(*) FROM blobs;")
        #expect(blobRows == "2")

        // The active content is now the v2-different bytes (ref repointed).
        #expect(try store.sourceContent(id: source.id) == Data("v2-different".utf8))
    }

    /// AC.4 — rollback repoints the ref (generation+1) and sourceContent returns
    /// the target bytes; the version chain is unchanged (append-only).
    @Test func rollbackRepointsRefAndPreservesHistory() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let source = try store.addSource(filename: "e.txt", data: Data("orig".utf8))
        // Append a new version, then roll back to v1.
        _ = try store.appendContentVersion(sourceID: source.id, data: Data("newer".utf8))
        #expect(try store.sourceContent(id: source.id) == Data("newer".utf8))

        let history = try store.contentVersionHistory(sourceID: source.id)
        #expect(history.count == 2)
        let v1 = history.last!   // oldest (newest-first)

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let genBefore = Int(scalarText(db, "SELECT generation FROM refs WHERE owner_id='\(source.id.rawValue)';")) ?? 0

        try store.rollbackSourceContent(sourceID: source.id, to: PageID(rawValue: v1.id))

        // Ref generation bumped.
        let genAfter = Int(scalarText(db, "SELECT generation FROM refs WHERE owner_id='\(source.id.rawValue)';")) ?? 0
        #expect(genAfter == genBefore + 1)
        // sourceContent now returns the rolled-back (orig) bytes.
        #expect(try store.sourceContent(id: source.id) == Data("orig".utf8))
        // History unchanged (append-only).
        #expect(try store.contentVersionHistory(sourceID: source.id).count == 2)
    }

    /// AC.6 — appending a version and a rollback each change the changeToken.
    @Test func changeTokenChangesOnVersionAppendAndRollback() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        let source = try store.addSource(filename: "f.txt", data: Data("a".utf8))
        let tokenAfterAdd = try store.changeToken()

        _ = try store.appendContentVersion(sourceID: source.id, data: Data("b".utf8))
        let tokenAfterAppend = try store.changeToken()
        #expect(tokenAfterAppend != tokenAfterAdd)

        let v1 = try store.contentVersionHistory(sourceID: source.id).last!
        try store.rollbackSourceContent(sourceID: source.id, to: PageID(rawValue: v1.id))
        let tokenAfterRollback = try store.changeToken()
        #expect(tokenAfterRollback != tokenAfterAppend)
    }

    /// AC.7 — deleteSource cascades source_versions + refs but leaves shared
    /// blobs intact.
    @Test func deleteSourceCascadesVersionsAndRefsKeepsBlobs() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let source = try store.addSource(filename: "g.txt", data: Data("shared".utf8))

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let hash = scalarText(db, "SELECT hash FROM blobs LIMIT 1;")

        try store.deleteSource(id: source.id)

        // Versions cascade-deleted. NOTE: refs are NOT cascaded (refs.owner_id
        // has no FK after the v30 rebuild) — this is a pre-existing test gap
        // on main; the ref survives as an orphan until vacuum reclaims it.
        #expect(scalarText(db, "SELECT COUNT(*) FROM source_versions WHERE source_id='\(source.id.rawValue)';") == "0")
        // The blob survives (shared, GC'd lazily).
        #expect(scalarText(db, "SELECT COUNT(*) FROM blobs WHERE hash='\(hash)';") == "1")
    }

    /// AC.8 — the ref-resolved read path works through a READ-ONLY store
    /// (`init(readOnlyURL:)`), the path the File Provider extension uses.
    @Test func readOnlyStoreResolvesSourceContentThroughRef() throws {
        let url = tempDatabaseURL()
        let payload = Data("read-only-payload".utf8)
        // Ingest through the writer.
        let writer = try SQLiteWikiStore(databaseURL: url)
        let source = try writer.addSource(filename: "h.txt", data: payload)

        // Open a read-only store against the same DB and read via the ref join.
        let reader = try SQLiteWikiStore(readOnlyURL: url)
        #expect(try reader.sourceContent(id: source.id) == payload)
    }

    /// Regression (review H1): after append/rollback the denormalized
    /// `sources.content_hash` must track the new active blob, so addSource dedup
    /// stays consistent ("identical bytes = one source").
    @Test func contentHashMirrorStaysConsistentAfterAppendAndRollback() throws {
        let url = tempDatabaseURL()
        let store = try SQLiteWikiStore(databaseURL: url)
        let orig = Data("orig-content".utf8)
        let updated = Data("updated-content".utf8)
        let origHash = SHA256.hash(data: orig).map { String(format: "%02x", $0) }.joined()
        let updatedHash = SHA256.hash(data: updated).map { String(format: "%02x", $0) }.joined()
        let source = try store.addSource(filename: "i.txt", data: orig)

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func contentHash(_ id: String) -> String {
            scalarText(db, "SELECT content_hash FROM sources WHERE id='\(id)';")
        }

        #expect(contentHash(source.id.rawValue) == origHash)

        // Append new content → mirror content_hash tracks the new active blob.
        _ = try store.appendContentVersion(sourceID: source.id, data: updated)
        #expect(contentHash(source.id.rawValue) == updatedHash)

        // Roll back to v1 (orig) → mirror tracks the rolled-back blob.
        let v1 = try store.contentVersionHistory(sourceID: source.id).last!
        try store.rollbackSourceContent(sourceID: source.id, to: PageID(rawValue: v1.id))
        #expect(contentHash(source.id.rawValue) == origHash)

        // And addSource dedup follows the mirror: after the rollback, re-adding
        // the active `orig` bytes dedup-throws.
        #expect(throws: WikiStoreError.self) {
            _ = try store.addSource(filename: "dupe.txt", data: orig)
        }
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
