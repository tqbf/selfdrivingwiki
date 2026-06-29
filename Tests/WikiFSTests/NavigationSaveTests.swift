import Foundation
import Testing
@testable import WikiFSCore

/// Regression suite for in-app navigation save semantics (§3.5 / §9.4).
/// Tab switches (setActiveTab) stash drafts without saving; sidebar clicks
/// (handleSelectionChange) and programmatic navigation (select()) flush the
/// draft to the database before loading the incoming page. Locks in:
///   1. select() flushes synchronously before loading the new page
///   2. handleSelectionChange() (sidebar click) flushes and loads
///   3. summaries are rebuilt from the store after mutations, never patched
@MainActor
struct NavigationSaveTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-autosave-\(UUID().uuidString).sqlite")
    }

    @Test func selectFlushesCurrentDraftThenLoadsNewPage() throws {
        let url = tempURL()
        let model = WikiStoreModel(store: try SQLiteWikiStore(databaseURL: url))

        // Create A and B (newPage selects the just-created page).
        model.newPage(title: "A")
        let aID = model.selection!
        model.newPage(title: "B")
        let bID = model.selection!

        // Select A, type into the body (no autosave — only explicit save).
        model.select(aID)
        model.draftBody = "A-edit"
        model.bodyChanged()

        // select() flushes the outgoing draft synchronously before loading B.
        model.select(bID)

        // B is now loaded with its (empty) body; A's edit was flushed to DB.
        #expect(model.selection == bID)
        #expect(model.draftBody == "")

        // Reload A from the store and confirm the draft was persisted.
        model.select(aID)
        #expect(model.draftBody == "A-edit")

        // Now mutate B, flush explicitly, reopen the store at the same URL,
        // and confirm BOTH pages persisted their latest text.
        model.select(bID)
        model.draftBody = "B-edit"
        model.bodyChanged()
        model.flushPendingSave()

        // selection is now a WikiSelection; pull the page ids back out to read.
        guard case let .page(aPageID) = aID, case let .page(bPageID) = bID else {
            Issue.record("expected page selections"); return
        }
        let reopened = try SQLiteWikiStore(databaseURL: url)
        #expect(try reopened.getPage(id: aPageID).bodyMarkdown == "A-edit")
        #expect(try reopened.getPage(id: bPageID).bodyMarkdown == "B-edit")
    }

    @Test func summariesRebuiltFromSourceAfterMutations() throws {
        let model = WikiStoreModel(store: try SQLiteWikiStore(databaseURL: tempURL()))
        model.newPage(title: "First")
        model.newPage(title: "Second")
        #expect(model.summaries.count == 2)

        let firstID = model.summaries.first { $0.title == "First" }!.id
        model.delete(firstID)
        // Rebuilt from source — not a stale cache.
        #expect(model.summaries.count == 1)
        #expect(model.summaries.allSatisfy { $0.title != "First" })
    }

    /// The sidebar / List-driven path: SwiftUI writes `selection` directly, then
    /// the view calls `handleSelectionChange(to:)`. This must flush the outgoing
    /// page's draft and load the incoming page — the same guarantee as `select`.
    @Test func listSelectionChangeFlushesAndLoads() throws {
        let url = tempURL()
        let model = WikiStoreModel(store: try SQLiteWikiStore(databaseURL: url))
        model.newPage(title: "A")
        let aID = model.selection!
        model.newPage(title: "B")
        let bID = model.selection!

        // Simulate List selecting A (binding writes selection, view fires onChange).
        model.selection = aID
        model.handleSelectionChange(to: aID)
        model.draftBody = "A via list"
        model.bodyChanged()

        // Now the List selects B before the debounce fires.
        model.selection = bID
        model.handleSelectionChange(to: bID)
        #expect(model.draftBody == "")  // B is empty, A's edit was flushed

        model.selection = aID
        model.handleSelectionChange(to: aID)
        #expect(model.draftBody == "A via list")
    }

    @Test func renameUpdatesSummaryFromSource() throws {
        let model = WikiStoreModel(store: try SQLiteWikiStore(databaseURL: tempURL()))
        model.newPage(title: "Old Name")
        guard case let .page(id)? = model.selection else {
            Issue.record("expected a page selection"); return
        }
        model.rename(id, to: "New Name")
        #expect(model.summaries.first { $0.id == id }?.title == "New Name")
        #expect(model.draftTitle == "New Name")
    }
}
