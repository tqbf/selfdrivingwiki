import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// Legacy payload recovery must retain the source namespace after a queue DB
/// is closed and reopened, the same lifecycle used during application restart.
struct QueueRestartTests {

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-restart-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("queue.sqlite")
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw QueueStoreError.open("could not open queue fixture database")
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw QueueStoreError.sqlite(code: -1, message: "could not update queue fixture")
        }
    }

    @Test func legacySourcePayloadRecoversAsSourceID() throws {
        let databaseURL = try temporaryDatabaseURL()
        let itemID: QueueItem.ID
        do {
            let store = try QueueStore(databaseURL: databaseURL)
            itemID = try store.enqueue(
                QueueItemRequest(
                    queue: .extraction,
                    wikiID: WikiID(rawValue: "legacy-wiki"),
                    payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "new-source")])
                )
            ).id
            store.close()
        }

        try execute(
            "UPDATE queue_items SET payload = '{\"sourceIDs\":[\"LEGACY-SOURCE-ID\"]}' WHERE id = '\(itemID.rawValue)';",
            at: databaseURL
        )

        let reopened = try QueueStore(databaseURL: databaseURL)
        let recovered = try #require(try reopened.getItem(itemID))
        #expect(recovered.payload.sourceIDs == [SourceID(rawValue: "LEGACY-SOURCE-ID")])
    }
}
