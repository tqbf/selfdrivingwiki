import Foundation
import Testing
@testable import WikiFSCore

/// #817 — Tests for the Versions-window data path (AC.5 / AC.7): that
/// `pageVersionBody` reads feed correctly into the diff engine
/// (`MarkdownDiff` + `SplitDiff`) that `SplitDiffView` renders, and that the
/// "current" marker + default Base/Compare selection resolve against the store.
///
/// The view logic itself (`SplitDiffView`) is reused unchanged from the
/// extraction-compare surface; these tests pin the *wiring* — the contract
/// between the new page-version reads and the existing diff pipeline.
@MainActor
struct PageVersionSelectionTests {

    private func tempStore() throws -> GRDBWikiStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
    }

    /// AC.7 — two page-version bodies read via `pageVersionBody` produce the
    /// expected `MarkdownDiff` line diff (the same pipeline `SplitDiffView`
    /// runs). The added/removed lines reflect the v1→v2 edit exactly.
    @Test func pageVersionBodiesFeedLineDiff() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Diff Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Diff Page",
            body: "line one\nline two\nline three",
            expectedHeadVersionID: nil)
        let v1 = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Diff Page",
            body: "line one\nline TWO\nline three\nline four",
            expectedHeadVersionID: v1)

        let left = try store.pageVersionBody(versionID: v1)!   // before
        let right = try store.pageVersionBody(versionID: try store.pageHeadVersionID(pageID: page.id)!)!  // after

        // The exact pipeline SplitDiffView.recompute runs:
        let lines = MarkdownDiff.lineDiff(left, right)
        let added = lines.filter { $0.kind == .added }.map(\.text)
        let removed = lines.filter { $0.kind == .removed }.map(\.text)

        #expect(removed == ["line two"], "v1's 'line two' was removed in v2")
        #expect(added == ["line TWO", "line four"], "v2 added 'line TWO' + 'line four'")
    }

    /// AC.7 — the diff pipeline degrades to a clean whole-doc change when the
    /// two versions share no lines (proves the SplitDiff path doesn't crash on
    /// a complete rewrite — the `SplitDiffView` empty/collapsed bands depend on
    /// this).
    @Test func pageVersionDiffHandlesCompleteRewrite() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "Rewrite Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Rewrite Page", body: "alpha\nbeta",
            expectedHeadVersionID: nil)
        let v1 = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Rewrite Page", body: "gamma\ndelta",
            expectedHeadVersionID: v1)

        let left = try store.pageVersionBody(versionID: v1)!
        let right = try store.pageVersionBody(versionID: try store.pageHeadVersionID(pageID: page.id)!)!

        let rows = SplitDiff.rows(from: MarkdownDiff.lineDiff(left, right))
        // No row should be equal on both sides (a complete rewrite).
        #expect(rows.allSatisfy { !($0.left?.kind == .equal && $0.right?.kind == .equal) })
        // Every left cell is a removal, every right cell is an addition.
        #expect(rows.allSatisfy { $0.left?.kind == .removed || $0.left == nil })
        #expect(rows.allSatisfy { $0.right?.kind == .added || $0.right == nil })
    }

    /// AC.5 — the "current" marker + default Base/Compare resolve against the
    /// store: `pageOrigin` (HEAD) picks out exactly the newest version, and the
    /// history offers at least two distinct versions to diff. This is the
    /// invariant the Versions-window sidebar's default selection relies on.
    @Test func headOriginPicksNewestAndHistoryHasTwoVersions() throws {
        let store = try tempStore()
        let page = try store.createPage(title: "History Page")
        _ = try store.appendPageVersion(
            pageID: page.id, title: "History Page", body: "v1",
            expectedHeadVersionID: nil)
        let v1 = try store.pageHeadVersionID(pageID: page.id)!
        _ = try store.appendPageVersion(
            pageID: page.id, title: "History Page", body: "v2",
            expectedHeadVersionID: v1)

        let history = try store.pageVersionHistory(pageID: page.id)
        #expect(history.count >= 2, "at least two versions exist to compare")

        // The HEAD origin's versionID is the newest (last in oldest-first order).
        let head = try store.pageHeadVersionID(pageID: page.id)!
        #expect(head == history.last?.id, "HEAD is the newest version")
        #expect(head != v1, "HEAD moved past v1 after the second save")
    }
}
