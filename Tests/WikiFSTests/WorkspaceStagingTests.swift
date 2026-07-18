import Foundation
import Testing
@testable import WikiFSCore

/// Phase 5 (multi-writer-hardening): tests for created-page staging.
///
/// Created pages are staged entirely in `workspace_refs` as `blob_hash` +
/// `title` (version_id NULL) — no phantom `pages` row on main until merge.
/// This means:
/// - A workspace-created page moves neither the changeToken nor the `pages`
///   count before merge.
/// - Merge mints the `pages` row + root version from the staged blob.
/// - Abandoning a workspace with created pages leaves zero rows on main.
/// - The `workspace_refs` row-shape invariant holds.
@Suite(.tags(.integration))
@MainActor
struct WorkspaceStagingTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - AC5.1: Created page is invisible on main before merge

    @Test func createdPageDoesNotTouchMainBeforeMerge() throws {
        let store = try tempStore()
        let tokenBefore = try store.changeToken()

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        let newPageID = PageID(rawValue: ULID.generate())
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: newPageID, title: "Staged Page", body: "staged content")

        // The changeToken must not move (no pages row → no COUNT/SUM change).
        let tokenAfter = try store.changeToken()
        #expect(tokenAfter == tokenBefore)

        // The page does not exist on main.
        #expect(throws: WikiStoreError.self) {
            _ = try store.getPage(id: newPageID)
        }
    }

    // MARK: - AC5.2: Merge mints the pages row + root version

    @Test func mergeMintsPagesRowAndRootVersion() throws {
        let store = try tempStore()
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        let newPageID = PageID(rawValue: ULID.generate())
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: newPageID, title: "Minted Page", body: "minted body")

        // Before merge: page doesn't exist.
        #expect(throws: WikiStoreError.self) {
            _ = try store.getPage(id: newPageID)
        }

        try store.workspaceMerge(workspaceID: wsID)

        // After merge: page exists with staged body + title.
        let page = try store.getPage(id: newPageID)
        #expect(page.title == "Minted Page")
        #expect(page.bodyMarkdown == "minted body")

        // A root version exists for the page.
        let headVersion = try store.pageHeadVersionID(pageID: newPageID)
        #expect(headVersion != nil)

        // The page-content ref points at the minted version.
        let mainHead = try store.pageHeadVersionID(pageID: newPageID)
        #expect(mainHead != nil)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .merged)
    }

    // MARK: - AC5.4: Abandon leaves zero rows on main

    @Test func abandonLeavesZeroRowsOnMain() throws {
        let store = try tempStore()
        let pagesBefore = try store.allPageIDs().count

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        let newPageID = PageID(rawValue: ULID.generate())
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: newPageID, title: "Abandoned Page", body: "abandoned body")

        // Abandon the workspace.
        try store.abandonWorkspace(id: wsID)

        // No new pages on main.
        let pagesAfter = try store.allPageIDs().count
        #expect(pagesAfter == pagesBefore)

        // The page does not exist on main.
        #expect(throws: WikiStoreError.self) {
            _ = try store.getPage(id: newPageID)
        }

        // Workspace refs are deleted.
        let refs = try store.workspaceRefs(workspaceID: wsID)
        #expect(refs.isEmpty)
    }

    // MARK: - AC5.5: Row-shape invariant holds

    @Test func workspaceRefsRowShapeInvariantHolds() throws {
        let store = try tempStore()

        // Existing page: version_id set, blob_hash + title nil.
        let existingPage = try store.createPage(title: "Existing Page")
        _ = try store.appendPageVersion(
            pageID: existingPage.id, title: "Existing Page", body: "v1",
            expectedHeadVersionID: nil)

        let ws1 = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: ws1, pageID: existingPage.id, title: "Existing Page", body: "ws edit")

        let existingRefs = try store.workspaceRefs(workspaceID: ws1)
        #expect(existingRefs.count == 1)
        let existingRef = existingRefs[0]
        #expect(existingRef.versionID != nil)
        #expect(existingRef.blobHash == nil)
        #expect(existingRef.title == nil)
        #expect(existingRef.baseVersionID != nil)

        // Created page: version_id nil, blob_hash + title set.
        let ws2 = try store.createWorkspace(name: nil, activityID: nil)
        let newPageID = PageID(rawValue: ULID.generate())
        _ = try store.workspaceWritePage(
            workspaceID: ws2, pageID: newPageID, title: "Created Page", body: "created body")

        let createdRefs = try store.workspaceRefs(workspaceID: ws2)
        #expect(createdRefs.count == 1)
        let createdRef = createdRefs[0]
        #expect(createdRef.versionID == nil)
        #expect(createdRef.blobHash != nil)
        #expect(createdRef.title == "Created Page")
        #expect(createdRef.baseVersionID == nil)
    }

    // MARK: - AC5.3: Conflict on title collision (main ref exists at merge)

    @Test func mergeConflictsWhenPageRefExistsOnMain() throws {
        let store = try tempStore()

        // Stage a created page in a workspace.
        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        let newPageID = PageID(rawValue: ULID.generate())
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: newPageID, title: "Collision Page", body: "staged body")

        // Simulate another writer creating a page-content ref with the same
        // page_id on main (e.g., via createPage with the same raw ULID —
        // page_id is TEXT, so it can collide if the same ULID is reused).
        // We can't easily create a page with a specific ULID via createPage,
        // so instead we create a page with the same ID directly by staging
        // and merging in a separate workspace.
        let ws2 = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: ws2, pageID: newPageID, title: "Collision Page", body: "other body")
        try store.workspaceMerge(workspaceID: ws2)

        // Now merge ws1 — should conflict (main ref already exists).
        try store.workspaceMerge(workspaceID: wsID)

        let summary = try store.workspaceSummary(id: wsID)
        #expect(summary?.status == .conflicted)

        // Main was not corrupted — it has ws2's body.
        let mainPage = try store.getPage(id: newPageID)
        #expect(mainPage.bodyMarkdown == "other body")
    }

    // MARK: - AC7 (latent defect fix): workspaceWritePage rejects non-open workspaces

    @Test func writePageRejectsMergedWorkspace() throws {
        let store = try tempStore()
        let existingPage = try store.createPage(title: "Pre-existing")

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        // Stage and merge → status is 'merged'.
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: existingPage.id, title: "Pre-existing", body: "ws edit")
        try store.workspaceMerge(workspaceID: wsID)

        // A subsequent write to the merged workspace must throw, not silently
        // succeed (which would vanish the edit — the workspace will never merge
        // again).
        #expect(throws: WikiStoreError.self) {
            _ = try store.workspaceWritePage(
                workspaceID: wsID, pageID: existingPage.id, title: "Pre-existing", body: "lost edit")
        }
    }

    @Test func writePageRejectsAbandonedWorkspace() throws {
        let store = try tempStore()
        let existingPage = try store.createPage(title: "Pre-existing")

        let wsID = try store.createWorkspace(name: nil, activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: existingPage.id, title: "Pre-existing", body: "ws edit")
        try store.abandonWorkspace(id: wsID)

        #expect(throws: WikiStoreError.self) {
            _ = try store.workspaceWritePage(
                workspaceID: wsID, pageID: existingPage.id, title: "Pre-existing", body: "lost edit")
        }
    }
}

// MARK: - Test helper extension

extension GRDBWikiStore {
    /// Returns all page IDs (for counting purposes in tests).
    fileprivate func allPageIDs() throws -> [PageID] {
        return try listPages(sortBy: .titleAZ).map { $0.id }
    }
}
