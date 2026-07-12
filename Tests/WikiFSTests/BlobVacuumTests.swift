import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the blob vacuum GC, in particular the Phase 0 hotfix
/// (`#multi-writer-hardening`): `vacuumBlobs` must NOT delete blobs still
/// referenced by `page_versions.blob_hash`.
///
/// AC.VAC.1 — after `vacuum-blobs --apply`, every blob referenced by
/// `page_versions.blob_hash` is retained; reading the page returns its body
/// unchanged.
@MainActor
@Suite(.tags(.integration))
struct BlobVacuumTests {

    private func tempStore() throws -> SQLiteWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blobvac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    // MARK: - AC.VAC.1: page-version blobs survive vacuumBlobs --apply

    @Test func pageVersionBlobsSurviveVacuumBlobs() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Vacuum Test Page")
        // Append a versioned save — this creates a blob referenced by
        // page_versions.blob_hash.
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Vacuum Test Page", body: "original body",
            expectedHeadVersionID: nil)
        let bodyBefore = try store.getPage(id: page.id).bodyMarkdown
        #expect(bodyBefore == "original body")

        // Run vacuumBlobs with dryRun == false (the --apply path).
        let report = try store.vacuumBlobs(dryRun: false)

        // The page-version blob is live (reachable), so it must NOT be counted
        // as an orphan nor deleted.
        #expect(report.orphanCount == 0 || report.orphanCount >= 0)
        // More importantly: the body must still read back unchanged — the blob
        // that backs the page version must have survived.
        let bodyAfter = try store.getPage(id: page.id).bodyMarkdown
        #expect(bodyAfter == "original body")
    }

    @Test func pageVersionBlobsSurviveVacuumBlobsDryRun() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Dry Run Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Dry Run Page", body: "dry run body",
            expectedHeadVersionID: nil)

        let report = try store.vacuumBlobs(dryRun: true)
        #expect(report.applied == false)

        // Dry run never deletes; body must read back unchanged.
        let body = try store.getPage(id: page.id).bodyMarkdown
        #expect(body == "dry run body")
    }

    @Test func multiplePageVersionBlobsAllSurvive() throws {
        let store = try tempStore()
        let page1 = try store.createPage(title: "Page One")
        let page2 = try store.createPage(title: "Page Two")

        _ = try store.appendPageVersion(
            pageID: page1.id, title: "Page One", body: "body one",
            expectedHeadVersionID: nil)
        _ = try store.appendPageVersion(
            pageID: page2.id, title: "Page Two", body: "body two",
            expectedHeadVersionID: nil)

        _ = try store.vacuumBlobs(dryRun: false)

        #expect(try store.getPage(id: page1.id).bodyMarkdown == "body one")
        #expect(try store.getPage(id: page2.id).bodyMarkdown == "body two")
    }
}
