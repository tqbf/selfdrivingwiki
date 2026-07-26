import Foundation
import Testing
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
@testable import WikiFSCore

/// Tests for the read-only (`query_only`) store the File Provider extension
/// uses: it reads what the writer produced, and rejects writes.
struct ReadOnlyStoreTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ro-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    @Test func readsBackWriterContent() throws {
        let url = tempDatabaseURL()
        let id: PageID
        do {
            let writer = try GRDBWikiStore(databaseURL: url)
            let page = try writer.createPage(title: "Home")
            id = page.id
            try writer.updatePage(id: id, title: "Home", body: "# Welcome\n\nlive body")
        }

        let reader = try GRDBWikiStore(readOnlyURL: url)
        let page = try reader.getPage(id: id)
        #expect(page.title == "Home")
        #expect(page.bodyMarkdown == "# Welcome\n\nlive body")

        let summaries = try reader.listPages(sortBy: .lastUpdated)
        #expect(summaries.contains { $0.id == id })

        let all = try reader.listAllPagesOrderedByID()
        #expect(all.count == 1)
        #expect(all.first?.id == id)
    }

    @Test func enumeratesMultiplePagesOrderedByID() throws {
        let url = tempDatabaseURL()
        let writer = try GRDBWikiStore(databaseURL: url)
        let a = try writer.createPage(title: "Alpha")
        let b = try writer.createPage(title: "Bravo")

        let reader = try GRDBWikiStore(readOnlyURL: url)
        let ids = try reader.listAllPagesOrderedByID().map(\.id.rawValue)
        // ULIDs sort lexicographically in creation order.
        #expect(ids == [a.id.rawValue, b.id.rawValue].sorted())
    }

    @Test func rejectsWrites() throws {
        let url = tempDatabaseURL()
        let page: WikiPage
        do {
            let writer = try GRDBWikiStore(databaseURL: url)
            page = try writer.createPage(title: "Home")
        }

        let reader = try GRDBWikiStore(readOnlyURL: url)
        // query_only=ON must reject the write at the SQLite layer.
        #expect(throws: (any Error).self) {
            try reader.updatePage(id: page.id, title: "Hacked", body: "nope")
        }
        #expect(throws: (any Error).self) {
            _ = try reader.createPage(title: "Should Fail")
        }
    }

    // MARK: - not-yet-migrated schema (#931)

    /// A read-only connection opened against a DB that hasn't been migrated to
    /// v43+ (missing `acp_session_id`) or v45+ (missing `model_provider_id` /
    /// `model_id`) must NOT throw "no such column" on chat queries — it should
    /// return an empty / not-found result, mirroring the `wikiIndexDocument()`
    /// graceful fallback. Without the guard this busy-loops ~50 times/sec in
    /// the File Provider extension (#931).
    @Test func chatQueriesDontThrowOnPreMigrationSchema() throws {
        let url = tempDatabaseURL()

        // Build a v42 DB by hand: a `chats` table WITHOUT the v43/v45 columns.
        var raw: OpaquePointer?
        #expect(sqlite3_open(url.path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, """
        CREATE TABLE chats (id TEXT PRIMARY KEY, kind TEXT, title TEXT,
            created_at REAL, updated_at REAL, summary TEXT, summary_at REAL);
        """, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(raw, """
        CREATE TABLE chat_messages (id TEXT PRIMARY KEY, chat_id TEXT, seq INTEGER,
            role TEXT, event_json TEXT, text TEXT, created_at REAL,
            summary TEXT, summary_kind TEXT, summary_at REAL);
        """, nil, nil, nil) == SQLITE_OK)
        // Insert a chat row so we can verify the guard fires (not just empty table).
        #expect(sqlite3_exec(raw, """
        INSERT INTO chats (id, kind, title, created_at, updated_at)
        VALUES ('01TEST0000000000000000000A', 'edit', 'Old Chat', 1000.0, 1000.0);
        """, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(raw, "PRAGMA user_version = 42;", nil, nil, nil) == SQLITE_OK)

        // Open read-only — the File Provider extension path.
        let reader = try GRDBWikiStore(readOnlyURL: url)

        // listAllChatsOrderedByID: returns [] instead of throwing.
        let ordered = try reader.listAllChatsOrderedByID()
        #expect(ordered.isEmpty)

        // listChats: returns [] instead of throwing.
        let listed = try reader.listChats()
        #expect(listed.isEmpty)

        // getChat: throws notFound instead of "no such column".
        let chatID = PageID(rawValue: "01TEST0000000000000000000A")
        #expect(throws: WikiStoreError.self) {
            _ = try reader.getChat(id: chatID)
        }
    }
}
