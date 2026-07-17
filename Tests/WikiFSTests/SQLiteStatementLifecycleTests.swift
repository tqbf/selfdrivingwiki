import Testing
import Foundation
import SQLite3
@testable import WikiFSCore

/// Statement-lifecycle regression tests for issue #332: cached SELECT
/// statements must never be left stepped-to-ROW (busy) when a method returns.
/// A busy statement pins the connection's WAL read snapshot, causing stale
/// reads and `BEGIN IMMEDIATE` failures after external writes.
///
/// **`noBusyStatementsAfterReads`** is the authoritative guard: deterministic
/// (`sqlite3_stmt_busy`), SQLite-version-independent, CI-fast. It exercises
/// every fixed statement site via public callers and asserts
/// `assertNoBusyStatements()` after each.
///
/// **`detectsBusyStatement`** verifies the guard itself throws when a
/// statement IS left busy (AC.2).
///
/// These tests use a single connection with deterministic checks — no
/// multi-connection WAL behavior, no slow working-set — so they are NOT
/// `.integration`-tagged and run in CI.
@Suite struct SQLiteStatementLifecycleTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stmt-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - AC.2: assertNoBusyStatements() throws when a statement is busy

    @Test func detectsBusyStatement() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())
        // Step without resetting — simulates the #332 bug.
        try store._testProbeBusyStatement("SELECT 1;")
        #expect(throws: WikiStoreError.self) {
            try store.assertNoBusyStatements()
        }
    }

    // MARK: - Test 1: no busy statements after any read or write-adjacent method

    @Test func noBusyStatementsAfterReads() throws {
        let store = try SQLiteWikiStore(databaseURL: tempDatabaseURL())

        // --- Setup: create data that exercises all fixed statement sites ---

        let page = try store.createPage(title: "Test Page")

        // addSource WITHOUT provenance → exercises legacyImportAgentID.
        let source = try store.addSource(
            filename: "doc.txt", data: Data("original content".utf8))

        // addSource WITH provenance → exercises ensureAgent.
        _ = try store.addSource(
            filename: "fetched.html", data: Data("<html>fetched</html>".utf8),
            provenance: SourceProvenance(
                agentName: "website", activityKind: "fetch",
                plan: "https://example.com", externalRef: "https://example.com/page",
                externalIdentity: "https://example.com/page"))

        // appendContentVersion → exercises refGeneration.
        let v2 = try store.appendContentVersion(
            sourceID: source.id, data: Data("version two".utf8))

        // Record two extractions → populates smv tables.
        let smv1 = try store.recordMarkdownExtraction(
            sourceID: source.id, content: "# Extracted",
            backend: .anthropic, modelVersion: "claude-test")
        let smv2 = try store.recordMarkdownExtraction(
            sourceID: source.id, content: "# Re-extracted",
            backend: .gemini)

        // Bookmark tree for delete + move tests.
        let folder = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .folder,
            label: "Folder", targetID: nil)
        let bookmark = try store.createBookmarkNode(
            parentID: nil, position: 1, kind: .pageRef,
            label: nil, targetID: page.id)

        // Chat for append/rename tests.
        let chat = try store.createChat(kind: .edit, title: "Test Chat")

        // --- Write-adjacent methods: call each, then assert no busy statements ---

        // setActiveMarkdown → check + upsertMarkdownDerivedRef → markdownDerivedGeneration.
        try store.setActiveMarkdown(sourceID: source.id, to: smv1.id)
        try store.assertNoBusyStatements()

        // revertProcessedMarkdown → upsertMarkdownDerivedRef → markdownDerivedGeneration.
        _ = try store.revertProcessedMarkdown(sourceID: source.id, to: smv2.id)
        try store.assertNoBusyStatements()

        // rollbackSourceContent → refGeneration + target + bs.
        try store.rollbackSourceContent(
            sourceID: source.id, to: PageID(rawValue: v2.id))
        try store.assertNoBusyStatements()

        // recordMarkdownExtraction (after ref is set) → markdownDerivedRef ROW path.
        _ = try store.recordMarkdownExtraction(
            sourceID: source.id, content: "# Third extraction",
            backend: .localPdf2md)
        try store.assertNoBusyStatements()

        // deleteBookmarkNode → info.
        try store.deleteBookmarkNode(id: bookmark.id)
        try store.assertNoBusyStatements()

        // moveBookmarkNode into a parent → info + ancestorStmt (root-hit path).
        let leaf = try store.createBookmarkNode(
            parentID: nil, position: 0, kind: .pageRef,
            label: nil, targetID: page.id)
        try store.moveBookmarkNode(id: leaf.id, toParentID: folder.id, position: 0)
        try store.assertNoBusyStatements()

        // appendChatMessages → exists + maxSeq.
        _ = try store.appendChatMessages(
            chatID: chat.id, events: [.userText("hello")])
        try store.assertNoBusyStatements()

        // renameChat → exists.
        try store.renameChat(id: chat.id, to: "Renamed Chat")
        try store.assertNoBusyStatements()

        // --- Read methods: call each, then assert no busy statements ---

        _ = try store.sourceContent(id: source.id)
        try store.assertNoBusyStatements()

        _ = try store.activeContentVersion(sourceID: source.id)
        try store.assertNoBusyStatements()

        _ = try store.sourceOrigin(sourceID: source.id)
        try store.assertNoBusyStatements()

        _ = try store.hasImageSiblings(sourceID: source.id)
        try store.assertNoBusyStatements()

        // canonicalLinkID(.chat) → exercise via replaceLinks with a chat link.
        try store.replaceLinks(from: page.id, parsedLinks: [
            ParsedLink(
                linkType: .chat, target: chat.id.rawValue,
                linkText: "Chat"),
        ])
        try store.assertNoBusyStatements()

        _ = try store.processedMarkdownHead(sourceID: source.id)
        try store.assertNoBusyStatements()

        _ = try store.processedMarkdownHeadID(sourceID: source.id)
        try store.assertNoBusyStatements()
    }
}

