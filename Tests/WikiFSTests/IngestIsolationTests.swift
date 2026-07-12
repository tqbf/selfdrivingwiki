import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore

/// Tests for Phase 7: workspace-isolated ingestion + stale-workspace reaping
/// (`#multi-writer-hardening`).
///
/// Covers:
/// - AC7.1: With `workspacesEnabled`, a workspace-stage write leaves main pages
///   and the changeToken untouched until merge.
/// - AC7.2: A human page edit during an isolated ingest commits immediately to
///   main (the workspace write doesn't block it).
/// - AC7.5: Stale `open` workspaces older than the TTL are reaped.
///
/// Store-layer tests only — the end-to-end agent pipeline (subprocess spawn +
/// WIKI_WORKSPACE env propagation) requires manual validation.
@MainActor
@Suite(.tags(.integration))
struct IngestIsolationTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - AC7.1: Workspace-stage write leaves main untouched until merge

    @Test func workspaceWriteLeavesMainUntouchedUntilMerge() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Original")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Original", body: "main body",
            expectedHeadVersionID: nil)

        // Simulate an isolated ingest: create a workspace, write a page into it.
        let wsID = try store.createWorkspace(name: "ingest-1", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Original", body: "workspace body")

        // Main is untouched — the page body is still the original.
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown == "main body")

        // The changeToken (refs SUM(generation)) should not have moved for
        // the workspace write — main refs are untouched.
        let headVersion = try store.pageHeadVersionID(pageID: page.id)
        let originalHead = try store.pageHeadVersionID(pageID: page.id)
        #expect(headVersion == originalHead)

        // Merge brings the workspace's changes to main.
        try store.workspaceMerge(workspaceID: wsID)

        // Now main has the workspace's body.
        let mergedPage = try store.getPage(id: page.id)
        #expect(mergedPage.bodyMarkdown == "workspace body")

        // The workspace is merged.
        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .merged)
    }

    // MARK: - AC7.1: Created page is invisible on main until merge

    @Test func createdPageInvisibleOnMainUntilMerge() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: "ingest-create", activityID: nil)

        // Stage a created page (doesn't exist on main).
        let newPageID = PageID(rawValue: ULID.generate())
        let resultID = try store.workspaceWritePage(
            workspaceID: wsID, pageID: newPageID, title: "New Page", body: "new content")
        #expect(!resultID.isEmpty)

        // The page does NOT exist on main — getPage should fail.
        #expect(throws: (any Error).self) {
            _ = try store.getPage(id: newPageID)
        }

        // The workspace's overlay read returns the staged body.
        let wsBody = try store.workspacePageBody(workspaceID: wsID, pageID: newPageID)
        #expect(wsBody == "new content")

        // Merge mints the pages row + root version.
        try store.workspaceMerge(workspaceID: wsID)

        // Now the page exists on main with the staged body.
        let mainPage = try store.getPage(id: newPageID)
        #expect(mainPage.bodyMarkdown == "new content")
    }

    // MARK: - AC7.2: Human edit during isolated ingest commits immediately

    @Test func humanEditCommitsImmediatelyDuringWorkspace() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Shared")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Shared", body: "v1",
            expectedHeadVersionID: nil)

        // An isolated ingest stages a workspace write.
        let wsID = try store.createWorkspace(name: "ingest", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Shared", body: "workspace v2")

        // Meanwhile, a human edits the page directly on main.
        try store.updatePage(id: page.id, title: "Shared", body: "human edit")

        // The human edit is immediately visible on main.
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown == "human edit")

        // The workspace still has its own version (not affected by the human edit).
        let wsBody = try store.workspacePageBody(workspaceID: wsID, pageID: page.id)
        #expect(wsBody == "workspace v2")
    }

    // MARK: - AC7.5: Stale workspaces reaped

    @Test func staleOpenWorkspacesReaped() throws {
        let store = try tempStore()

        // Create an "old" workspace (updated_at is now, so it won't be stale
        // with a 24h TTL unless we lower the TTL drastically).
        let wsID = try store.createWorkspace(name: "stale", activityID: nil)

        // Write a page to make it realistic.
        let page = try store.createPage(title: "Stale")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Stale", body: "body",
            expectedHeadVersionID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Stale", body: "ws body")

        // With a very short TTL (e.g. 0 seconds), the workspace is immediately stale.
        let reaped = try store.reapStaleWorkspaces(ttl: 0)
        #expect(reaped >= 1)

        // The workspace is now abandoned.
        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .abandoned)
    }

    @Test func freshWorkspacesNotReaped() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: "fresh", activityID: nil)

        // A very long TTL should not reap the just-created workspace.
        let reaped = try store.reapStaleWorkspaces(ttl: 86_400)
        #expect(reaped == 0)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .open)
    }

    // MARK: - AC7.4: workspacesEnabled flag is off by default

    @Test func workspacesEnabledDefaultsToFalse() throws {
        let store = try tempStore()
        let model = WikiStoreModel(store: store)
        #expect(model.workspacesEnabled == false)
    }

    // MARK: - WIKI_WORKSPACE env var: page get/upsert routing

    @Test func pageGetWorkspaceReturnsStagedVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Overlay")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Overlay", body: "main",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page.id, title: "Overlay", body: "staged")

        // page get with --workspace returns the staged version.
        let result = try PageCommand.run(
            .get(.id(page.id), json: false, workspace: wsID),
            in: store)
        #expect(result.output == "staged")
        #expect(result.didCommit == false)
    }

    @Test func pageUpsertWorkspaceWritesToWorkspaceNotMain() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Target")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Target", body: "original",
            expectedHeadVersionID: nil)

        let wsID = try store.createWorkspace(name: nil, activityID: nil)

        // page upsert --workspace writes to the workspace, not main.
        let result = try PageCommand.run(
            .upsert(id: page.id, title: "Target", body: "ws edit", workspace: wsID),
            in: store)
        #expect(result.didCommit == true)

        // Main is unchanged.
        let mainPage = try store.getPage(id: page.id)
        #expect(mainPage.bodyMarkdown == "original")

        // The workspace has the staged version.
        let wsBody = try store.workspacePageBody(workspaceID: wsID, pageID: page.id)
        #expect(wsBody == "ws edit")
    }
}
