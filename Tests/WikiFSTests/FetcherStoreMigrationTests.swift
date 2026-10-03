import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// AC.7 — the v54→v55 schema migration (fetcher packages).
///
/// v54 stored the retained Zotero-named provenance columns
/// (`zotero_item_key`/`zotero_item_title`) on `sources`. v55 renames them
/// to the provider-neutral `external_item_key`/`external_item_title` (the
/// values move with the rename — nothing drops), adds the fetch lifecycle
/// (`fetch_state` + `fetch_producer`), and backfills byteless
/// `application/zotero` rows the sync created before this schema to
/// `pending` so they remain fetchable.
///
/// The fixture reuses the proven ladder pattern: create a current
/// file-backed store, close it, reshape it back to v54 by hand (rename the
/// two columns back, drop the lifecycle columns, stamp `user_version` =
/// 54), then reopen through `GRDBWikiStore(databaseURL:)` so the real
/// migration ladder runs.
@Suite("Fetcher store migration", .serialized, .timeLimit(.minutes(2)))
struct FetcherStoreMigrationTests {

    // MARK: - v54 → v55

    @Test func v54DatabaseMigratesToV55PreservingZoteroProvenance() throws {
        let pair = try TestStoreFactory.fileBacked(prefix: "fetcher-v55")
        pair.store.close()
        try MetadataSQLiteFixtureSupport.execute("""
        -- Reshape back to the real v54 `sources` shape.
        ALTER TABLE sources RENAME COLUMN external_item_key TO zotero_item_key;
        ALTER TABLE sources RENAME COLUMN external_item_title TO zotero_item_title;
        ALTER TABLE sources DROP COLUMN fetch_state;
        ALTER TABLE sources DROP COLUMN fetch_producer;

        -- One row carrying Zotero-named provenance, one byteless sync row,
        -- one ordinary byte-bearing row.
        INSERT INTO sources
          (id, filename, ext, mime_type, byte_size, created_at, updated_at, version,
           zotero_item_key, zotero_item_title, role)
        VALUES
          ('zotero-row', 'ABCD1234', '', 'application/zotero', 0, 1, 1, 1,
           'ZKEY01', 'Old Zotero Title', 'primary'),
          ('byteless-row', 'SYNC2', '', 'application/zotero', 0, 1, 1, 1,
           NULL, NULL, 'primary'),
          ('bytes-row', 'paper.pdf', 'pdf', 'application/pdf', 100, 1, 1, 1,
           NULL, NULL, 'primary');

        PRAGMA user_version = 54;
        """, at: pair.url)

        let migrated = try GRDBWikiStore(databaseURL: pair.url)
        #expect(migrated.pragmaValue("user_version") == "56")
        #expect(GRDBWikiStore.schemaVersion == 56)

        // The neutral columns exist; the Zotero-named ones are gone.
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('sources') WHERE name IN ('external_item_key', 'external_item_title');"
        ) == "2")
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('sources') WHERE name IN ('zotero_item_key', 'zotero_item_title');"
        ) == "0")

        // The renamed values moved with the rename — readable through the
        // store's neutral surface.
        let summaries = try migrated.listSources()
        let zoteroRow = try #require(summaries.first { $0.filename == "ABCD1234" })
        #expect(zoteroRow.externalItemKey == "ZKEY01")
        #expect(zoteroRow.externalItemTitle == "Old Zotero Title")

        // Backfill: every pre-schema byteless application/zotero row is
        // `pending` (still fetchable); a byte-bearing row never was a fetch
        // source.
        let zoteroState = try #require(try migrated.fetchState(
            sourceID: zoteroRow.id))
        #expect(zoteroState == .pending)
        let bytelessRow = try #require(summaries.first { $0.filename == "SYNC2" })
        #expect(try migrated.fetchState(sourceID: bytelessRow.id) == .pending)
        let bytesRow = try #require(summaries.first { $0.filename == "paper.pdf" })
        #expect(try migrated.fetchState(sourceID: bytesRow.id) == nil)

        // Idempotent: close and reopen — still 55, values unchanged.
        migrated.close()
        let reopened = try GRDBWikiStore(databaseURL: pair.url)
        #expect(reopened.pragmaValue("user_version") == "56")
        let reopenedZotero = try #require(try reopened.listSources().first {
            $0.filename == "ABCD1234"
        })
        #expect(reopenedZotero.externalItemKey == "ZKEY01")
        #expect(try reopened.fetchState(sourceID: reopenedZotero.id) == .pending)
    }

    // MARK: - Fresh-schema path (the fallback contract)

    /// Even on a fresh database the same lifecycle contract holds end to
    /// end: a byteless fetch source starts `pending`, acquiring bytes
    /// writes `formatJobPending`, and settlement writes `complete`.
    @Test func freshSchemaFetchLifecycleAdvances() throws {
        let store = try TestStoreFactory.inMemory()
        #expect(store.pragmaValue("user_version") == "56")

        let summary = try store.addBytelessSource(
            filename: "ABCD1234",
            mimeType: ContentTypeRegistry.zoteroAttachment,
            provenance: SourceProvenance(
                agentName: "zotero",
                activityKind: "fetch",
                plan: "https://api.zotero.org/users/12345/items/ABCD1234/file",
                externalRef: "https://api.zotero.org/users/12345/items/ABCD1234/file",
                externalIdentity: "ABCD1234"),
            role: .primary)
        #expect(try store.fetchState(sourceID: summary.id) == .pending)

        _ = try store.attachAcquiredBytes(
            sourceID: summary.id,
            bytes: Data("%PDF-1.4 fresh".utf8),
            mimeType: "application/pdf",
            originalFilename: "paper.pdf",
            externalItemKey: "PARENT30",
            externalItemTitle: "A Study of Extraction",
            producer: nil)
        #expect(try store.fetchState(sourceID: summary.id) == .formatJobPending)

        try store.markFetchComplete(sourceID: summary.id)
        #expect(try store.fetchState(sourceID: summary.id) == .complete)
    }
}