/// Multi-connection integration tests for issue #332: a leaked busy statement
/// on one connection should not block writes or serve stale reads after an
/// external commit advances the WAL.
///
/// These require real WAL cross-connection behavior and may be SQLite-version-
/// dependent. `noBusyStatementsAfterReads` (above) is the authoritative,
/// version-independent regression guard.
@Suite(.tags(.integration)) struct SQLiteStatementLifecycleIntegrationTests {

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stmt-lifecycle-int-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("WikiFS.sqlite")
    }

    // MARK: - Test 2: leaked statement does not block write after external commit

    @Test func leakedStatementDoesNotBlockWriteAfterExternalCommit() throws {
        let url = tempDatabaseURL()

        // Store A: add a source, then read its content (pre-fix: leaves blobStmt busy).
        let storeA = try SQLiteWikiStore(databaseURL: url)
        let source = try storeA.addSource(
            filename: "f.txt", data: Data("original".utf8))
        _ = try storeA.sourceContent(id: source.id)

        // Store B: a separate writer commits (advances the WAL).
        let storeB = try SQLiteWikiStore(databaseURL: url)
        _ = try storeB.addSource(
            filename: "g.txt", data: Data("other".utf8))

        // Store A: write through withTransaction → BEGIN IMMEDIATE.
        // Pre-fix: SQLITE_BUSY_SNAPSHOT. Post-fix: succeeds.
        try storeA.deleteSource(id: source.id)
    }

    // MARK: - Test 3: read-only store has no busy statements after sourceContent

    @Test func readOnlyStoreHasNoBusyStatementsAfterRead() throws {
        let url = tempDatabaseURL()

        let writer = try SQLiteWikiStore(databaseURL: url)
        let source = try writer.addSource(
            filename: "f.txt", data: Data("original".utf8))

        // Open a read-only store (simulates the File Provider / WikiReadPool path).
        let reader = try SQLiteWikiStore(readOnlyURL: url)
        _ = try reader.sourceContent(id: source.id)

        // The deterministic check: no statement should be left busy.
        // Pre-fix: blobStmt is busy → throws. Post-fix: passes.
        try reader.assertNoBusyStatements()
    }
}
