import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Store-boundary enforcement of `WikiNameRules` plus the v17→18 one-time
/// sweep of pre-existing rows.
struct WikiNameSanitizationStoreTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-namerules-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempStore() throws -> GRDBWikiStore {
        try GRDBWikiStore(databaseURL: tempDir().appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - Write-boundary enforcement

    @Test func createPageSanitizesTitle() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "[Draft] A | B]")
        #expect(page.title == "(Draft) A - B)")
        #expect(try store.getPage(id: page.id).title == "(Draft) A - B)")
    }

    @Test func updatePageSanitizesTitle() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Clean")
        try store.updatePage(id: page.id, title: "#Now | Tagged", body: "x")
        #expect(try store.getPage(id: page.id).title == "Now - Tagged")
    }

    @Test func renameSourceSanitizesDisplayName() throws {
        let store = try tempStore()
        let src = try store.addSource(filename: "doc.md", data: Data("hi".utf8))
        try store.renameSource(id: src.id, to: "New | Name]")
        let renamed = try store.getSource(id: src.id)
        #expect(renamed.displayName == "New - Name)")
    }

    @Test func addSourceWithUnlinkableFilenameGetsSanitizedDisplayName() throws {
        let store = try tempStore()
        // No richer metadata → the citable name would fall back to the raw
        // filename, which is unlinkable — so its sanitized form is stored as
        // the display name while the filename stays verbatim.
        let src = try store.addSource(filename: "notes|v1].txt", data: Data("hi".utf8))
        let stored = try store.getSource(id: src.id)
        #expect(stored.filename == "notes|v1].txt")
        #expect(stored.displayName == "notes-v1).txt")
        #expect(try store.resolveSourceByName("notes-v1).txt") == src.id)
    }

    @Test func addSourceWithLinkableFilenameKeepsNilDisplayName() throws {
        let store = try tempStore()
        let src = try store.addSource(filename: "doc.pdf", data: Data("%PDF".utf8))
        #expect(try store.getSource(id: src.id).displayName == nil)
    }

    @Test func upsertOfUnlinkableTitleDoesNotDuplicate() throws {
        let store = try tempStore()
        // The raw title sanitizes to the same stored title both times — the
        // second upsert must UPDATE, not create a second page.
        let first = try PageUpsert.upsert(in: store, id: nil, title: "A | B", body: "one")
        let second = try PageUpsert.upsert(in: store, id: nil, title: "A | B", body: "two")
        #expect(first.didCreate)
        #expect(!second.didCreate)
        #expect(second.id == first.id)
        #expect(try store.getPage(id: first.id).title == "A - B")
        #expect(try store.getPage(id: first.id).bodyMarkdown == "two")
    }

    // MARK: - v17 → 18 migration sweep

    @Test func migrationSanitizesPreexistingNames() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("WikiFS.sqlite")

        var pageID: PageID?
        var sourceID: PageID?
        do {
            // Fresh v18 store with clean rows, released at scope end so the
            // raw connection below sees a closed database.
            let store = try GRDBWikiStore(databaseURL: url)
            pageID = try store.createPage(title: "Clean Page").id
            sourceID = try store.addSource(filename: "doc.md", data: Data("hi".utf8)).id
        }

        // Tamper via a raw connection: plant pre-rule dirty names and rewind
        // the stamp to v17, simulating a database written before the rule.
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        for sql in [
            "UPDATE pages SET title = '[Draft] Bad | #Title';",
            "UPDATE sources SET display_name = 'Foo | Bar]';",
            "PRAGMA user_version=17;",
        ] {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, Comment(rawValue: sql))
        }
        sqlite3_close(db)

        // Reopen → the 17→18 step sweeps the dirty names.
        let reopened = try GRDBWikiStore(databaseURL: url)
        #expect(reopened.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        let page = try reopened.getPage(id: pageID!)
        #expect(page.title == "(Draft) Bad - #Title") // inner # is fine, kept
        #expect(try reopened.getSource(id: sourceID!).displayName == "Foo - Bar)")
    }

    @Test func migrationLeavesCleanNamesUntouched() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("WikiFS.sqlite")

        var pageID: PageID?
        var pageVersion: Int?
        do {
            let store = try GRDBWikiStore(databaseURL: url)
            let page = try store.createPage(title: "C# Guide") // # inside: linkable
            pageID = page.id
            pageVersion = page.version
        }

        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=17;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let reopened = try GRDBWikiStore(databaseURL: url)
        let page = try reopened.getPage(id: pageID!)
        #expect(page.title == "C# Guide")
        #expect(page.version == pageVersion!) // no gratuitous version bump
    }
}
