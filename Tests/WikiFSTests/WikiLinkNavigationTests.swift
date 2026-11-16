import Foundation
import Testing
@testable import WikiFSCore

/// Tests for the in-app preview navigation seam on `WikiStoreModel`:
/// `pageExists(title:)` (drives resolved-vs-unresolved styling) and
/// `selectPage(byTitle:)` (drives the click→select navigation, through the same
/// `select(_:)` path the sidebar uses).
@MainActor
struct WikiLinkNavigationTests {

    private func tempModel() throws -> (WikiStoreModel, GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-nav-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    @Test func pageExistsReflectsStore() async throws {
        let (model, store) = try tempModel()
        _ = try await store.createPage(title: "Photosynthesis")
        await model.bootstrapFromStore()
        #expect(model.pageExists(title: "Photosynthesis"))
        #expect(!model.pageExists(title: "Nonexistent"))
    }

    @Test func selectPageByTitleNavigatesToThatPage() async throws {
        let (model, store) = try tempModel()
        let target = try await store.createPage(title: "Chloroplast")
        await model.bootstrapFromStore()

        let navigated = model.selectPage(byTitle: "Chloroplast")
        #expect(navigated)
        #expect(model.selection == .page(target.id))
    }

    @Test func selectPageByTitleNoOpsOnMissingTitle() async throws {
        let (model, _) = try tempModel()
        let navigated = model.selectPage(byTitle: "Ghost")
        #expect(!navigated)
        #expect(model.selection == nil)
    }

    @Test func selectPageByTitleResolvesDuplicateToLowestULID() async throws {
        let (model, store) = try tempModel()
        let a = try await store.createPage(title: "Dup")
        let b = try await store.createPage(title: "Dup")
        // ULID generation isn't guaranteed monotonic within a tick, so derive the
        // expected winner from the ids themselves rather than creation order.
        let lowest = a.id.rawValue < b.id.rawValue ? a.id : b.id
        await model.bootstrapFromStore()

        #expect(model.selectPage(byTitle: "Dup"))
        // Lowest-ULID page wins, matching the link graph's resolveTitleToID.
        #expect(model.selection == .page(lowest))
    }

    @Test func selectPageByTitleReusesAlreadyOpenTab() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        // Open both pages in tabs, leaving `from` active.
        model.openTab(.page(to.id))
        let toTab = model.tabs.first { $0.selection == .page(to.id) }!.id
        model.openTab(.page(from.id))
        #expect(model.tabs.count == 2)

        // A plain-click [[To]] link focuses the already-open tab — no third tab.
        #expect(model.selectPage(byTitle: "To"))
        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == toTab)
        #expect(model.selection == .page(to.id))
    }

    @Test func selectPageByTitlePlainClickNavigatesCurrentTabInPlace() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        model.openTab(.page(from.id))
        let fromTab = model.activeTabID
        #expect(model.tabs.count == 1)

        // Plain click (openInNewTab: false) navigates the active tab in place —
        // the existing tab's selection is replaced, no second tab is created.
        #expect(model.selectPage(byTitle: "To"))
        #expect(model.tabs.count == 1)
        #expect(model.activeTabID == fromTab)
        #expect(model.selection == .page(to.id))
        #expect(model.tabs.first?.selection == .page(to.id))
    }

    @Test func selectPageByTitleCommandClickOpensNewTab() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        model.openTab(.page(from.id))
        #expect(model.tabs.count == 1)

        // ⌘-click (openInNewTab: true) opens the target in a new tab.
        #expect(model.selectPage(byTitle: "To", openInNewTab: true))
        #expect(model.tabs.count == 2)
        #expect(model.selection == .page(to.id))
        #expect(model.tabs.contains { $0.selection == .page(to.id) })
    }

    @Test func selectPageByTitleCommandClickReusesAlreadyOpenTab() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        model.openTab(.page(to.id))
        let toTab = model.tabs.first { $0.selection == .page(to.id) }!.id
        model.openTab(.page(from.id))
        #expect(model.tabs.count == 2)

        // ⌘-clicking an already-open target focuses its tab rather than
        // duplicating (openTab dedup).
        #expect(model.selectPage(byTitle: "To", openInNewTab: true))
        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == toTab)
    }

    @Test func selectPageByTitlePlainClickInEmptyStateOpensTab() async throws {
        let (model, store) = try tempModel()
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        #expect(model.tabs.isEmpty)

        // No active tab → plain click falls back to opening a tab.
        #expect(model.selectPage(byTitle: "To"))
        #expect(model.tabs.count == 1)
        #expect(model.selection == .page(to.id))
    }

    @Test func selectPageByTitleNavigatesInPlaceRecordingHistory() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        model.openTab(.page(from.id))
        await model.quiesceSelectionTransitions()

        // Plain-click in-place navigation records a history transition so the
        // back button can return to the outgoing page.
        #expect(model.selectPage(byTitle: "To"))
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(to.id))
        model.navigateBack()
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(from.id))
    }

    @Test func selectPageByTitleFlushesOutgoingEditsOnInPlaceNavigation() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let to = try await store.createPage(title: "To")
        await model.bootstrapFromStore()

        // In-place navigation replaces the active tab's selection, so the
        // outgoing page's pending edits are flushed (auto-saved) rather than
        // silently discarded — the reader is read-only in practice, but this
        // keeps the edit path safe and matches sidebar `select(_:)`.
        model.openTab(.page(from.id))
        await model.quiesceSelectionTransitions()
        model.draftBody = "edited body before clicking a link"
        model.bodyChanged()

        #expect(model.selectPage(byTitle: "To"))
        await model.quiesceSelectionTransitions()
        #expect(model.selection == .page(to.id))

        let reloaded = try store.getPage(id: from.id)
        #expect(reloaded.bodyMarkdown == "edited body before clicking a link")
    }

    // MARK: - selectSource(byDisplayName:) (Phase B)

    @Test func selectSourceByDisplayNameNavigatesToThatSource() async throws {
        let (model, store) = try tempModel()
        let source = try store.addSource(filename: "Paper.pdf", data: Data("pdf".utf8))
        await model.bootstrapFromStore()

        let navigated = await model.selectSource(byDisplayName: "Paper.pdf")
        #expect(navigated)
        #expect(model.selection == .source(source.id))
        #expect(model.tabs.contains { $0.selection == .source(source.id) })
    }

    @Test func selectSourceByDisplayNameNoOpsOnMissingName() async throws {
        let (model, _) = try tempModel()
        let navigated = await model.selectSource(byDisplayName: "Ghost.pdf")
        #expect(!navigated)
    }

    @Test func selectSourceByDisplayNameReusesAlreadyOpenTab() async throws {
        let (model, store) = try tempModel()
        let source = try store.addSource(filename: "notes.md", data: Data("md".utf8))
        await model.bootstrapFromStore()

        model.openTab(.source(source.id))
        #expect(model.tabs.count == 1)

        #expect(await model.selectSource(byDisplayName: "notes.md"))
        #expect(model.tabs.count == 1) // reused, not duplicated
        #expect(model.selection == .source(source.id))
    }

    @Test func selectSourceByDisplayNamePlainClickNavigatesInPlace() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let source = try store.addSource(filename: "notes.md", data: Data("md".utf8))
        await model.bootstrapFromStore()

        model.openTab(.page(from.id))
        let fromTab = model.activeTabID
        #expect(model.tabs.count == 1)

        // Plain click on an [[source:…]] link navigates the active tab in place.
        #expect(await model.selectSource(byDisplayName: "notes.md"))
        #expect(model.tabs.count == 1)
        #expect(model.activeTabID == fromTab)
        #expect(model.selection == .source(source.id))
    }

    @Test func selectSourceByDisplayNameCommandClickOpensNewTab() async throws {
        let (model, store) = try tempModel()
        let from = try await store.createPage(title: "From")
        let source = try store.addSource(filename: "notes.md", data: Data("md".utf8))
        await model.bootstrapFromStore()

        model.openTab(.page(from.id))
        #expect(model.tabs.count == 1)

        // ⌘-click on an [[source:…]] link opens the source in a new tab.
        #expect(await model.selectSource(byDisplayName: "notes.md", openInNewTab: true))
        #expect(model.tabs.count == 2)
        #expect(model.selection == .source(source.id))
    }
}
