import Foundation
import Testing
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
@testable import WikiFSCore

@Suite struct SchemaMigrationLadderTests {
    @Test func freshSchemaContainsOKFTrustTablesAndIndexes() throws {
        let store = try TestStoreFactory.inMemory()
        for table in [
            "page_okf_metadata", "source_markdown_okf_metadata",
            "page_okf_verifications", "source_markdown_okf_verifications"
        ] {
            #expect(store.scalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(table)';") == "1")
        }
        for index in [
            "page_okf_verifications_target_order",
            "source_markdown_okf_verifications_target_order",
            "page_okf_verifications_activity",
            "source_markdown_okf_verifications_activity"
        ] {
            #expect(store.scalarText(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='\(index)';") == "1")
        }
        #expect(store.pragmaValue("user_version") == "53")
    }

    @Test func v51MigratesWithoutBackfillOrDataLoss() throws {
        let fixture = try v51Fixture()
        let migrated = try GRDBWikiStore(databaseURL: fixture.url)
        #expect(migrated.pragmaValue("user_version") == "53")
        #expect(try migrated.getPage(id: fixture.pageID).title == "Historical page")
        #expect(try migrated.getSource(id: fixture.sourceID).filename == "historical.txt")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM page_okf_metadata;") == "0")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM source_markdown_okf_metadata;") == "0")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM page_okf_verifications;") == "0")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM source_markdown_okf_verifications;") == "0")
    }

    @Test func v52DBWithChatSummaryColumnsMigratesToV53() throws {
        // A v52 database still carries `chats.summary`/`summary_at` (the
        // mirrored one-line answer summary). Reintroduce them by hand on a
        // file-backed store, stamp back to 52, and reopen: the migration
        // must drop both columns and stamp 53.
        let pair = try TestStoreFactory.fileBacked(prefix: "schema-v53")
        pair.store.close()
        try MetadataSQLiteFixtureSupport.execute("""
        ALTER TABLE chats ADD COLUMN summary TEXT;
        ALTER TABLE chats ADD COLUMN summary_at REAL;
        INSERT INTO chats (id, kind, title, created_at, updated_at, summary, summary_at)
        VALUES ('survivor', 'edit', 'Survivor', 1, 1, 'tainted summary', 2);
        INSERT INTO chat_messages (id, chat_id, seq, role, event_json, text, created_at)
        VALUES ('m1', 'survivor', 0, 'user', '{"userText":{"_0":"Why?"}}', 'Why?', 1);
        PRAGMA user_version = 52;
        """, at: pair.url)

        let migrated = try GRDBWikiStore(databaseURL: pair.url)
        #expect(migrated.pragmaValue("user_version") == "53")
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chats') WHERE name IN ('summary', 'summary_at');") == "0")
        // The drop must not lose the rows the columns rode on (F12b).
        #expect(migrated.scalarText(
            "SELECT title FROM chats WHERE id = 'survivor';") == "Survivor")
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM chat_messages WHERE chat_id = 'survivor';") == "1")
    }

    @Test func v52MigrationEnforcesTargetForeignKeysAndStatusChecks() throws {
        let fixture = try v51Fixture()
        let migrated = try GRDBWikiStore(databaseURL: fixture.url)
        migrated.close()
        #expect(try MetadataSQLiteFixtureSupport.executeResult("""
        PRAGMA foreign_keys = ON;
        INSERT INTO page_okf_metadata
          (page_version_id, status, projection_revision, updated_at)
        VALUES ('missing-page-version', 'draft', 0, 1);
        """, at: fixture.url) == SQLITE_CONSTRAINT)
        #expect(try MetadataSQLiteFixtureSupport.executeResult("""
        PRAGMA foreign_keys = ON;
        INSERT INTO page_okf_metadata
          (page_version_id, status, projection_revision, updated_at)
        VALUES ('\(fixture.pageVersionID.rawValue)', 'active', 0, 1);
        """, at: fixture.url) == SQLITE_CONSTRAINT)
        #expect(try MetadataSQLiteFixtureSupport.executeResult("""
        PRAGMA foreign_keys = ON;
        INSERT INTO source_markdown_okf_metadata
          (source_markdown_version_id, status, projection_revision, updated_at)
        VALUES ('\(fixture.pageVersionID.rawValue)', 'draft', 0, 1);
        """, at: fixture.url) == SQLITE_CONSTRAINT)
    }

    @Test func v52DatabaseReopensIdempotently() throws {
        let fixture = try v51Fixture()
        var store: GRDBWikiStore? = try GRDBWikiStore(databaseURL: fixture.url)
        try store?.setPageOKFStatus(versionID: fixture.pageVersionID, status: .stable)
        store?.close()
        store = nil

        let reopened = try GRDBWikiStore(databaseURL: fixture.url)
        #expect(reopened.pragmaValue("user_version") == "53")
        #expect(try reopened.pageOKFMetadata(
            versionID: fixture.pageVersionID, includeCorrected: false)?.metadata.status == .stable)
    }

    private struct Fixture {
        let url: URL
        let pageID: PageID
        let pageVersionID: PageVersionID
        let sourceID: SourceID
    }

    private func v51Fixture() throws -> Fixture {
        let pair = try TestStoreFactory.fileBacked(prefix: "schema-v52")
        let page = try pair.store.createPage(title: "Historical page")
        let pageVersionID = try #require(try pair.store.pageHeadVersionID(pageID: page.id))
        let source = try pair.store.addSource(
            filename: "historical.txt", data: Data("historical".utf8))
        _ = try pair.store.appendProcessedMarkdown(
            sourceID: source.id, content: "processed", origin: .user,
            note: nil, technique: nil)
        pair.store.close()
        try MetadataSQLiteFixtureSupport.execute("""
        PRAGMA foreign_keys = OFF;
        DROP TABLE source_markdown_okf_verifications;
        DROP TABLE page_okf_verifications;
        DROP TABLE source_markdown_okf_metadata;
        DROP TABLE page_okf_metadata;
        PRAGMA user_version = 51;
        """, at: pair.url)
        return .init(
            url: pair.url, pageID: page.id,
            pageVersionID: pageVersionID, sourceID: source.id)
    }
}
