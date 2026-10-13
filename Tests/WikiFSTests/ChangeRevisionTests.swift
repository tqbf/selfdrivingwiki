import Foundation
import Testing
@testable import WikiFSCore

/// The v57 change revision. The change token folds COUNT and SUM(version) per
/// table, so two writes can cancel out and leave it unchanged; the File
/// Provider then reports "nothing changed" and the mount drifts. The revision
/// only increases, on every write to a covered table, and is the token's
/// last field.
@Suite(.serialized)
struct ChangeRevisionTests {

    private func makeStore(prefix: String) throws -> (store: GRDBWikiStore, url: URL) {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tmp/change-revision-tests", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("WikiFS.sqlite")
        return (try GRDBWikiStore(databaseURL: url), url)
    }

    private func cleanup(_ store: GRDBWikiStore, url: URL) {
        store.close()
        do {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } catch {
            DebugLog.store("Change revision test fixture cleanup failed: \(error)")
        }
    }

    /// The trigger names present in `store`'s schema.
    private func triggerNames(in store: GRDBWikiStore) -> Set<String> {
        let joined = store.scalarText(
            "SELECT group_concat(name, ',') FROM sqlite_master WHERE type = 'trigger';")
        return Set(joined.split(separator: ",").map(String.init))
    }

    private func expectAllTriggers(in store: GRDBWikiStore) {
        let names = triggerNames(in: store)
        for table in GRDBWikiStore.changeRevisionTables {
            for operation in ["ai", "au", "ad"] {
                let name = GRDBWikiStore.changeRevisionTriggerName(table: table, operation: operation)
                #expect(names.contains(name), "missing trigger \(name)")
            }
        }
    }

    // MARK: - The collision

    /// Delete a page at version 1, create a new page at version 1: COUNT and
    /// SUM(version) are both unchanged. The token must still change.
    @Test func deleteThenCreatePageChangesTheToken() throws {
        let (store, url) = try makeStore(prefix: "page-collision")
        defer { cleanup(store, url: url) }
        let first = try store.createPage(title: "First")
        let before = try store.changeToken()

        try store.deletePage(id: first.id)
        let second = try store.createPage(title: "Second")
        let after = try store.changeToken()

        #expect(second.version == first.version)
        // The folds collide — this is the bug the revision fixes.
        #expect(after.pages == before.pages)
        #expect(after.changeRevision > before.changeRevision)
        #expect(after.rawString != before.rawString)
    }

    /// The chat fold is two counts; delete-then-create collides the same way.
    @Test func deleteThenCreateChatChangesTheToken() throws {
        let (store, url) = try makeStore(prefix: "chat-collision")
        defer { cleanup(store, url: url) }
        let first = try store.createChat(kind: .edit, title: "First")
        let before = try store.changeToken()

        try store.deleteChat(id: first.id)
        _ = try store.createChat(kind: .edit, title: "Second")
        let after = try store.changeToken()

        #expect(after.chat == before.chat)
        #expect(after.rawString != before.rawString)
    }

    /// A content edit that does not touch any fold's inputs still moves the
    /// revision (UPDATE triggers), and the revision never goes down.
    @Test func everyWriteAdvancesTheRevision() throws {
        let (store, url) = try makeStore(prefix: "monotonic")
        defer { cleanup(store, url: url) }
        var last = try store.changeToken().changeRevision
        let page = try store.createPage(title: "Page")
        for step in 0..<3 {
            try store.updatePage(id: page.id, title: "Page", body: "body \(step)")
            let now = try store.changeToken().changeRevision
            #expect(now > last)
            last = now
        }
        try store.deletePage(id: page.id)
        #expect(try store.changeToken().changeRevision > last)
    }

    // MARK: - Schema

    /// A fresh DB has the revision row and every covered table's triggers,
    /// and every covered table exists (a stale table list would fail here).
    @Test func freshSchemaHasEveryTrigger() throws {
        let (store, url) = try makeStore(prefix: "fresh")
        defer { cleanup(store, url: url) }

        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(store.scalarText("SELECT revision FROM change_revision WHERE id = 1;") == "0")
        for table in GRDBWikiStore.changeRevisionTables {
            #expect(store.scalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)';") == "1",
                    "covered table \(table) missing from the fresh schema")
        }
        expectAllTriggers(in: store)
    }

    /// A v56 DB (no revision table, no triggers) migrates to v57 with both,
    /// and its existing rows are untouched.
    @Test func v56DatabaseMigratesToTheRevision() throws {
        let (store, url) = try makeStore(prefix: "v56")
        defer { cleanup(store, url: url) }
        let page = try store.createPage(title: "Kept")
        store.close()

        var rewind = "DROP TABLE IF EXISTS change_revision;\n"
        for table in GRDBWikiStore.changeRevisionTables {
            for operation in ["ai", "au", "ad"] {
                rewind += "DROP TRIGGER IF EXISTS \(GRDBWikiStore.changeRevisionTriggerName(table: table, operation: operation));\n"
            }
        }
        rewind += "PRAGMA user_version = 56;"
        try MetadataSQLiteFixtureSupport.execute(rewind, at: url)

        let migrated = try GRDBWikiStore(databaseURL: url)
        defer { migrated.close() }
        #expect(migrated.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        expectAllTriggers(in: migrated)
        #expect(try migrated.getPage(id: page.id).title == "Kept")

        let before = try migrated.changeToken().changeRevision
        _ = try migrated.createPage(title: "New")
        #expect(try migrated.changeToken().changeRevision > before)
    }

    /// SQLite drops a table's triggers with the table. A later migration that
    /// rebuilds a covered table would lose them; any ladder run re-creates
    /// whatever is missing.
    @Test func ladderRunRestoresDroppedTriggers() throws {
        let (store, url) = try makeStore(prefix: "rebuild")
        defer { cleanup(store, url: url) }
        store.close()

        let dropped = GRDBWikiStore.changeRevisionTriggerName(table: "pages", operation: "ad")
        try MetadataSQLiteFixtureSupport.execute("""
        DROP TRIGGER \(dropped);
        PRAGMA user_version = 56;
        """, at: url)

        let reopened = try GRDBWikiStore(databaseURL: url)
        defer { reopened.close() }
        expectAllTriggers(in: reopened)
    }
}
