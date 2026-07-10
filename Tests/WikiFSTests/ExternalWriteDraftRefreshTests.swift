import Foundation
import Testing
@testable import WikiFSCore

/// Regression suite for the "stale UI after agent page write" bug.
///
/// When the agent (or `wikictl`) writes page content through the store
/// directly — bypassing the model's draft system — the store emits a
/// `ResourceChangeEvent`, the model's bus handler calls `reloadFromStore()`,
/// and that must refresh the on-screen page content. Before the fix,
/// `reloadFromStore()` only rebuilt the sidebar lists; the displayed
/// `draftBody` was stale.
@MainActor
struct ExternalWriteDraftRefreshTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-ext-write-\(UUID().uuidString).sqlite")
    }

    private func makeModel() throws -> (WikiStoreModel, SQLiteWikiStore) {
        let store = try SQLiteWikiStore(databaseURL: tempURL())
        store.eventBus = WikiEventBus(wikiID: "test")
        let model = WikiStoreModel(store: store)
        return (model, store)
    }

    @Test func reloadFromStoreRefreshesCleanDraftAfterExternalWrite() throws {
        let (model, store) = try makeModel()
        model.newPage(title: "Home")
        guard case .page(let id) = model.selection else { Issue.record("expected page selection"); return }

        // The page starts empty.
        #expect(model.draftBody == "")

        // Simulate an agent write: store.updatePage directly, bypassing the
        // model's draft system (exactly what AgentOperationRunner does).
        try store.updatePage(id: id, title: "Home", body: "# Welcome\n\nAgent content.")

        // The event bus handler calls reloadFromStore(); call it directly.
        model.reloadFromStore()

        // The clean draft must now reflect the agent-written content.
        #expect(model.draftBody == "# Welcome\n\nAgent content.")
        #expect(model.draftTitle == "Home")
    }

    @Test func reloadFromStorePreservesDirtyDraftAfterExternalWrite() throws {
        let (model, store) = try makeModel()
        model.newPage(title: "Home")
        guard case .page(let id) = model.selection else { Issue.record("expected page selection"); return }

        // User starts editing — draft is now dirty.
        model.draftBody = "My unsaved edit"
        model.bodyChanged()

        // Agent writes to the same page (external store write).
        try store.updatePage(id: id, title: "Home", body: "# Agent overwrote this.")

        model.reloadFromStore()

        // The user's unsaved edit must win — never clobbered by the reload.
        #expect(model.draftBody == "My unsaved edit")
    }

    @Test func reloadFromStoreNoOpsWhenSelectionIsNotAPage() throws {
        let (model, store) = try makeModel()
        model.newPage(title: "Home")
        guard case .page(let id) = model.selection else { Issue.record("expected page selection"); return }

        // Navigate away from the page (to the .newChat surface).
        model.select(.newChat)
        #expect(model.draftBody == "")

        // External write to the page.
        try store.updatePage(id: id, title: "Home", body: "# Should not affect draft.")

        model.reloadFromStore()

        // draftBody is still empty (we're on .newChat, not the page).
        #expect(model.draftBody == "")
    }
}
