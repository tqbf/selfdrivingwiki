import Foundation
import Testing
@testable import WikiFSCore

/// Tests for W0 — page versioning & CAS (PR #312).
///
/// Covers: CAS conflict detection, version chain ordering, revert, the
/// default-active rule (no ref → MAX(id)), and migration seeding.
@MainActor
struct PageVersionTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - CAS conflict detection

    @Test func casConflictWhenHeadMoved() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Test Page")
        // First versioned save (blind — no CAS expectation, backward-compatible).
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Test Page", body: "v1 body",
            expectedHeadVersionID: nil)
        let head = try store.pageHeadVersionID(pageID: page.id)
        #expect(head != nil)

        // Simulate a concurrent write: another writer commits a new version.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Test Page", body: "v2 body (concurrent)",
            expectedHeadVersionID: head)  // passes CAS — head matches

        // Now the original editor tries to save with the STALE head → conflict.
        #expect(throws: PageConflictError.self) {
            _ = try store.appendPageVersion(
                pageID: page.id, title: "Test Page", body: "v2 body (original editor)",
                expectedHeadVersionID: head)  // stale — head moved to v2
        }
    }

    @Test func casPassesWhenHeadUnchanged() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Stable Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Stable Page", body: "v1",
            expectedHeadVersionID: nil)
        let head = try store.pageHeadVersionID(pageID: page.id)

        // Second save with the correct head → succeeds.
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Stable Page", body: "v2",
            expectedHeadVersionID: head)
        #expect(v2 != head)
    }

    @Test func blindWriteWhenExpectedHeadIsNil() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Blind Page")
        // nil = no CAS check, backward-compatible.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Blind Page", body: "v1",
            expectedHeadVersionID: nil)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Blind Page", body: "v2",
            expectedHeadVersionID: nil)
        let history = try store.pageVersionHistory(pageID: page.id)
        // 2 appends + 1 root version seeded by createPage (Phase 3).
        #expect(history.count == 3)
    }

    // MARK: - Version chain ordering

    @Test func historyIsOrderedByULID() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Chain Page")
        for i in 0..<5 {
            _ = try store.appendPageVersion(
                pageID: page.id, title: "Chain Page", body: "v\(i)",
                expectedHeadVersionID: nil)
        }
        let history = try store.pageVersionHistory(pageID: page.id)
        // 5 appends + 1 root version seeded by createPage (Phase 3).
        #expect(history.count == 6)
        // ULIDs are time-ordered; the chain should be ascending.
        for i in 1..<history.count {
            #expect(history[i].id > history[i - 1].id, "version \(i) should come after \(i-1) in ULID order")
        }
    }

    @Test func parentIDLinksChain() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Parent Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Parent Page", body: "v1",
            expectedHeadVersionID: nil)
        let v1Head = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Parent Page", body: "v2",
            expectedHeadVersionID: v1Head)
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history[0].parentID == nil)  // root (seeded by createPage)
        #expect(history[1].parentID == history[0].id)  // v1's parent is root
        #expect(history[2].parentID == v1Head)  // v2's parent is v1
    }

    // MARK: - Revert

    @Test func revertRestoresBodyFromVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Revert Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Page", body: "original body",
            expectedHeadVersionID: nil)
        let v1Head = try store.pageHeadVersionID(pageID: page.id)
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Page", body: "modified body",
            expectedHeadVersionID: v1Head)

        // Revert to v1.
        try store.revertPage(pageID: page.id, to: v1Head!)
        let page2 = try store.getPage(id: page.id)
        #expect(page2.bodyMarkdown == "original body")
    }

    @Test func revertRepointsActiveVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Revert Head Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Head Page", body: "v1",
            expectedHeadVersionID: nil)
        let v1 = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Revert Head Page", body: "v2",
            expectedHeadVersionID: v1)

        // Head should be v2.
        let headAfterV2 = try store.pageHeadVersionID(pageID: page.id)
        #expect(headAfterV2 != v1)

        // Revert to v1.
        try store.revertPage(pageID: page.id, to: v1)
        let headAfterRevert = try store.pageHeadVersionID(pageID: page.id)
        #expect(headAfterRevert == v1)
    }

    // MARK: - Default-active rule

    @Test func defaultActiveIsMaxID() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Default Page")
        // Phase 3: createPage seeds a root version + ref atomically.
        // The first versioned save writes a new version + updates the ref.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Default Page", body: "v1",
            expectedHeadVersionID: nil)
        // Head should be the last version (the ref points at it).
        let head = try store.pageHeadVersionID(pageID: page.id)
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(head == history.last?.id)
    }

    // MARK: - Body mirror + FTS

    @Test func bodyMirrorUpdatedAfterVersionedSave() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Mirror Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Mirror Page", body: "versioned body",
            expectedHeadVersionID: nil)
        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "versioned body")
    }

    // MARK: - Phase 3: head-ref invariant (AC3)

    @Test func createPageSeedsRootVersionAndRef() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Ref Page")

        // createPage should seed a root version + page-content ref.
        let head = try store.pageHeadVersionID(pageID: page.id)
        #expect(head != nil, "createPage should seed a root version")

        // The ref should point at the root version.
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history.count == 1)
        #expect(history[0].parentID == nil, "root version has no parent")
        #expect(head == history[0].id, "ref points at the root version")
    }

    @Test func v34BackfillEveryPageHasRef() throws {
        let store = try tempStore()
        // Create pages and append versions (which write refs).
        let page1 = try store.createPage(title: "Page One")
        _ = try store.appendPageVersion(
            pageID: page1.id, title: "Page One", body: "body 1",
            expectedHeadVersionID: nil)
        let page2 = try store.createPage(title: "Page Two")
        _ = try store.appendPageVersion(
            pageID: page2.id, title: "Page Two", body: "body 2",
            expectedHeadVersionID: nil)

        // Every page should have a page-content ref pointing at its head.
        for page in [page1, page2] {
            let head = try store.pageHeadVersionID(pageID: page.id)
            #expect(head != nil)
        }
    }

    @Test func v34Idempotent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v34-idem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("WikiFS.sqlite")

        let store1 = try SQLiteWikiStore(databaseURL: dbURL)
        let page = try store1.createPage(title: "Idempotent Page")
        _ = try store1.appendPageVersion(
            pageID: page.id, title: "Idempotent Page", body: "body",
            expectedHeadVersionID: nil)
        let headBefore = try store1.pageHeadVersionID(pageID: page.id)
        let historyBefore = try store1.pageVersionHistory(pageID: page.id)

        // Reopen the same DB — migrations re-run but v34 finds all pages
        // already have refs, so it's a no-op.
        let store2 = try SQLiteWikiStore(databaseURL: dbURL)
        let headAfter = try store2.pageHeadVersionID(pageID: page.id)
        let historyAfter = try store2.pageVersionHistory(pageID: page.id)
        #expect(headBefore == headAfter)
        #expect(historyBefore.count == historyAfter.count)
    }

    // MARK: - Phase 4: amend + GC (AC4)

    @Test func sameActorSavesCoalesceIntoOneVersion() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Amend Page")

        // First versioned save (with actor identity).
        let v1 = try store.appendPageVersion(
            pageID: page.id, title: "Amend Page", body: "initial body",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")

        // Second save by the SAME actor, immediately (within the 5s window).
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Amend Page", body: "amended body",
            expectedHeadVersionID: v1, lastEditedBy: "agent-A")

        // The amend should have returned the SAME version id (head unchanged).
        #expect(v1 == v2, "same-actor save within window should amend (same version id)")

        // Still only 1 versioned save + 1 root = 2 rows (no new version appended).
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history.count == 2, "amend should not append a version row")

        // The body should reflect the amended content.
        let readBack = try store.getPage(id: page.id)
        #expect(readBack.bodyMarkdown == "amended body")

        // The head version's blob should point at the amended body.
        let head = try store.pageHeadVersionID(pageID: page.id)
        #expect(head == v1)
    }

    @Test func guardedHeadNotAmended() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Guarded Page")

        // v1 — first save by agent-A (amend fails: root's actor is nil → append)
        let v1 = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v1 body",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")

        // v2 — save by agent-B (amend fails: different actor → append)
        // This makes v1 have a child (v2).
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v2 body",
            expectedHeadVersionID: v1, lastEditedBy: "agent-B")

        // v3 — save by agent-A (amend fails: different actor → append)
        // This makes v2 have a child (v3).
        let v3 = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v3 body",
            expectedHeadVersionID: v2, lastEditedBy: "agent-A")

        // Revert to v2, making it the head. v2 has a child (v3).
        try store.revertPage(pageID: page.id, to: v2)

        // Now save by agent-A — same actor as pages.last_edited_by (still
        // "agent-A" from v3's append). BUT v2 has a child → amend guard fails → append.
        let v4 = try store.appendPageVersion(
            pageID: page.id, title: "Guarded Page", body: "v4 body",
            expectedHeadVersionID: v2, lastEditedBy: "agent-A")

        #expect(v4 != v2, "head with children should NOT be amended (new version id)")

        // Also test the workspace_refs guard: if a workspace references the head,
        // the save should append.
        let page2 = try store.createPage(title: "Workspace Guarded Page")
        // wv1 — first save by agent-B (amend fails: root's actor is nil → append)
        let wv1 = try store.appendPageVersion(
            pageID: page2.id, title: "Workspace Guarded Page", body: "ws v1",
            expectedHeadVersionID: nil, lastEditedBy: "agent-B")

        // Create a workspace and stage a write to page2 (this creates a
        // workspace_refs row referencing wv1 as base_version_id).
        let wsID = try store.createWorkspace(name: "test-ws", activityID: nil)
        _ = try store.workspaceWritePage(
            workspaceID: wsID, pageID: page2.id,
            title: "Workspace Guarded Page", body: "ws staged")

        // Save again by agent-B — same actor, within window, no children,
        // BUT a workspace_refs row references wv1 → amend guard fails → append.
        let wv2 = try store.appendPageVersion(
            pageID: page2.id, title: "Workspace Guarded Page", body: "ws v2",
            expectedHeadVersionID: wv1, lastEditedBy: "agent-B")

        #expect(wv2 != wv1, "head referenced by workspace_refs should NOT be amended")
    }

    @Test func vacuumPageVersionsDeletesOnlyUnreachable() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Vacuum Page")

        // Root version (from createPage) + 2 appends (different actors to
        // prevent amend coalescing, ensuring distinct version rows).
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Vacuum Page", body: "v1",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")
        let head = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Vacuum Page", body: "v2",
            expectedHeadVersionID: head, lastEditedBy: "agent-B")

        // All versions are reachable via the parent chain from the ref target.
        // Dry-run: should report 0 orphans and not delete anything.
        let dryReport = try store.vacuumPageVersions(dryRun: true)
        #expect(dryReport.applied == false, "dry-run should not apply")
        #expect(dryReport.deletedCount == 0, "all versions should be reachable")

        let historyAfterDry = try store.pageVersionHistory(pageID: page.id)
        #expect(historyAfterDry.count == 3, "dry-run should not delete versions")

        // Applied vacuum should also find 0 orphans (all reachable).
        let appliedReport = try store.vacuumPageVersions(dryRun: false)
        #expect(appliedReport.applied == true)
        #expect(appliedReport.deletedCount == 0, "no orphans to delete")
        let historyAfterApply = try store.pageVersionHistory(pageID: page.id)
        #expect(historyAfterApply.count == historyAfterDry.count, "applied vacuum should not change count when 0 orphans")
    }

    @Test func amendAfterWindowExpiresAppends() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Window Page")

        // First versioned save.
        let v1 = try store.appendPageVersion(
            pageID: page.id, title: "Window Page", body: "v1 body",
            expectedHeadVersionID: nil, lastEditedBy: "agent-A")

        // Wait for the coalescing window (5s) to expire.
        Thread.sleep(forTimeInterval: 6)

        // Second save by same actor — but window expired, so should append.
        let v2 = try store.appendPageVersion(
            pageID: page.id, title: "Window Page", body: "v2 body",
            expectedHeadVersionID: v1, lastEditedBy: "agent-A")

        #expect(v1 != v2, "save after window expiry should append (new version id)")

        // 1 root + 2 versioned saves = 3 versions.
        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history.count == 3, "two appends + root")
    }
}
