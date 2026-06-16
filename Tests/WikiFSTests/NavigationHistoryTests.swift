import Foundation
import Testing
@testable import WikiFSCore

@MainActor
struct NavigationHistoryTests {

    private func tempModel() throws -> (WikiStoreModel, SQLiteWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    @Test func programmaticSelectionBuildsBackAndForwardHistory() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.select(.page(a.id))
        model.select(.page(b.id))
        model.select(.page(c.id))

        #expect(model.selection == .page(c.id))
        #expect(model.canNavigateBack)
        #expect(!model.canNavigateForward)

        model.navigateBack()
        #expect(model.selection == .page(b.id))
        #expect(model.canNavigateForward)

        model.navigateBack()
        #expect(model.selection == .page(a.id))
        #expect(!model.canNavigateBack)

        model.navigateForward()
        #expect(model.selection == .page(b.id))
    }

    @Test func listSelectionBuildsHistoryThroughChangeHandler() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.selection = .page(b.id)
        model.handleSelectionChange(to: .page(b.id))

        #expect(model.selection == .page(b.id))
        model.navigateBack()
        #expect(model.selection == .page(a.id))
    }

    @Test func wikiLinkSelectionParticipatesInHistory() throws {
        let (model, store) = try tempModel()
        let from = try store.createPage(title: "From")
        let to = try store.createPage(title: "To")
        model.reloadFromStore()

        model.select(.page(from.id))
        #expect(model.selectPage(byTitle: "To"))

        #expect(model.selection == .page(to.id))
        model.navigateBack()
        #expect(model.selection == .page(from.id))
    }

    @Test func historyNavigationFlushesOutgoingDraft() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.select(.page(a.id))
        model.select(.page(b.id))
        model.draftBody = "edited before back"
        model.bodyChanged()

        model.navigateBack()
        #expect(model.selection == .page(a.id))
        #expect(try store.getPage(id: b.id).bodyMarkdown == "edited before back")
    }

    @Test func newSelectionClearsForwardHistory() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.select(.page(a.id))
        model.select(.page(b.id))
        model.navigateBack()
        #expect(model.canNavigateForward)

        model.select(.page(c.id))
        #expect(!model.canNavigateForward)
    }

    @Test func deletingSelectionRemovesItFromHistory() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.select(.page(a.id))
        model.select(.page(b.id))
        model.delete(a.id)

        #expect(!model.canNavigateBack)
    }

    @Test func reloadPrunesExternallyDeletedHistoryItems() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.select(.page(a.id))
        model.select(.page(b.id))
        try store.deletePage(id: a.id)

        model.reloadFromStore()

        #expect(!model.canNavigateBack)
    }
}
