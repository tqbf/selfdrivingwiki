import Foundation
import Testing
@testable import WikiFSCore

/// Phase 6 — merge completeness tests.
///
/// After `workspaceMerge`, post-merge state is fully consistent:
/// - Re-embedding is triggered for each merged page (best-effort; the call
///   mirrors `PageUpsert`'s post-save path — in tests no embedder is available
///   so `EmbeddingService.chunkedEmbeddings` returns `[]` and the
///   `storePageChunks` call is skipped by the `!chunks.isEmpty` guard. We
///   verify the page-set return value instead, which is the input the
///   re-embedding loop consumes).
/// - An ingest-completion log entry is appended.
/// - Wiki-index line-set three-way merge (disjoint edits survive; same-line
///   edits park the workspace).
@MainActor
@Suite(.tags(.integration), .timeLimit(.minutes(5)))
struct WorkspaceMergeCompletenessTests {

    private func tempStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    // MARK: - Return value + log entry

    @Test func mergeReturnsMergedPageIDs_fastForward() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Test Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Test Page", body: "v1",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Test Page", body: "workspace body")

        let merged = try store.workspaceMerge(workspaceID: wsID)

        #expect(merged == [page.id.rawValue])
        #expect(try store.getPage(id: page.id).bodyMarkdown == "workspace body")
    }

    @Test func mergeReturnsMergedPageIDs_createdPage() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: nil, activityID: nil)

        // Stage a created page (no main page exists).
        let newPageID = PageID(rawValue: ULID.generate())
        let body = "This is a new page body"
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: newPageID, title: "Created Page", body: body)

        let merged = try store.workspaceMerge(workspaceID: wsID)

        #expect(merged == [newPageID.rawValue])
        let page = try store.getPage(id: newPageID)
        #expect(page.title == "Created Page")
        #expect(page.bodyMarkdown == body)
    }

    @Test func mergeAppendsIngestCompletionLogEntry() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Log Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Log Page", body: "v1",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Log Page", body: "v2")

        let merged = try store.workspaceMerge(workspaceID: wsID)
        #expect(!merged.isEmpty)

        // The merge should have appended a log entry with kind .ingest.
        let entries = try store.recentLogEntries(limit: 10)
        let ingestEntries = entries.filter { $0.kind == .ingest }
        #expect(!ingestEntries.isEmpty)
        let last = ingestEntries.last!
        #expect(last.title == "Workspace merge completed")
        #expect(last.note != nil)
        #expect(last.note!.contains("\(merged.count)"))
    }

    @Test func conflictParkReturnsEmptyAndNoLogEntry() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Conflict Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Page", body: "v1",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Conflict Page", body: "ws body")

        // Move main so the merge conflicts.
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Page", body: "main moved",
            expectedHeadVersionID: mainHead)

        let merged = try store.workspaceMerge(workspaceID: wsID)

        #expect(merged.isEmpty)
        // No ingest-completion log entry should be appended on conflict.
        let entries = try store.recentLogEntries(limit: 10)
        let mergeLogs = entries.filter {
            $0.kind == .ingest && $0.title == "Workspace merge completed"
        }
        #expect(mergeLogs.isEmpty)
    }

    // MARK: - Wiki-index line-set three-way merge

    @Test func wikiIndexDisjointEditsBothSurvive() throws {
        let store = try tempStore()

        // Start from a known multi-line base so edits land in clearly
        // separate regions (Diff3 needs non-overlapping changed regions).
        let baseText = """
        # Index

        Line One
        Line Two
        Line Three
        """
        try store.updateWikiIndex(body: baseText)

        // Workspace 1: change "Line Two" → "Line Two A".
        let wsID1 = try store.createWorkspace(name: nil, activityID: nil)
        let ws1Body = """
        # Index

        Line One
        Line Two A
        Line Three
        """
        try store.setWorkspaceIndexBody(
            workspaceID: wsID1, indexBody: ws1Body, indexBaseVersion: baseText)

        // Workspace 2: change "Line Three" → "Line Three B".
        let wsID2 = try store.createWorkspace(name: nil, activityID: nil)
        let ws2Body = """
        # Index

        Line One
        Line Two
        Line Three B
        """
        try store.setWorkspaceIndexBody(
            workspaceID: wsID2, indexBody: ws2Body, indexBaseVersion: baseText)

        _ = try store.workspaceMerge(workspaceID: wsID1)
        #expect(try store.getWikiIndex().body.contains("Line Two A"))

        _ = try store.workspaceMerge(workspaceID: wsID2)
        let final = try store.getWikiIndex()
        // Both disjoint edits survive the sequential merges.
        #expect(final.body.contains("Line Two A"))
        #expect(final.body.contains("Line Three B"))
    }

    @Test func wikiIndexSameLineConflictParks() throws {
        let store = try tempStore()

        let baseText = """
        # Index

        Line One
        Line Two
        Line Three
        """
        try store.updateWikiIndex(body: baseText)

        // Workspace 1: change "Line Two" → "Line Two A".
        let wsID1 = try store.createWorkspace(name: nil, activityID: nil)
        let ws1Body = """
        # Index

        Line One
        Line Two A
        Line Three
        """
        try store.setWorkspaceIndexBody(
            workspaceID: wsID1, indexBody: ws1Body, indexBaseVersion: baseText)
        _ = try store.workspaceMerge(workspaceID: wsID1)
        #expect(try store.getWikiIndex().body.contains("Line Two A"))

        // Workspace 2: change the same "Line Two" → "Line Two B".
        let wsID2 = try store.createWorkspace(name: nil, activityID: nil)
        let ws2Body = """
        # Index

        Line One
        Line Two B
        Line Three
        """
        try store.setWorkspaceIndexBody(
            workspaceID: wsID2, indexBody: ws2Body, indexBaseVersion: baseText)

        // Merge ws2 — should conflict on "Line Two" and park.
        _ = try store.workspaceMerge(workspaceID: wsID2)

        let summary = try store.workspaceSummary(id: wsID2)
        #expect(summary?.status == .conflicted)
    }
}
