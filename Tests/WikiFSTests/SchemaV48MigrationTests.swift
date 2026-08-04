import Foundation
import Testing
#if canImport(CSQLite)
import CSQLite
#else
import SQLite3
#endif
@testable import WikiFSCore

struct SchemaV48MigrationTests {
    private final class HookRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []

        func append(_ event: String) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }
    }

    private struct Sentinel: Error {}

    private func v47URL(_ name: String = "schema-v48") throws -> URL {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: name)
        try MetadataSQLiteFixtureSupport.prepareV47(at: url)
        return url
    }

    private func migrationStore(
        at url: URL,
        hooks: SchemaV48MigrationHooks = .productionDefault,
        checker: SchemaForeignKeyChecker = .productionDefault(),
        foreignKeysEnabled: Bool = true
    ) throws -> GRDBWikiStore {
        try GRDBWikiStore(
            databaseURL: url,
            schemaV48MigrationHooks: hooks,
            schemaForeignKeyChecker: checker,
            foreignKeysEnabled: foreignKeysEnabled
        )
    }

    @Test func freshDatabaseHasCurrentSchema() throws {
        let store = try TestStoreFactory.inMemory()
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(store.scalarText("SELECT COUNT(*) FROM pragma_table_info('chat_turns') WHERE name = 'input_tokens'") == "1")
        #expect(store.scalarText("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'page_version_sources'") == "1")
    }

    @Test func upgradeV47PreservesRows() throws {
        let url = try v47URL()
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO chats (id, kind, title, created_at, updated_at) VALUES ('chat', 'edit', 'chat', 1, 1);
        INSERT INTO chat_turns (chat_id, turn_id, command_id, ordinal, state, user_text, context_refs_json, submitted_at)
        VALUES ('chat', 'turn', 'command', 0, 'queued', 'text', '[]', 1);
        """, at: url)
        let store = try migrationStore(at: url)
        #expect(try store.listPersistedChatTurns(chatID: ChatID(rawValue: "chat")).first?.submission.userText == "text")
        #expect(try store.chatTurnUsage(chatID: ChatID(rawValue: "chat"), turnID: ChatTurnID(rawValue: "turn"))?.inputTokens == nil)
    }

    @Test func upgradeStampsVersionAfterCommit() throws {
        let store = try migrationStore(at: v47URL())
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func reopenCurrentSchemaIsIdempotent() throws {
        let url = try v47URL()
        let first = try migrationStore(at: url)
        first.close()
        let reopened = try migrationStore(at: url)
        #expect(reopened.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func rewoundV48SchemaRepairsSafely() throws {
        let url = try v47URL()
        let first = try migrationStore(at: url)
        first.close()
        try MetadataSQLiteFixtureSupport.execute("PRAGMA user_version = 47", at: url)
        #expect(try migrationStore(at: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func freshAndUpgradeSchemasMatch() throws {
        let freshURL = try MetadataSQLiteFixtureSupport.fileURL(prefix: "fresh-v48")
        let fresh = try GRDBWikiStore(databaseURL: freshURL)
        fresh.close()
        let upgradedURL = try v47URL("upgrade-v48")
        let upgraded = try migrationStore(at: upgradedURL)
        upgraded.close()
        let names = "('chat_turns', 'page_version_sources', 'workspace_ref_sources', 'chat_turns_command_id', 'chat_turns_ordinal', 'chat_turns_claim_id', 'page_version_sources_source', 'workspace_ref_sources_source')"
        for type in ["table", "index"] {
            let freshSQL = try metadataSQL(type: type, names: names, at: freshURL)
            let upgradedSQL = try metadataSQL(type: type, names: names, at: upgradedURL)
            #expect(freshSQL == upgradedSQL)
        }
    }

    @Test func fixtureFactoryUsesProductionV47SchemaAndClassifier() throws {
        let url = try v47URL()
        #expect(try SchemaV48FixtureFactory.classification(at: url) == .v47)
    }

    @Test func classifierIdentifiesExactV47Shape() throws {
        let url = try v47URL()
        #expect(try SchemaV48FixtureFactory.classification(at: url) == .v47)
    }

    @Test func classifierIdentifiesExactV48Shape() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "fixture-v48")
        try MetadataSQLiteFixtureSupport.prepareV47(at: url, classificationFixture: .exactV48)
        #expect(try SchemaV48FixtureFactory.classification(at: url) == .v48)
    }

    @Test func staleShadowTableIsCleanedBeforeRebuild() throws {
        let url = try v47URL()
        try MetadataSQLiteFixtureSupport.execute("CREATE TABLE chat_turns_v48 (stale TEXT)", at: url)
        let store = try migrationStore(at: url)
        #expect(store.scalarText("SELECT COUNT(*) FROM sqlite_master WHERE name = 'chat_turns_v48'") == "0")
    }

    @Test func partialChatTurnsShapeIsRejected() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "partial-v48")
        try MetadataSQLiteFixtureSupport.prepareV47(at: url, classificationFixture: .partialChatTurnsShape)
        do {
            _ = try migrationStore(at: url)
            Issue.record("expected partial schema rejection")
        } catch let error as SchemaV48MigrationError {
            #expect(error.description.contains("partial"))
        }
    }

    @Test func unknownChatTurnsDefinitionIsRejected() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "unknown-v48")
        try MetadataSQLiteFixtureSupport.prepareV47(at: url, classificationFixture: .unknownChatTurnsDefinition)
        do {
            _ = try migrationStore(at: url)
            Issue.record("expected unknown schema rejection")
        } catch let error as SchemaV48MigrationError {
            #expect(error.description.contains("unknown"))
        }
    }

    @Test func migrationHooksRunExactlyOnceInDeclaredOrder() throws {
        let recorder = HookRecorder()
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: { recorder.append("cleanup") },
            afterChatCopy: { source, copied in
                recorder.append("copy:\(source):\(copied)")
                return copied
            }
        )
        _ = try migrationStore(at: v47URL(), hooks: hooks)
        #expect(recorder.events == ["cleanup", "copy:0:0"])
    }

    @Test func afterShadowCleanupCheckpointObservesCleanShadowAndUncreatedFinalTables() throws {
        let recorder = HookRecorder()
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: { recorder.append("cleanup") },
            afterChatCopy: { source, copied in
                recorder.append("copy")
                return copied
            }
        )
        let url = try v47URL()
        try MetadataSQLiteFixtureSupport.execute("CREATE TABLE chat_turns_v48 (stale TEXT)", at: url)
        _ = try migrationStore(at: url, hooks: hooks)
        #expect(recorder.events == ["cleanup", "copy"])
        #expect(try masterCount("chat_turns_v48", at: url) == 0)
        #expect(try masterCount("page_version_sources", at: url) == 1)
        #expect(try masterCount("workspace_ref_sources", at: url) == 1)
    }

    @Test func afterChatCopyCheckpointReceivesExactSourceAndCopiedCounts() throws {
        let url = try v47URL()
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO chats (id, kind, title, created_at, updated_at) VALUES ('chat', 'edit', 'Chat', 1, 1);
        INSERT INTO chat_turns (chat_id, turn_id, command_id, ordinal, state, user_text, context_refs_json, submitted_at)
        VALUES ('chat', 'one', 'command-one', 0, 'queued', 'one', '[]', 1),
               ('chat', 'two', 'command-two', 1, 'queued', 'two', '[]', 2);
        """, at: url)
        let recorder = HookRecorder()
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: { recorder.append("cleanup") },
            afterChatCopy: { source, copied in
                recorder.append("copy:\(source):\(copied)")
                return copied
            }
        )
        _ = try migrationStore(at: url, hooks: hooks)
        #expect(recorder.events == ["cleanup", "copy:2:2"])
    }

    @Test func afterShadowCleanupInjectedFailureRollsBackAndRetainsVersion47() throws {
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: { throw Sentinel() }, afterChatCopy: { _, copied in copied }
        )
        let url = try v47URL()
        do { _ = try migrationStore(at: url, hooks: hooks); Issue.record("expected hook failure") }
        catch let error as SchemaV48MigrationError { #expect(error.description.contains("migration failed")) }
        #expect(try userVersion(at: url) == 47)
        #expect(try masterCount("page_version_sources", at: url) == 0)
    }

    @Test func injectedCopyCountMismatchRollsBackMigration() throws {
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: {}, afterChatCopy: { source, _ in source + 1 }
        )
        let url = try v47URL()
        do { _ = try migrationStore(at: url, hooks: hooks); Issue.record("expected copy mismatch") }
        catch let error as SchemaV48MigrationError { #expect(error.description.contains("copy count mismatch")) }
        #expect(try userVersion(at: url) == 47)
    }

    @Test func constraintInvalidCopiedRowRollsBackMigrationAndRetainsVersion47() throws {
        let url = try v47URL()
        // This is a legacy-corruption fixture only. The upgraded connection has
        // enforcement enabled, so copying the invalid child into the v48 shadow
        // table fails inside the production immediate transaction.
        try MetadataSQLiteFixtureSupport.execute("""
        PRAGMA foreign_keys = OFF;
        INSERT INTO chat_turns (chat_id, turn_id, command_id, ordinal, state, user_text, context_refs_json, submitted_at)
        VALUES ('missing-chat', 'turn', 'command', 0, 'queued', 'text', '[]', 1);
        """, at: url)
        do {
            _ = try migrationStore(at: url)
            Issue.record("expected invalid copied child to fail")
        } catch let error as SchemaV48MigrationError {
            #expect(error.description.contains("constraint"))
        }
        try assertV48ObjectsAbsent(at: url)
    }

    @Test func orphanedCascadeChildrenAreRepairedAndMigrationSucceeds() throws {
        let url = try v47URL()
        // Mirror the real-world corruption: a `sources` row was deleted while
        // foreign-key enforcement was off, leaving its ON DELETE CASCADE
        // children behind. source_chunks is WITHOUT ROWID (exercises the
        // NULL-rowid reporting path); source_search is a rowid table.
        try MetadataSQLiteFixtureSupport.execute("""
        PRAGMA foreign_keys = OFF;
        INSERT INTO source_chunks (source_id, chunk_idx, embedding) VALUES
            ('ghost-source', 0, x'00'),
            ('ghost-source', 1, x'00');
        INSERT INTO source_search (source_id, title, body) VALUES
            ('ghost-source', 'ghost', 'body');
        PRAGMA foreign_keys = ON;
        """, at: url)
        #expect(try scalar("SELECT COUNT(*) FROM pragma_foreign_key_check", at: url) == "3")

        // The store must open despite the orphans: the gate repairs the
        // cascade children, then re-checks clean.
        let store = try migrationStore(at: url)
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
        #expect(try scalar("SELECT COUNT(*) FROM source_chunks WHERE source_id = 'ghost-source'", at: url) == "0")
        #expect(try scalar("SELECT COUNT(*) FROM source_search WHERE source_id = 'ghost-source'", at: url) == "0")
        #expect(try scalar("SELECT COUNT(*) FROM pragma_foreign_key_check", at: url) == "0")
    }

    @Test func nonCascadeOrphanStillAbortsMigration() throws {
        let url = try v47URL()
        // page_links references pages with the default NO ACTION — an orphan
        // there is not something a cascade-cleanup can repair, so the
        // migration must still abort rather than mask the damage.
        try MetadataSQLiteFixtureSupport.execute("""
        PRAGMA foreign_keys = OFF;
        INSERT INTO page_links (from_page_id, to_page_id, link_text)
        VALUES ('missing-page', 'missing-page', 'link');
        PRAGMA foreign_keys = ON;
        """, at: url)
        #expect(try scalar("SELECT COUNT(*) FROM pragma_foreign_key_check", at: url) == "2")

        do {
            _ = try migrationStore(at: url)
            Issue.record("expected non-cascade orphan to abort")
        } catch let error as SchemaV48MigrationError {
            #expect(error.description.contains("foreign-key check returned"))
        }
        try assertV48ObjectsAbsent(at: url)
    }

    @Test func productionForeignKeyCheckerRunsRealCleanPragmaWithEnforcementEnabled() throws {
        let store = try migrationStore(at: v47URL())
        #expect(store.pragmaValue("foreign_keys") == "1")
    }

    @Test func productionForeignKeyCheckerRejectsDisabledEnforcementAndRollsBackToV47() throws {
        let url = try v47URL()
        do {
            _ = try migrationStore(at: url, foreignKeysEnabled: false)
            Issue.record("expected disabled foreign-key enforcement")
        } catch let error as SchemaV48MigrationError {
            #expect(error.description.contains("disabled"))
        }
        #expect(try userVersion(at: url) == 47)
        #expect(try masterCount("page_version_sources", at: url) == 0)
    }

    @Test func retryAfterEnablingForeignKeyEnforcementSucceeds() throws {
        let url = try v47URL()
        do { _ = try migrationStore(at: url, foreignKeysEnabled: false) } catch { }
        #expect(try migrationStore(at: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func injectedForeignKeyResultMapsToTypedViolation() throws {
        let checker = SchemaForeignKeyChecker(
            verifyEnforcement: { _ in },
            check: { _ in [.init(table: "child", rowID: 1, parentTable: "parent", foreignKeyIndex: 0)] }
        )
        let url = try v47URL()
        do { _ = try migrationStore(at: url, checker: checker); Issue.record("expected FK result") }
        catch let error as SchemaV48MigrationError { #expect(error.description.contains("foreign-key check returned 1")) }
        try assertV48ObjectsAbsent(at: url)
    }

    @Test func injectedForeignKeyViolationRollbackRemovesAllV48ObjectsAndRetainsVersion47() throws {
        let checker = SchemaForeignKeyChecker(
            verifyEnforcement: { _ in },
            check: { _ in [.init(table: "child", rowID: 1, parentTable: "parent", foreignKeyIndex: 0)] }
        )
        let url = try v47URL()
        do {
            _ = try migrationStore(at: url, checker: checker)
            Issue.record("expected injected foreign-key violation")
        } catch let error as SchemaV48MigrationError {
            #expect(error.description.contains("foreign-key check returned 1"))
        }
        try assertV48ObjectsAbsent(at: url)
    }

    @Test func injectedForeignKeyCheckerThrowRollsBackAllV48ObjectsAndRetainsVersion47() throws {
        let checker = SchemaForeignKeyChecker(verifyEnforcement: { _ in }, check: { _ in throw Sentinel() })
        let url = try v47URL()
        do { _ = try migrationStore(at: url, checker: checker); Issue.record("expected checker failure") }
        catch let error as SchemaV48MigrationError { #expect(error.description.contains("checker failed")) }
        try assertV48ObjectsAbsent(at: url)
    }

    @Test func afterChatCopyInjectedFailureRollsBackAndRetainsVersion47() throws {
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: {}, afterChatCopy: { _, _ in throw Sentinel() }
        )
        let url = try v47URL()
        do {
            _ = try migrationStore(at: url, hooks: hooks)
            Issue.record("expected after-copy hook failure")
        } catch let error as SchemaV48MigrationError {
            #expect(error.description.contains("migration failed"))
        }
        try assertV48ObjectsAbsent(at: url)
    }

    @Test func retryAfterInjectedForeignKeyViolationSucceeds() throws {
        let checker = SchemaForeignKeyChecker(
            verifyEnforcement: { _ in },
            check: { _ in [.init(table: "child", rowID: 1, parentTable: "parent", foreignKeyIndex: 0)] }
        )
        let url = try v47URL()
        do { _ = try migrationStore(at: url, checker: checker) } catch { }
        #expect(try migrationStore(at: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func retryAfterReplacingThrowingCheckerWithProductionCheckerSucceeds() throws {
        let throwing = SchemaForeignKeyChecker(verifyEnforcement: { _ in }, check: { _ in throw Sentinel() })
        let url = try v47URL()
        do { _ = try migrationStore(at: url, checker: throwing) } catch { }
        #expect(try migrationStore(at: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func failedUpgradeRollsBackAndRetries() throws {
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: { throw Sentinel() }, afterChatCopy: { _, copied in copied }
        )
        let url = try v47URL()
        do { _ = try migrationStore(at: url, hooks: hooks) } catch { }
        try assertV48ObjectsAbsent(at: url)
        #expect(try migrationStore(at: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func injectedForeignKeyCheckerRunsAtExactFinalSchemaCheckpoint() throws {
        let recorder = HookRecorder()
        let checker = SchemaForeignKeyChecker(
            verifyEnforcement: { _ in recorder.append("verify") },
            check: { db in
                // These reads run through the very connection and immediate
                // transaction that owns the upgrade. They prove the checker is
                // after final chat and provenance objects exist, before the
                // outer migration stamps user_version.
                try db.execute(sql: "SELECT input_tokens, finished_at FROM chat_turns LIMIT 0;")
                try db.execute(sql: "SELECT role FROM page_version_sources LIMIT 0;")
                try db.execute(sql: "SELECT role FROM workspace_ref_sources LIMIT 0;")
                recorder.append("check")
                return []
            }
        )
        let hooks = SchemaV48MigrationHooks(
            afterShadowCleanup: { recorder.append("cleanup") },
            afterChatCopy: { source, copied in recorder.append("copy"); return copied }
        )
        let store = try migrationStore(at: v47URL(), hooks: hooks, checker: checker)
        #expect(recorder.events == ["verify", "cleanup", "copy", "check"])
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func readOnlyV47ReturnsCompatibilityEmptyValues() throws {
        let url = try v47URL()
        let store = try GRDBWikiStore(readOnlyURL: url)
        #expect(try store.chatTurnUsage(chatID: ChatID(rawValue: "missing"), turnID: ChatTurnID(rawValue: "missing")) == nil)
        #expect(try store.chatUsageSummary(chatID: ChatID(rawValue: "missing")) == .empty)
        #expect(try store.pageVersionSources(versionID: PageVersionID(rawValue: "missing")).isEmpty)
        #expect(try userVersion(at: url) == 47)
    }

    @Test func readOnlyOpenNeverMigrates() throws {
        let url = try v47URL()
        let store = try GRDBWikiStore(readOnlyURL: url)
        #expect(store.pragmaValue("user_version") == "47")
        store.close()
        #expect(try userVersion(at: url) == 47)
        #expect(try masterCount("page_version_sources", at: url) == 0)
    }

    @Test func readOnlyV48ReadsMetadata() throws {
        let url = try MetadataSQLiteFixtureSupport.fileURL(prefix: "readonly-v48")
        let writable = try GRDBWikiStore(databaseURL: url)
        let chat = try writable.createChat(kind: .edit, title: "Read-only")
        let source = try writable.addSource(filename: "source.txt", data: Data("source".utf8))
        let page = try writable.createPage(title: "Page")
        let version = try #require(try writable.pageHeadVersionID(pageID: page.id))
        writable.close()
        try MetadataSQLiteFixtureSupport.execute("""
        INSERT INTO chat_turns
          (chat_id, turn_id, command_id, ordinal, state, user_text, context_refs_json, submitted_at,
           claimed_at, provider_id, model_id, input_tokens)
        VALUES ('\(chat.id.rawValue)', 'turn', 'command', 0, 'claimed', 'text', '[]', 1,
                2, 'provider', 'model', 3);
        INSERT INTO page_version_sources VALUES ('\(version.rawValue)', '\(source.id.rawValue)', 'primary');
        """, at: url)
        let readOnly = try GRDBWikiStore(readOnlyURL: url)
        #expect(try readOnly.chatTurnUsage(chatID: chat.id, turnID: ChatTurnID(rawValue: "turn"))?.inputTokens == 3)
        #expect(try readOnly.pageVersionSources(versionID: version) == [
            .init(pageVersionID: version, sourceID: source.id, role: .primary),
        ])
    }

    @Test func migrationHooksAreInternalAndProductionDefaultsAreNoOp() throws {
        let store = try migrationStore(at: v47URL(), hooks: .productionDefault, checker: .productionDefault())
        #expect(store.pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func productionForeignKeyCheckerIsRestoredPerStoreInstance() throws {
        let url = try v47URL()
        let rejecting = SchemaForeignKeyChecker(verifyEnforcement: { _ in throw Sentinel() }, check: { _ in [] })
        do { _ = try migrationStore(at: url, checker: rejecting) } catch { }
        #expect(try migrationStore(at: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func injectedForeignKeyCheckerStateDoesNotLeakAfterRollbackAndReopen() throws {
        let url = try v47URL()
        let rejecting = SchemaForeignKeyChecker(
            verifyEnforcement: { _ in },
            check: { _ in [.init(table: "child", rowID: 1, parentTable: "parent", foreignKeyIndex: 0)] }
        )
        do { _ = try migrationStore(at: url, checker: rejecting) } catch { }
        #expect(try migrationStore(at: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func fixtureFactoryUsesFreshProductionCheckerByDefault() throws {
        let url = try v47URL()
        #expect(try GRDBWikiStore(databaseURL: url).pragmaValue("user_version") == "\(GRDBWikiStore.schemaVersion)")
    }

    @Test func foreignKeysAreEnabled() throws {
        #expect(try TestStoreFactory.inMemory().pragmaValue("foreign_keys") == "1")
    }

    private func metadataSQL(type: String, names: String, at url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw WikiStoreError.open("fixture open") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT group_concat(replace(replace(lower(sql), char(10), ' '), '  ', ' '), '|') FROM sqlite_master WHERE type = '\(type)' AND name IN \(names) ORDER BY name"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw WikiStoreError.sqlite(code: -1, message: "schema query") }
        defer { sqlite3_reset(statement); sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: text)
    }

    private func userVersion(at url: URL) throws -> Int { Int(try scalar("PRAGMA user_version", at: url)) ?? -1 }
    private func masterCount(_ name: String, at url: URL) throws -> Int { Int(try scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = '\(name)'", at: url)) ?? -1 }
    private func assertV48ObjectsAbsent(at url: URL) throws {
        #expect(try userVersion(at: url) == 47)
        for name in ["chat_turns_v48", "page_version_sources", "workspace_ref_sources", "page_version_sources_source", "workspace_ref_sources_source"] {
            #expect(try masterCount(name, at: url) == 0)
        }
    }
    private func scalar(_ query: String, at url: URL) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw WikiStoreError.open("fixture open") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw WikiStoreError.sqlite(code: -1, message: "scalar query") }
        defer { sqlite3_reset(statement); sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return "" }
        return String(cString: value)
    }
}
