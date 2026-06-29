import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the in-app preview navigation seam on `WikiStoreModel`:
/// `pageExists(title:)` (drives resolved-vs-unresolved styling) and
/// `selectPage(byTitle:)` (drives the click→select navigation, through the same
/// `select(_:)` path the sidebar uses).
@MainActor
struct WikiLinkNavigationTests {

    private func tempModel() throws -> (WikiStoreModel, SQLiteWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-nav-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    @Test func pageExistsReflectsStore() throws {
        let (model, store) = try tempModel()
        _ = try store.createPage(title: "Photosynthesis")
        model.reloadFromStore()
        #expect(model.pageExists(title: "Photosynthesis"))
        #expect(!model.pageExists(title: "Nonexistent"))
    }

    @Test func selectPageByTitleNavigatesToThatPage() throws {
        let (model, store) = try tempModel()
        let target = try store.createPage(title: "Chloroplast")
        model.reloadFromStore()

        let navigated = model.selectPage(byTitle: "Chloroplast")
        #expect(navigated)
        #expect(model.selection == .page(target.id))
    }

    @Test func selectPageByTitleNoOpsOnMissingTitle() throws {
        let (model, _) = try tempModel()
        let navigated = model.selectPage(byTitle: "Ghost")
        #expect(!navigated)
        #expect(model.selection == nil)
    }

    @Test func selectPageByTitleResolvesDuplicateToLowestULID() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "Dup")
        let b = try store.createPage(title: "Dup")
        // ULID generation isn't guaranteed monotonic within a tick, so derive the
        // expected winner from the ids themselves rather than creation order.
        let lowest = a.id.rawValue < b.id.rawValue ? a.id : b.id
        model.reloadFromStore()

        #expect(model.selectPage(byTitle: "Dup"))
        // Lowest-ULID page wins, matching the link graph's resolveTitleToID.
        #expect(model.selection == .page(lowest))
    }

    @Test func selectPageByTitleReusesAlreadyOpenTab() throws {
        let (model, store) = try tempModel()
        let from = try store.createPage(title: "From")
        let to = try store.createPage(title: "To")
        model.reloadFromStore()

        // Open both pages in tabs, leaving `from` active.
        model.openTab(.page(to.id))
        let toTab = model.tabs.first { $0.selection == .page(to.id) }!.id
        model.openTab(.page(from.id))
        #expect(model.tabs.count == 2)

        // Clicking a [[To]] link focuses the existing tab — no third tab.
        #expect(model.selectPage(byTitle: "To"))
        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == toTab)
        #expect(model.selection == .page(to.id))
    }

    @Test func selectPageByTitleOpensNewTabWhenNotAlreadyOpen() throws {
        let (model, store) = try tempModel()
        let from = try store.createPage(title: "From")
        let to = try store.createPage(title: "To")
        model.reloadFromStore()

        model.openTab(.page(from.id))
        #expect(model.tabs.count == 1)

        #expect(model.selectPage(byTitle: "To"))
        #expect(model.tabs.count == 2)
        #expect(model.selection == .page(to.id))
    }

    @Test func selectPageByTitleDoesNotAutoSavePendingEditsToOutgoingPage() throws {
        let (model, store) = try tempModel()
        let from = try store.createPage(title: "From")
        let to = try store.createPage(title: "To")
        model.reloadFromStore()

        // Open `from`, type into the body, then navigate to `to`. Edits are
        // only committed by an explicit save (flushPendingSave); navigating
        // away must NOT auto-save to the database.
        model.select(.page(from.id))
        model.draftBody = "edited body before clicking a link"
        model.bodyChanged()

        #expect(model.selectPage(byTitle: "To"))
        #expect(model.selection == .page(to.id))

        let reloaded = try store.getPage(id: from.id)
        #expect(reloaded.bodyMarkdown == "")  // not auto-saved
    }

    // MARK: - selectSource(byDisplayName:) (Phase B)

    @Test func selectSourceByDisplayNameNavigatesToThatSource() throws {
        let (model, store) = try tempModel()
        let source = try store.addSource(filename: "Paper.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()

        let navigated = model.selectSource(byDisplayName: "Paper.pdf")
        #expect(navigated)
        #expect(model.selection == .source(source.id))
        #expect(model.tabs.contains { $0.selection == .source(source.id) })
    }

    @Test func selectSourceByDisplayNameNoOpsOnMissingName() throws {
        let (model, _) = try tempModel()
        let navigated = model.selectSource(byDisplayName: "Ghost.pdf")
        #expect(!navigated)
    }

    @Test func selectSourceByDisplayNameReusesAlreadyOpenTab() throws {
        let (model, store) = try tempModel()
        let source = try store.addSource(filename: "notes.md", data: Data("md".utf8))
        model.reloadFromStore()

        model.openTab(.source(source.id))
        #expect(model.tabs.count == 1)

        #expect(model.selectSource(byDisplayName: "notes.md"))
        #expect(model.tabs.count == 1) // reused, not duplicated
        #expect(model.selection == .source(source.id))
    }
}
