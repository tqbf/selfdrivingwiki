import Foundation
import Testing
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
@testable import WikiFSCore

@Suite struct SchemaV52MigrationTests {
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
        #expect(store.pragmaValue("user_version") == "52")
    }

    @Test func v51MigratesWithoutBackfillOrDataLoss() throws {
        let fixture = try v51Fixture()
        let migrated = try GRDBWikiStore(databaseURL: fixture.url)
        #expect(migrated.pragmaValue("user_version") == "52")
        #expect(try migrated.getPage(id: fixture.pageID).title == "Historical page")
        #expect(try migrated.getSource(id: fixture.sourceID).filename == "historical.txt")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM page_okf_metadata;") == "0")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM source_markdown_okf_metadata;") == "0")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM page_okf_verifications;") == "0")
        #expect(migrated.scalarText("SELECT COUNT(*) FROM source_markdown_okf_verifications;") == "0")
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
        #expect(reopened.pragmaValue("user_version") == "52")
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
