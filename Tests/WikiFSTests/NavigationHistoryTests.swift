import Foundation
import Testing
@testable import WikiFSCore

@MainActor
struct NavigationHistoryTests {

    private func tempModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    @Test func programmaticSelectionBuildsBackAndForwardHistory() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "A")
        let b = try await store.createPage(title: "B")
        let c = try await store.createPage(title: "C")
        await model.bootstrapFromStore()

        model.select(.page(a.id))
        await model.quiesceSelectionTransitions()
        model.select(.page(b.id))
        await model.quiesceSelectionTransitions()
        model.select(.page(c.id))
        await model.quiesceSelectionTransitions()

        #expect(model.selection == .page(c.id))
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)

        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(b.id))
        #expect(model.canNavigateForward)

        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(a.id))
        #expect(!model.canNavigateBack)

        model.navigateForward()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(b.id))
    }

    @Test func listSelectionBuildsHistoryThroughChangeHandler() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "A")
        let b = try await store.createPage(title: "B")
        await model.bootstrapFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.selection = .page(b.id)
        model.handleSelectionChange(to: .page(b.id))
        await model.quiesceSelectionTransitions()

        #expect(model.selection == .page(b.id))
        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(a.id))
    }

    @Test func wikiLinkSelectionParticipatesInHistory() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        model.select(.page(from.id))
        await model.quiesceSelectionTransitions()
        #expect(model.selectPage(byTitle: "To"))
        await model.quiesceSelectionTransitions()

        #expect(model.selection == .page(to.id))
        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(from.id))
    }

    @Test func querySelectionParticipatesInHistory() async throws {
        let (model, store) = try tempModel()
        let page = try await store.createPage(title: "A")
        await model.bootstrapFromStore()

        model.select(.page(page.id))
        await model.quiesceSelectionTransitions()
        model.select(.newChat)
        await model.quiesceSelectionTransitions()

        #expect(model.selection == .newChat)
        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(page.id))
        model.navigateForward()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .newChat)
    }

    @Test func historyNavigationFlushesOutgoingDraft() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "A")
        let b = try await store.createPage(title: "B")
        await model.bootstrapFromStore()

        model.select(.page(a.id))
        await model.quiesceSelectionTransitions()
        model.select(.page(b.id))
        await model.quiesceSelectionTransitions()
        model.draftBody = "edited before back"
        model.bodyChanged()

        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(a.id))
        #expect(try store.getPage(id: b.id).bodyMarkdown == "edited before back")
    }

    @Test func newSelectionClearsForwardHistory() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "A")
        let b = try await store.createPage(title: "B")
        let c = try await store.createPage(title: "C")
        await model.bootstrapFromStore()

        model.select(.page(a.id))
        await model.quiesceSelectionTransitions()
        model.select(.page(b.id))
        await model.quiesceSelectionTransitions()
        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.canNavigateForward)

        model.select(.page(c.id))
        await model.quiesceSelectionTransitions()
        #expect(!model.canNavigateForward)
    }

    @Test func deletingSelectionRemovesItFromHistory() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "A")
        let b = try await store.createPage(title: "B")
        await model.bootstrapFromStore()

        model.select(.page(a.id))
        model.select(.page(b.id))
        try await model.delete(a.id, unlinkIncomingLinks: false)

        #expect(!model.canNavigateBack)
    }

    @Test func reloadPrunesExternallyDeletedHistoryItems() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "A")
        let b = try await store.createPage(title: "B")
        await model.bootstrapFromStore()

        model.select(.page(a.id))
        await model.quiesceSelectionTransitions()
        model.select(.page(b.id))
        await model.quiesceSelectionTransitions()
        try store.deletePage(id: a.id)

        // This harness's store has no event bus, so drive the public reload
        // entry point explicitly — the same coalesced reload a production bus
        // event would enqueue; its drain owns the history prune.
        model.reloadFromStore()
        await model.quiesceSelectionTransitions()

        #expect(!model.canNavigateBack)
    }

    // MARK: - Sort order integration

    @Test func changingSortOrderReloadsSummaries() async throws {
        let (model, store) = try tempModel()
        _ = try await store.createPage(title: "Banana")
        // Use Task.sleep to avoid blocking the cooperative thread pool (#732).
        try await Task.sleep(for: .milliseconds(2))
        _ = try await store.createPage(title: "apple")
        await model.bootstrapFromStore()

        // Default: lastUpdated — both pages have the same updated_at,
        // so we just verify two pages are loaded.
        #expect(model.summaries.count == 2)

        // Switch to title A–Z: "apple" then "Banana" (case-insensitive).
        model.pageSortOrder = .titleAZ
        #expect(model.summaries.map(\.title) == ["apple", "Banana"])

        // Switch back to lastUpdated.
        model.pageSortOrder = .lastUpdated
        #expect(model.summaries.count == 2)
    }

    @Test func snapshotIgnoresSortPreference() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "A")
        // Use Task.sleep to avoid blocking the cooperative thread pool (#732).
        try await Task.sleep(for: .milliseconds(2))
        _ = try await store.createPage(title: "B")
        // Touch A so it becomes most-recently-edited under lastUpdated.
        try await store.updatePage(id: a.id, title: "A", body: "edited")
        await model.bootstrapFromStore()

        // User sorts by title A–Z in the sidebar.
        model.pageSortOrder = .titleAZ

        // Snapshot must still report titles most-recently-edited first.
        let snapshot = try await model.currentStateSnapshot()
        // A was edited last, so it should sort first in the snapshot
        // regardless of the sidebar's titleAZ preference.
        #expect(snapshot.pageTitles.first == "A")
    }
}
