import Foundation
import Testing
@testable import WikiFSCore

/// Tests for:
/// 1. Default untitled page titles include a timestamp so they don't collide.
/// 2. Renaming a page to a title already used by another page is blocked.
@MainActor
struct PageTitleCollisionTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-title-collision-\(UUID().uuidString).sqlite")
    }

    // MARK: - Timestamped default title

    @Test func defaultUntitledTitleIncludesTimestamp() {
        let title = WikiStoreModel.defaultUntitledTitle()
        // Should start with "Untitled " and have a date-like suffix.
        #expect(title.hasPrefix("Untitled "))
        // The suffix should be parseable as "yyyy-MM-dd HH:mm:ss".
        let suffix = title.dropFirst("Untitled ".count)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        #expect(formatter.date(from: String(suffix)) != nil)
    }

    @Test func defaultUntitledTitleChangesOverTime() async throws {
        let title1 = WikiStoreModel.defaultUntitledTitle()
        // Wait just over a second so the timestamp is different at second
        // granularity (DateFormatter rounds to whole seconds).
        try await Task.sleep(for: .seconds(2))
        let title2 = WikiStoreModel.defaultUntitledTitle()
        #expect(title1 != title2)
    }

    @Test func newPageWithoutExplicitTitleGetsTimestamp() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPage()
        model.reloadFromStore()
        let summary = try #require(model.summaries.first)
        #expect(summary.title.hasPrefix("Untitled "))
        #expect(summary.title != "Untitled")
    }

    @Test func newPageInNewTabWithoutExplicitTitleGetsTimestamp() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPageInNewTab()
        model.reloadFromStore()
        let summary = try #require(model.summaries.first)
        #expect(summary.title.hasPrefix("Untitled "))
        #expect(summary.title != "Untitled")
    }

    // MARK: - Rename collision

    @Test func renameToExistingTitleIsBlocked() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPage(title: "First Page")
        model.newPage(title: "Second Page")
        model.reloadFromStore()
        guard case let .page(secondID)? = model.selection else {
            Issue.record("expected a page selection"); return
        }

        // Try to rename Second Page → "First Page" (already exists).
        model.rename(secondID, to: "First Page")
        model.reloadFromStore()

        // The rename should be blocked: title unchanged, conflict surfaced.
        #expect(model.summaries.first { $0.id == secondID }?.title == "Second Page")
        #expect(model.renameConflictingTitle == "First Page")
    }

    @Test func renameToOwnTitleIsAllowed() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPage(title: "Same Title")
        model.reloadFromStore()
        guard case let .page(id)? = model.selection else {
            Issue.record("expected a page selection"); return
        }

        // Renaming to the same title should not trigger a conflict.
        model.rename(id, to: "Same Title")
        model.reloadFromStore()
        #expect(model.renameConflictingTitle == nil)
        #expect(model.summaries.first { $0.id == id }?.title == "Same Title")
    }

    @Test func renameToExistingTitleCaseInsensitiveIsBlocked() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPage(title: "My Page")
        model.newPage(title: "Other Page")
        model.reloadFromStore()
        guard case let .page(otherID)? = model.selection else {
            Issue.record("expected a page selection"); return
        }

        // "MY PAGE" should collide with "My Page" (case-insensitive).
        model.rename(otherID, to: "MY PAGE")
        model.reloadFromStore()
        #expect(model.summaries.first { $0.id == otherID }?.title == "Other Page")
        #expect(model.renameConflictingTitle == "MY PAGE")
    }

    @Test func renameToUniqueTitleSucceeds() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPage(title: "Alpha")
        model.newPage(title: "Beta")
        model.reloadFromStore()
        guard case let .page(betaID)? = model.selection else {
            Issue.record("expected a page selection"); return
        }

        model.rename(betaID, to: "Gamma")
        model.reloadFromStore()
        #expect(model.renameConflictingTitle == nil)
        #expect(model.summaries.first { $0.id == betaID }?.title == "Gamma")
    }

    @Test func clearRenameConflictResets() throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        model.newPage(title: "A")
        model.newPage(title: "B")
        model.reloadFromStore()
        guard case let .page(bID)? = model.selection else {
            Issue.record("expected a page selection"); return
        }

        model.rename(bID, to: "A")
        #expect(model.renameConflictingTitle != nil)

        model.clearRenameConflict()
        #expect(model.renameConflictingTitle == nil)
    }
}
