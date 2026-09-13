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
        #expect(store.pragmaValue("user_version") == "54")
        // v54 (#1266): fresh `chat_transcript_items` carries the summary
        // trio; `chat_messages` is the compatibility projection without any
        // app-owned summary columns.
        let transcriptColumns = store.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chat_transcript_items') WHERE name IN ('summary', 'summary_kind', 'summary_at');")
        #expect(transcriptColumns == "3")
        let messageColumns = store.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chat_messages') WHERE name IN ('summary', 'summary_kind', 'summary_at');")
        #expect(messageColumns == "0")
    }

    @Test func v51MigratesWithoutBackfillOrDataLoss() throws {
        let fixture = try v51Fixture()
        let migrated = try GRDBWikiStore(databaseURL: fixture.url)
        #expect(migrated.pragmaValue("user_version") == "54")
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
        #expect(migrated.pragmaValue("user_version") == "54")
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chats') WHERE name IN ('summary', 'summary_at');") == "0")
        // The drop must not lose the rows the columns rode on (F12b).
        #expect(migrated.scalarText(
            "SELECT title FROM chats WHERE id = 'survivor';") == "Survivor")
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM chat_messages WHERE chat_id = 'survivor';") == "1")
    }

    @Test func v53DBMovesPerMessageSummaryAndRewritesTaintedRows() throws {
        // A v53 database stores the per-message summary on the compatibility
        // `chat_messages` projection, keyed by an unrelated PageID, and rows
        // written before 7937b383 / bb3e7884 can carry the skills-budget
        // warning in stored titles and summaries (issue #1266). Reopen: the
        // migration must add the summary trio to `chat_transcript_items`,
        // backfill through the seq↔cursor mapping, rewrite the tainted rows,
        // drop the `chat_messages` columns, and stamp 54.
        let warning = AgentPresentationPreamble.knownWarningSentence
        let pair = try TestStoreFactory.fileBacked(prefix: "schema-v54")
        pair.store.close()
        try MetadataSQLiteFixtureSupport.execute("""
        -- Reconstruct the real v53-era shapes: `chat_messages` carried the
        -- summary trio (v40–v53); `chat_transcript_items` did not have it.
        ALTER TABLE chat_messages ADD COLUMN summary TEXT;
        ALTER TABLE chat_messages ADD COLUMN summary_kind TEXT;
        ALTER TABLE chat_messages ADD COLUMN summary_at REAL;
        ALTER TABLE chat_transcript_items DROP COLUMN summary;
        ALTER TABLE chat_transcript_items DROP COLUMN summary_kind;
        ALTER TABLE chat_transcript_items DROP COLUMN summary_at;

        INSERT INTO chats (id, kind, title, created_at, updated_at) VALUES
            ('chat-a', 'edit', '\(warning)\n\nTidal pools form twice daily.', 1, 1),
            ('chat-b', 'edit', '\(warning)', 1, 1),
            ('chat-c', 'edit', 'Clean title', 1, 1),
            ('chat-d', 'edit', '\(warning)', 1, 1);

        INSERT INTO chat_transcript_items
            (chat_id, cursor, item_kind, item_json, projected_text, created_at) VALUES
            ('chat-a', 1, 'message', '{}', 'question', 1),
            ('chat-a', 2, 'message', '{}', 'assistant text', 1),
            ('chat-c', 1, 'message', '{}', 'question', 1),
            ('chat-c', 2, 'message', '{}', 'assistant text', 1),
            ('chat-b', 1, 'message', '{}', 'question', 1),
            ('chat-b', 2, 'message', '{}', 'assistant text', 1);

        INSERT INTO chat_messages
            (id, chat_id, seq, role, event_json, text, created_at,
             summary, summary_kind, summary_at) VALUES
            ('m-a0', 'chat-a', 0, 'user', '{}', 'How do tides work?', 1, NULL, NULL, NULL),
            ('m-a1', 'chat-a', 1, 'assistant', '{}', 'answer', 2,
             '\(warning)\n\nCached tidal summary.', 'model', 3),
            ('m-c1', 'chat-c', 1, 'assistant', '{}', 'answer', 2,
             'Clean cached summary.', 'default', 3),
            ('m-b0', 'chat-b', 0, 'user', '{}', 'Why do tides retreat?', 1, NULL, NULL, NULL),
            ('m-b1', 'chat-b', 1, 'assistant', '{}', 'answer', 2,
             '\(warning)', 'model', 3);

        -- The sidecar carries a title copy; it must be rewritten in step.
        INSERT INTO chat_search (chat_id, title, body) VALUES
            ('chat-a', 'stale sidecar title', 'body');

        PRAGMA user_version = 53;
        """, at: pair.url)

        let migrated = try GRDBWikiStore(databaseURL: pair.url)
        #expect(migrated.pragmaValue("user_version") == "54")

        // The `chat_messages` summary columns are gone; the transcript items
        // carry the trio.
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chat_messages') WHERE name IN ('summary', 'summary_kind', 'summary_at');") == "0")
        #expect(migrated.scalarText(
            "SELECT COUNT(*) FROM pragma_table_info('chat_transcript_items') WHERE name IN ('summary', 'summary_kind', 'summary_at');") == "3")

        // Backfill + sanitization: the tainted summary moved cleaned, the
        // clean summary moved verbatim, the warning-only summary NULLed back
        // to unsummarized (the summarizer recomputes it). The summary lives
        // on the assistant item at cursor 2 (the user item at cursor 1
        // carries none).
        #expect(migrated.scalarText(
            "SELECT summary FROM chat_transcript_items WHERE chat_id = 'chat-a' AND cursor = 2;") == "Cached tidal summary.")
        #expect(migrated.scalarText(
            "SELECT summary_kind FROM chat_transcript_items WHERE chat_id = 'chat-a' AND cursor = 2;") == "model")
        #expect(migrated.scalarText(
            "SELECT summary FROM chat_transcript_items WHERE chat_id = 'chat-c' AND cursor = 2;") == "Clean cached summary.")
        #expect(migrated.scalarText(
            "SELECT summary_kind FROM chat_transcript_items WHERE chat_id = 'chat-c' AND cursor = 2;") == "default")
        #expect(migrated.scalarText(
            "SELECT COALESCE(summary, 'nil') || '/' || COALESCE(summary_kind, 'nil') FROM chat_transcript_items WHERE chat_id = 'chat-b' AND cursor = 2;") == "nil/nil")

        // Titles: the content-bearing tainted title is stripped, the
        // warning-only titles are rewritten (provisional question title when
        // a question is recoverable, "New Chat" otherwise), and the clean
        // title is untouched.
        #expect(migrated.scalarText(
            "SELECT title FROM chats WHERE id = 'chat-a';") == "Tidal pools form twice daily.")
        #expect(migrated.scalarText(
            "SELECT title FROM chats WHERE id = 'chat-b';") == "Why do tides retreat?")
        #expect(migrated.scalarText(
            "SELECT title FROM chats WHERE id = 'chat-c';") == "Clean title")
        #expect(migrated.scalarText(
            "SELECT title FROM chats WHERE id = 'chat-d';") == "New Chat")

        // The sidecar title copy was rewritten in the same pass.
        #expect(migrated.scalarText(
            "SELECT title FROM chat_search WHERE chat_id = 'chat-a';") == "Tidal pools form twice daily.")
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
        #expect(reopened.pragmaValue("user_version") == "54")
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
