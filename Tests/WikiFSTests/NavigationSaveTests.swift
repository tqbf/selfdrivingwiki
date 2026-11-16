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

    @Test func selectFlushesCurrentDraftThenLoadsNewPage() async throws {
        let url = tempURL()
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: url))

        // Create A and B (newPage selects the just-created page).
        await model.newPage(title: "A")
        let aID = model.selection!
        await model.newPage(title: "B")
        let bID = model.selection!
        await model.bootstrapFromStore()

        // Select A, type into the body (no autosave — only explicit save).
        model.select(aID)
        await model.quiesceSelectionTransitions()
        model.draftBody = "A-edit"
        model.bodyChanged()

        // select() flushes the outgoing draft synchronously before loading B.
        model.select(bID)
        await model.quiesceSelectionTransitions()

        // B is now loaded with its (empty) body; A's edit was flushed to DB.
        #expect(model.selection == bID)
        #expect(model.draftBody == "")

        // Reload A from the store and confirm the draft was persisted.
        model.select(aID)
        await model.quiesceSelectionTransitions()
        #expect(model.draftBody == "A-edit")

        // Now mutate B, flush explicitly, reopen the store at the same URL,
        // and confirm BOTH pages persisted their latest text.
        model.select(bID)
        await model.quiesceSelectionTransitions()
        model.draftBody = "B-edit"
        model.bodyChanged()
        await model.flushPendingSave()
        await model.quiesceSelectionTransitions()

        // selection is now a WikiSelection; pull the page ids back out to read.
        guard case let .page(aPageID) = aID, case let .page(bPageID) = bID else {
            Issue.record("expected page selections"); return
        }
        let reopened = try StoreBackend.current.makeStore(databaseURL: url)
        #expect(try await reopened.getPage(id: aPageID).bodyMarkdown == "A-edit")
        #expect(try await reopened.getPage(id: bPageID).bodyMarkdown == "B-edit")
    }

    @Test func summariesRebuiltFromSourceAfterMutations() async throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        await model.newPage(title: "First")
        await model.newPage(title: "Second")
        await model.bootstrapFromStore()
        #expect(model.summaries.count == 2)

        let firstID = model.summaries.first { $0.title == "First" }!.id
        try await model.delete(firstID, unlinkIncomingLinks: false)
        await model.bootstrapFromStore()
        // Rebuilt from source — not a stale cache.
        #expect(model.summaries.count == 1)
        #expect(model.summaries.allSatisfy { $0.title != "First" })
    }

    /// The sidebar / List-driven path: SwiftUI writes `selection` directly, then
    /// the view calls `handleSelectionChange(to:)`. This must flush the outgoing
    /// page's draft and load the incoming page — the same guarantee as `select`.
    @Test func listSelectionChangeFlushesAndLoads() async throws {
        let url = tempURL()
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: url))
        await model.newPage(title: "A")
        let aID = model.selection!
        await model.newPage(title: "B")
        let bID = model.selection!
        await model.bootstrapFromStore()

        // Simulate List selecting A (binding writes selection, view fires onChange).
        model.selection = aID
        model.handleSelectionChange(to: aID)
        await model.quiesceSelectionTransitions()
        model.draftBody = "A via list"
        model.bodyChanged()

        // Now the List selects B before the debounce fires.
        model.selection = bID
        model.handleSelectionChange(to: bID)
        await model.quiesceSelectionTransitions()
        #expect(model.draftBody == "")  // B is empty, A's edit was flushed

        model.selection = aID
        model.handleSelectionChange(to: aID)
        await model.quiesceSelectionTransitions()
        #expect(model.draftBody == "A via list")
    }

    @Test func renameUpdatesSummaryFromSource() async throws {
        let model = WikiStoreModel(store: try StoreBackend.current.makeStore(databaseURL: tempURL()))
        await model.newPage(title: "Old Name")
        await model.bootstrapFromStore()
        guard case let .page(id)? = model.selection else {
            Issue.record("expected a page selection"); return
        }
        await model.rename(id, to: "New Name")
        await model.bootstrapFromStore()
        #expect(model.summaries.first { $0.id == id }?.title == "New Name")
        #expect(model.draftTitle == "New Name")
    }
}
