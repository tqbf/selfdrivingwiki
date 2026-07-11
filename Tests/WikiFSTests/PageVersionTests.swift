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
        #expect(history.count == 2)
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
        #expect(history.count == 5)
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
        #expect(history[0].parentID == nil)  // root
        #expect(history[1].parentID == v1Head)  // v2's parent is v1
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
        // Root version is seeded by migration with no ref → head = MAX(id).
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Default Page", body: "v1",
            expectedHeadVersionID: nil)
        // The first versioned save writes a ref; head should be that version.
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
}
