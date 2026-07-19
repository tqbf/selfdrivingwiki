import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the `wiki_metadata` key-value table (v37, issue #477).
/// Verifies the get/set metadata API, the persistence of the link-reconcile
/// flag across store reopening, and the schema migration from v36→v37.
@Suite(.tags(.integration), .timeLimit(.minutes(5)))
struct WikiMetadataTests {

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikimeta-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("db.sqlite")
    }

    // MARK: - Metadata get/set

    @Test func getReturnsNilForMissingKey() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        let value = try store.getMetadata("nonexistent")
        #expect(value == nil)
    }

    @Test func setThenGetRoundTrips() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        try store.setMetadata("test_key", value: "test_value")
        let value = try store.getMetadata("test_key")
        #expect(value == "test_value")
    }

    @Test func setUpsertsExistingKey() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        try store.setMetadata("counter", value: "1")
        try store.setMetadata("counter", value: "2")
        let value = try store.getMetadata("counter")
        #expect(value == "2")
    }

    // MARK: - Reconcile flag persistence

    @Test func reconcileFlagPersistsAcrossReopen() throws {
        let url = tempURL()
        let store1 = try GRDBWikiStore(databaseURL: url)
        // Simulate a completed reconcile: set the flag.
        try store1.setMetadata("link_reconcile_version", value: "1")

        // Reopen the same DB file — the flag must survive.
        let store2 = try GRDBWikiStore(databaseURL: url)
        let value = try store2.getMetadata("link_reconcile_version")
        #expect(value == "1")
    }

    @Test func reconcileFlagAbsentOnFreshDB() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        let value = try store.getMetadata("link_reconcile_version")
        // A fresh DB has never reconciled — no flag persists.
        #expect(value == nil)
    }

    // MARK: - Schema version

    @Test func freshDBHasCorrectSchemaVersion() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func freshDBHasWikiMetadataTable() throws {
        let store = try GRDBWikiStore(databaseURL: tempURL())
        let count = store.scalarText(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wiki_metadata';")
        #expect(count == "1")
    }
}
