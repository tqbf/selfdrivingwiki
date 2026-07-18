import Foundation
import Testing
@testable import WikiFSCore

/// Tests for W1 — workspaces, overlay, fast-forward merge (PR #312).
///
/// Covers: workspace creation, workspace writes (don't touch main), overlay
/// reads, fast-forward merge (base == main head), conflict park (main moved),
/// abandon, and page-created-in-workspace merge.
@MainActor
struct WorkspaceTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - Workspace CRUD

    @Test func createWorkspaceReturnsID() throws {
        let store = try tempStore()
        let id = try store.createWorkspace(name: "test", activityID: nil)
        #expect(!id.isEmpty)
        let summary = try store.workspaceSummary(id: id)
        #expect(summary != nil)
        #expect(summary?.status == .open)
        #expect(summary?.name == "test")
    }

    @Test func workspaceSummaryReturnsNilForMissing() throws {
        let store = try tempStore()
        let summary = try store.workspaceSummary(id: "nonexistent")
        #expect(summary == nil)
    }

    // MARK: - Workspace writes don't touch main

    @Test func workspaceWriteDoesNotTouchMain() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Main Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Main Page", body: "main body",
            expectedHeadVersionID: nil)

        // Write into a workspace.
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Main Page", body: "workspace body")

        // Main's body should be unchanged.
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown == "main body")

        // The workspace's version should be different from main's head.
        let wsVersion = try store.workspacePageVersion(workspaceID: wsID, pageID: page.id)
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        #expect(wsVersion != nil)
        #expect(wsVersion != mainHead)
    }

    // MARK: - Overlay reads

    @Test func overlayReadReturnsWorkspaceVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Overlay Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Overlay Page", body: "v1",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Overlay Page", body: "workspace version")

        // The workspace sees its own version.
        let wsVersion = try store.workspacePageVersion(workspaceID: wsID, pageID: page.id)
        #expect(wsVersion != nil)

        // Main is untouched.
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown == "v1")
    }

    // MARK: - Fast-forward merge

    @Test func fastForwardMergeSucceedsWhenMainUnchanged() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "FF Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "FF Page", body: "v1",
            expectedHeadVersionID: nil)

        // Write into workspace.
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "FF Page", body: "workspace v2")

        // Merge (main hasn't moved → fast-forward).
        try store.workspaceMerge(workspaceID: wsID)

        // Main now has the workspace's body.
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown == "workspace v2")

        // Workspace is merged.
        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .merged)
    }

    // MARK: - Conflict park

    @Test func conflictParksWhenMainMoved() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Conflict Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Page", body: "v1",
            expectedHeadVersionID: nil)

        // Write into workspace (captures base = main head at this point).
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Conflict Page", body: "workspace body")

        // Main moves (another writer commits).
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Page", body: "main moved",
            expectedHeadVersionID: mainHead)

        // Merge should park as conflicted (no throw — parks and returns).
        try store.workspaceMerge(workspaceID: wsID)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .conflicted)

        // Main is NOT corrupted — still has the concurrent writer's body.
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown == "main moved")
    }

    // MARK: - Abandon

    @Test func abandonClearsRefsAndSetsStatus() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Abandon Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Abandon Page", body: "v1",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Abandon Page", body: "ws body")

        // Abandon.
        try store.abandonWorkspace(id: wsID)

        // Status is abandoned.
        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .abandoned)

        // Workspace refs are deleted.
        let refs = try store.workspaceRefs(workspaceID: wsID)
        #expect(refs.isEmpty)
    }

    // MARK: - Page created in workspace

    @Test func pageCreatedInWorkspaceMergesByCreating() throws {
        let store = try tempStore()

        // Create a workspace and write a page that doesn't exist on main.
        // v35 staging: the page is staged as blob_hash + title in
        // workspace_refs — no pages row on main until merge.
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        let newPageID = PageID(rawValue: ULID.generate())
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: newPageID, title: "Brand New Page", body: "new content")

        // The page does NOT exist on main yet (v35 staging — no placeholder).
        #expect(throws: WikiStoreError.self) {
            _ = try store.getPage(id: newPageID)
        }

        // Merge — should mint the pages row + root version from the staged blob.
        try store.workspaceMerge(workspaceID: wsID)

        // Now the page exists on main with the staged body.
        let pageAfter = try store.getPage(id: newPageID)
        #expect(pageAfter.title == "Brand New Page")
        #expect(pageAfter.bodyMarkdown == "new content")

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .merged)
    }

    // MARK: - Multiple pages in one workspace

    @Test func mergeFastForwardsMultiplePages() throws {
        let store = try tempStore()
        let page1 = try store.createPage(title: "Page One")
        let page2 = try store.createPage(title: "Page Two")
        _ = try store.appendPageVersion(
            pageID: page1.id, title: "Page One", body: "v1",
            expectedHeadVersionID: nil)
        _ = try store.appendPageVersion(
            pageID: page2.id, title: "Page Two", body: "v1",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page1.id, title: "Page One", body: "ws v2")
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page2.id, title: "Page Two", body: "ws v2")

        // Merge — both should fast-forward.
        try store.workspaceMerge(workspaceID: wsID)

        let p1 = try store.getPage(id: page1.id)
        let p2 = try store.getPage(id: page2.id)
        #expect(p1.bodyMarkdown == "ws v2")
        #expect(p2.bodyMarkdown == "ws v2")

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .merged)
    }

    // MARK: - diff3 merge (W2)

    @Test func diff3MergeCleansWhenChangesAreInDifferentRegions() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Diff3 Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Diff3 Page", body: "line1\nline2\nline3",
            expectedHeadVersionID: nil)

        // Workspace writes: change line1 → ws-line1.
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Diff3 Page",
            body: "ws-line1\nline2\nline3")

        // Main moves: change line3 → main-line3.
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Diff3 Page",
            body: "line1\nline2\nmain-line3",
            expectedHeadVersionID: mainHead)

        // Merge — should diff3 cleanly (different regions).
        try store.workspaceMerge(workspaceID: wsID)

        let merged = try store.getPage(id: page.id)
        #expect(merged.bodyMarkdown.contains("ws-line1"))
        #expect(merged.bodyMarkdown.contains("main-line3"))
        #expect(merged.bodyMarkdown.contains("line2"))

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .merged)
    }

    @Test func diff3MergeParksWhenSameLineChangedDifferently() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Conflict Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Page", body: "line1\nline2\nline3",
            expectedHeadVersionID: nil)

        // Workspace writes: line2 → ws-line2.
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Conflict Page",
            body: "line1\nws-line2\nline3")

        // Main moves: line2 → main-line2.
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Page",
            body: "line1\nmain-line2\nline3",
            expectedHeadVersionID: mainHead)

        // Merge — should conflict (same line, different change).
        try store.workspaceMerge(workspaceID: wsID)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .conflicted)

        // Main body unchanged (not corrupted).
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown.contains("main-line2"))
    }

    @Test func diff3MergeCreatesTwoParentVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Lineage Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Lineage Page", body: "line1\nline2",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Lineage Page",
            body: "line1\nline2\nws-added")

        // Main moves (different region).
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Lineage Page",
            body: "main-added\nline1\nline2",
            expectedHeadVersionID: mainHead)

        try store.workspaceMerge(workspaceID: wsID)

        // The merge version should have two parents.
        let history = try store.pageVersionHistory(pageID: page.id)
        let mergeVersion = history.last!
        #expect(mergeVersion.parentID != nil)
        #expect(mergeVersion.mergeParentID != nil)
        #expect(mergeVersion.mergeParentID != mergeVersion.parentID)
    }

    @Test func twoOverlappingIngestionsBothMerge() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Shared Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Shared Page", body: "line1\nline2\nline3",
            expectedHeadVersionID: nil)

        // Ingestion 1: touches line1.
        let ws1 = try store.createWorkspace(name: "ingest1", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: ws1, pageID: page.id, title: "Shared Page",
            body: "ingest1-line1\nline2\nline3")

        // Merge ingestion 1 (fast-forward — main hasn't moved).
        try store.workspaceMerge(workspaceID: ws1)

        // Ingestion 2: touches line3 (different region from ingest1).
        let ws2 = try store.createWorkspace(name: "ingest2", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: ws2, pageID: page.id, title: "Shared Page",
            body: "ingest1-line1\nline2\ningest2-line3")

        // Merge ingestion 2 (main moved since base → diff3).
        try store.workspaceMerge(workspaceID: ws2)

        let merged = try store.getPage(id: page.id)
        #expect(merged.bodyMarkdown.contains("ingest1-line1"))
        #expect(merged.bodyMarkdown.contains("ingest2-line3"))
        #expect(merged.bodyMarkdown.contains("line2"))

        let summary2 = try store.workspaceSummary(id: ws2)
        #expect(summary2?.status == .merged)
    }

    // MARK: - refresh (W2)

    @Test func refreshReBasesWorkspaceAgainstMain() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Refresh Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Refresh Page", body: "line1\nline2\nline3",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Refresh Page",
            body: "line1\nws-line2\nline3")

        // Main moves in a different region (line1 → main-line1).
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Refresh Page",
            body: "main-line1\nline2\nline3",
            expectedHeadVersionID: mainHead)

        // Refresh — should diff3 merge, update base to new main head.
        try store.workspaceRefresh(workspaceID: wsID)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .open)  // still open after refresh

        // The workspace_ref's base should now be the new main head.
        let refs = try store.workspaceRefs(workspaceID: wsID)
        let newMainHead = try store.pageHeadVersionID(pageID: page.id)
        #expect(refs.first?.baseVersionID == newMainHead)
    }

    // MARK: - Conflict resolution (W3)

    @Test func conflictsArePersistedAndQueryable() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Conflict Persist Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Persist Page", body: "line1\nline2",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Conflict Persist Page",
            body: "line1\nws-line2")

        // Main moves (same line, different change).
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Conflict Persist Page",
            body: "line1\nmain-line2",
            expectedHeadVersionID: mainHead)

        // Merge → parks as conflicted.
        try store.workspaceMerge(workspaceID: wsID)

        // Conflicts should be persisted and queryable.
        let conflicts = try store.workspaceConflicts(workspaceID: wsID)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.pageID == page.id)
        #expect(conflicts.first?.baseVersionID != nil)
        #expect(conflicts.first?.mainVersionID != nil)
        #expect(conflicts.first?.wsVersionID != nil)
    }

    @Test func resolveConflictThenRetryMergeSucceeds() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Resolve Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Resolve Page", body: "line1\nline2",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Resolve Page",
            body: "line1\nws-line2")

        // Main moves (same line, different change → conflict).
        let mainHead = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Resolve Page",
            body: "line1\nmain-line2",
            expectedHeadVersionID: mainHead)

        // Merge → parks.
        try store.workspaceMerge(workspaceID: wsID)
        #expect(try store.workspaceSummary(id: wsID)?.status == .conflicted)

        // Resolve the conflict with a hand-merged body.
        try store.workspaceResolveConflict(
            workspaceID: wsID, pageID: page.id,
            body: "line1\nmain-line2\nws-line2")

        // Conflict row should be deleted.
        let conflicts = try store.workspaceConflicts(workspaceID: wsID)
        #expect(conflicts.isEmpty)

        // Retry merge → should succeed (base == main head now).
        try store.workspaceRetryMerge(workspaceID: wsID)
        #expect(try store.workspaceSummary(id: wsID)?.status == .merged)

        // Main has the resolved body.
        let merged = try store.getPage(id: page.id)
        #expect(merged.bodyMarkdown.contains("main-line2"))
        #expect(merged.bodyMarkdown.contains("ws-line2"))
    }

    @Test func secondWorkspaceMergesWhileFirstIsParked() throws {
        let store = try tempStore()
        let page1 = try store.createPage(title: "Page One")
        let page2 = try store.createPage(title: "Page Two")
        _ = try store.appendPageVersion(
            pageID: page1.id, title: "Page One", body: "line1\nline2",
            expectedHeadVersionID: nil)
        _ = try store.appendPageVersion(
            pageID: page2.id, title: "Page Two", body: "lineA\nlineB",
            expectedHeadVersionID: nil)

        // Workspace 1: conflicts on page1.
        let ws1 = try store.createWorkspace(name: "conflicting", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: ws1, pageID: page1.id, title: "Page One", body: "line1\nws1-line2")

        let mainHead1 = try store.pageHeadVersionID(pageID: page1.id)
        _ = try store.appendPageVersion(
            pageID: page1.id, title: "Page One", body: "line1\nmain-line2",
            expectedHeadVersionID: mainHead1)

        try store.workspaceMerge(workspaceID: ws1)
        #expect(try store.workspaceSummary(id: ws1)?.status == .conflicted)

        // Workspace 2: touches a DIFFERENT page (page2, no conflict).
        let ws2 = try store.createWorkspace(name: "clean", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: ws2, pageID: page2.id, title: "Page Two", body: "lineA\nws2-lineB")

        // Merge ws2 — should succeed even though ws1 is parked.
        try store.workspaceMerge(workspaceID: ws2)
        #expect(try store.workspaceSummary(id: ws2)?.status == .merged)

        let merged = try store.getPage(id: page2.id)
        #expect(merged.bodyMarkdown.contains("ws2-lineB"))
    }

    // MARK: - Reaper (W4)

    @Test func reapAbandonsStaleOpenWorkspaces() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Reap Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Reap Page", body: "v1",
            expectedHeadVersionID: nil)

        // Create a workspace (it's 'open').
        let wsID = try store.createWorkspace(name: "stale", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Reap Page", body: "ws")

        // Reap with a TTL that covers it (it was just created, so 0 TTL reaps it).
        let reaped = try store.reapStaleWorkspaces(ttl: 0)
        #expect(reaped == 1)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .abandoned)

        // Workspace refs should be deleted.
        let refs = try store.workspaceRefs(workspaceID: wsID)
        #expect(refs.isEmpty)
    }

    @Test func reapDoesNotTouchActiveWorkspaces() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: "active", activityID: nil)

        // Reap with a 1-hour TTL — the workspace was just created, should survive.
        let reaped = try store.reapStaleWorkspaces(ttl: 3600)
        #expect(reaped == 0)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .open)
    }
}
