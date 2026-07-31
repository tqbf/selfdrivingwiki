import Foundation
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
import Testing
@testable import WikiFSCore

/// SQLite-level acceptance tests for every v48 CHECK and FK. These use a
/// file-backed fresh v48 schema and leave enforcement on for every rejection.
struct SchemaV48ConstraintTests {
    private func freshURL(_ prefix: String = "schema-v48-constraint") throws -> URL {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: prefix)
        let store = try GRDBWikiStore(databaseURL: url)
        store.close()
        return url
    }

    private func chatInsertResult(_ extraColumns: String, _ extraValues: String) throws -> Int32 {
        let url = try freshURL()
        return try MetadataSQLiteFixtureSupport.executeResult("""
        PRAGMA foreign_keys = ON;
        INSERT INTO chats (id, kind, title, created_at, updated_at)
        VALUES ('chat', 'edit', 'Chat', 1, 1);
        INSERT INTO chat_turns
          (chat_id, turn_id, command_id, ordinal, state, user_text, context_refs_json, submitted_at\(extraColumns))
        VALUES ('chat', 'turn', 'command', 0, 'queued', 'text', '[]', 1\(extraValues));
        """, at: url)
    }

    private func preparedPageAndSource() throws -> (URL, PageVersionID, SourceID) {
        let url = try freshURL("schema-v48-relations")
        let store = try GRDBWikiStore(databaseURL: url)
        let page = try store.createPage(title: "Evidence")
        let version = try #require(try store.pageHeadVersionID(pageID: page.id))
        let source = try store.addSource(filename: "evidence.txt", data: Data("evidence".utf8))
        store.close()
        return (url, version, source.id)
    }

    @Test func chatCheckRejectsNegativeInputTokens() throws {
        #expect(try chatInsertResult(", input_tokens", ", -1") == SQLITE_CONSTRAINT)
    }

    @Test func chatCheckRejectsNegativeOutputTokens() throws {
        #expect(try chatInsertResult(", output_tokens", ", -1") == SQLITE_CONSTRAINT)
    }

    @Test func chatCheckRejectsNegativeThoughtTokens() throws {
        #expect(try chatInsertResult(", thought_tokens", ", -1") == SQLITE_CONSTRAINT)
    }

    @Test func chatCheckRejectsNegativeCacheReadTokens() throws {
        #expect(try chatInsertResult(", cache_read_tokens", ", -1") == SQLITE_CONSTRAINT)
    }

    @Test func chatCheckRejectsNegativeCacheWriteTokens() throws {
        #expect(try chatInsertResult(", cache_write_tokens", ", -1") == SQLITE_CONSTRAINT)
    }

    @Test func chatCheckRejectsCostWithoutCurrency() throws {
        #expect(try chatInsertResult(", cost_decimal", ", '1.25'") == SQLITE_CONSTRAINT)
    }

    @Test func chatChecksRejectFinishBeforeStart() throws {
        #expect(try chatInsertResult(", claimed_at, finished_at", ", 10, 9") == SQLITE_CONSTRAINT)
    }

    @Test func roleCheckRejectsUnknownValue() throws {
        let (url, version, sourceID) = try preparedPageAndSource()
        #expect(try MetadataSQLiteFixtureSupport.executeResult("""
        PRAGMA foreign_keys = ON;
        INSERT INTO page_version_sources VALUES ('\(version.rawValue)', '\(sourceID.rawValue)', 'untrusted');
        """, at: url) == SQLITE_CONSTRAINT)
    }

    @Test func workspaceRefSourcesHasCompositeForeignKey() throws {
        let (url, _, sourceID) = try preparedPageAndSource()
        #expect(try MetadataSQLiteFixtureSupport.executeResult("""
        PRAGMA foreign_keys = ON;
        INSERT INTO workspaces (id, status, created_at, updated_at)
        VALUES ('workspace', 'open', 1, 1);
        INSERT INTO workspace_refs (workspace_id, kind, owner_id, updated_at)
        VALUES ('workspace', 'page-content', 'present-owner', 1);
        INSERT INTO workspace_ref_sources (workspace_id, kind, owner_id, source_id, role)
        VALUES ('workspace', 'page-content', 'missing-owner', '\(sourceID.rawValue)', 'primary');
        """, at: url) == SQLITE_CONSTRAINT)
    }

    @Test func pageVersionCascadeWorks() throws {
        let (url, version, sourceID) = try preparedPageAndSource()
        try MetadataSQLiteFixtureSupport.execute("""
        PRAGMA foreign_keys = ON;
        INSERT INTO page_version_sources VALUES ('\(version.rawValue)', '\(sourceID.rawValue)', 'primary');
        DELETE FROM page_versions WHERE id = '\(version.rawValue)';
        """, at: url)
        #expect(try MetadataSQLiteFixtureSupport.scalar(
            "SELECT COUNT(*) FROM page_version_sources WHERE source_id = '\(sourceID.rawValue)'", at: url
        ) == "0")
    }

    @Test func deletingReferencedSourceIsRestricted() throws {
        let (url, version, sourceID) = try preparedPageAndSource()
        try MetadataSQLiteFixtureSupport.execute("""
        PRAGMA foreign_keys = ON;
        INSERT INTO page_version_sources VALUES ('\(version.rawValue)', '\(sourceID.rawValue)', 'primary');
        """, at: url)
        #expect(try MetadataSQLiteFixtureSupport.executeResult("""
        PRAGMA foreign_keys = ON;
        DELETE FROM sources WHERE id = '\(sourceID.rawValue)';
        """, at: url) == SQLITE_CONSTRAINT)
    }

    @Test func deletingWorkspaceRefCascadesStagedSources() throws {
        let (url, _, sourceID) = try preparedPageAndSource()
        try MetadataSQLiteFixtureSupport.execute("""
        PRAGMA foreign_keys = ON;
        INSERT INTO workspaces (id, status, created_at, updated_at)
        VALUES ('workspace', 'open', 1, 1);
        INSERT INTO workspace_refs (workspace_id, kind, owner_id, updated_at)
        VALUES ('workspace', 'page-content', 'owner', 1);
        INSERT INTO workspace_ref_sources (workspace_id, kind, owner_id, source_id, role)
        VALUES ('workspace', 'page-content', 'owner', '\(sourceID.rawValue)', 'supporting');
        DELETE FROM workspace_refs
        WHERE workspace_id = 'workspace' AND kind = 'page-content' AND owner_id = 'owner';
        """, at: url)
        #expect(try MetadataSQLiteFixtureSupport.scalar(
            "SELECT COUNT(*) FROM workspace_ref_sources WHERE source_id = '\(sourceID.rawValue)'", at: url
        ) == "0")
    }
}
