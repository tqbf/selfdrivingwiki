import Foundation
import Testing
@testable import WikiFSCore

@MainActor
struct EditorTabTests {

    private func tempModel() throws -> (WikiStoreModel, SQLiteWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try SQLiteWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    // MARK: - Initial state

    @Test func startsWithNoTabs() throws {
        let (model, _) = try tempModel()
        #expect(model.tabs.isEmpty)
        #expect(model.activeTabIndex == 0)
        #expect(model.recentlyClosedTabs.isEmpty)
    }

    // MARK: - Sidebar-driven selection creates tabs

    @Test func firstSidebarSelectionCreatesInitialTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        #expect(model.tabs.isEmpty)

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].selection == .page(a.id))
        #expect(model.tabs[0].title == "A")
        #expect(model.activeTabIndex == 0)
    }

    @Test func sidebarSingleClickReplacesActiveTabContent() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].title == "A")

        model.selection = .page(b.id)
        model.handleSelectionChange(to: .page(b.id))

        #expect(model.tabs.count == 1)  // Still one tab — content replaced
        #expect(model.tabs[0].selection == .page(b.id))
        #expect(model.tabs[0].title == "B")
    }

    // MARK: - openTab

    @Test func openTabAddsNewTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        // Seed the first tab via selection.
        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        #expect(model.tabs.count == 1)

        // Open B in a new tab (Obsidian-style).
        model.openTab(.page(b.id))

        #expect(model.tabs.count == 2)
        #expect(model.tabs[0].selection == .page(a.id))
        #expect(model.tabs[1].selection == .page(b.id))
        #expect(model.activeTabIndex == 1)  // New tab is active
        #expect(model.selection == .page(b.id))
    }

    @Test func openTabForExistingPageCreatesNewTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        #expect(model.tabs.count == 1)

        // Opening the same page again creates a new tab (Obsidian-style).
        model.openTab(.page(a.id))
        #expect(model.tabs.count == 2)
        #expect(model.tabs[0].selection == .page(a.id))
        #expect(model.tabs[1].selection == .page(a.id))
    }

    // MARK: - Singleton reuse

    @Test func singletonSelectionReusesExistingTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.query)
        #expect(model.tabs.count == 2)

        // Opening query again should switch to the existing query tab.
        model.openTab(.query)
        #expect(model.tabs.count == 2)  // No duplicate
        #expect(model.activeTabIndex == 1)  // Query tab is active
    }

    @Test func singletonSystemPromptReusesExistingTab() throws {
        let (model, _) = try tempModel()
        model.openTab(.systemPrompt)
        #expect(model.tabs.count == 1)
        model.openTab(.systemPrompt)
        #expect(model.tabs.count == 1)
    }

    @Test func singletonChangeLogReusesExistingTab() throws {
        let (model, _) = try tempModel()
        model.openTab(.changeLog)
        #expect(model.tabs.count == 1)
        model.openTab(.changeLog)
        #expect(model.tabs.count == 1)
    }

    // MARK: - selectTab

    @Test func selectTabSwitchesContent() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        // Both tabs open, B is active (index 1).

        model.selectTab(at: 0)
        #expect(model.activeTabIndex == 0)
        #expect(model.selection == .page(a.id))
    }

    @Test func selectTabFlushesOutgoingDraft() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        model.draftBody = "B content has been edited"
        model.bodyChanged()
        model.flushPendingSave()

        // Switch back to tab A. B's draft should have been persisted.
        model.selectTab(at: 0)
        let bPage = try store.getPage(id: b.id)
        #expect(bPage.bodyMarkdown == "B content has been edited")
    }

    @Test func selectTabWithSameIndexIsNoOp() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.draftBody = "some text"

        // Selecting the already-active tab should not flush/change anything.
        model.selectTab(at: 0)
        #expect(model.activeTabIndex == 0)
        #expect(model.draftBody == "some text")
    }

    // MARK: - closeTab

    @Test func closeTabActivatesRightNeighbor() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        model.openTab(.page(c.id))
        #expect(model.tabs.count == 3)
        #expect(model.activeTabIndex == 2)

        // Close tab 1 (B). Active is 2 > 1, stays at 1 (C shifts left).
        model.closeTab(at: 1)
        #expect(model.tabs.count == 2)
        #expect(model.tabs[1].selection == .page(c.id))
        #expect(model.activeTabIndex == 1)
    }

    @Test func closeTabRightmostActivatesLeftNeighbor() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        #expect(model.activeTabIndex == 1)

        // Close tab 1 (rightmost, active).
        model.closeTab(at: 1)
        #expect(model.tabs.count == 1)
        #expect(model.activeTabIndex == 0)
        #expect(model.tabs[0].selection == .page(a.id))
    }

    @Test func closeLastTabShowsEmptyState() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        #expect(model.tabs.count == 1)

        model.closeTab(at: 0)
        #expect(model.tabs.isEmpty)
        #expect(model.selection == nil)
    }

    @Test func closeNonActiveTabDoesNotChangeSelection() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        model.openTab(.page(c.id))
        // Active is tab 2 (C).

        // Close tab 0 (A, not active, to the left of active).
        model.closeTab(at: 0)
        #expect(model.tabs.count == 2)
        #expect(model.activeTabIndex == 1)  // Shifted from 2 → 1
        #expect(model.selection == .page(c.id))
    }

    // MARK: - Reopen closed tab

    @Test func reopenLastClosedTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.closeTab(at: 0)
        #expect(model.tabs.isEmpty)

        model.reopenLastClosedTab()
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].selection == .page(a.id))
        #expect(model.activeTabIndex == 0)
    }

    @Test func closeTabPreservesInRecentlyClosedStack() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.closeTab(at: 0)

        #expect(model.recentlyClosedTabs.count == 1)
        #expect(model.recentlyClosedTabs[0].title == "A")
    }

    @Test func reopenWhenStackIsEmptyIsNoOp() throws {
        let (model, _) = try tempModel()
        #expect(model.recentlyClosedTabs.isEmpty)
        model.reopenLastClosedTab()
        #expect(model.tabs.isEmpty)
    }

    // MARK: - Delete page closes affected tab

    @Test func deletePage_closesAffectedTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        #expect(model.tabs.count == 2)
        #expect(model.activeTabIndex == 1)  // B is active

        model.delete(a.id)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].selection == .page(b.id))
    }

    @Test func deleteActivePageActivatesNeighbor() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        // Active is tab 1 (B).

        model.delete(b.id)
        #expect(model.tabs.count == 1)
        #expect(model.activeTabIndex == 0)
        #expect(model.tabs[0].selection == .page(a.id))
    }

    @Test func deletePage_notInAnyTab_doesNotAffectTabs() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))

        // Delete C — not open in any tab.
        model.delete(c.id)
        #expect(model.tabs.count == 2)
    }

    // MARK: - Delete ingested file closes affected tab

    @Test func deleteIngestedFile_closesAffectedTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let f1 = try store.ingestFile(filename: "doc.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.ingestedFile(f1.id))
        #expect(model.tabs.count == 2)

        model.deleteIngestedFile(f1.id)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].selection == .page(a.id))
    }

    // MARK: - Rename updates tab titles

    @Test func renameUpdatesTabTitles() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        #expect(model.tabs[0].title == "A")

        model.rename(a.id, to: "Renamed A")
        #expect(model.tabs[0].title == "Renamed A")
    }

    @Test func renamePageOnlyAffectsMatchingTabs() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        model.openTab(.query)
        #expect(model.tabs.count == 3)

        model.rename(a.id, to: "Renamed A")
        // Tab 0 (page A) should be renamed.
        #expect(model.tabs[0].title == "Renamed A")
        // Tab 1 (page B) should be unchanged.
        #expect(model.tabs[1].title == "B")
        // Tab 2 (Query) should be unchanged.
        #expect(model.tabs[2].title == "Query")
    }

    // MARK: - newPageInNewTab

    @Test func newPageInNewTab_createsPageAndOpensTab() throws {
        let (model, store) = try tempModel()
        model.reloadFromStore()

        model.newPageInNewTab(title: "Fresh Page")
        #expect(model.tabs.count == 1)
        if case .page = model.tabs[0].selection {
            // OK
        } else {
            #expect(Bool(false), "Expected tab selection to be a page")
        }
        #expect(model.tabs[0].title == "Fresh Page")
        #expect(model.activeTabIndex == 0)

        let summaries = (try? store.listPages(sortBy: .lastUpdated)) ?? []
        #expect(summaries.contains(where: { $0.title == "Fresh Page" }))
    }

    // MARK: - History navigation preserves tab metadata

    @Test func historyBackUpdatesActiveTabMetadata() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.selection = .page(b.id)
        model.handleSelectionChange(to: .page(b.id))

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].title == "B")

        model.navigateBack()
        #expect(model.selection == .page(a.id))
        #expect(model.tabs[0].title == "A")
        #expect(model.tabs[0].selection == .page(a.id))
    }

    // MARK: - tabTitle helper

    @Test func tabTitleForPage() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "My Page")
        model.reloadFromStore()
        #expect(model.tabTitle(for: .page(a.id)) == "My Page")
    }

    @Test func tabTitleForMissingPageReturnsUntitled() throws {
        let (model, _) = try tempModel()
        #expect(model.tabTitle(for: .page(PageID(rawValue: "nonexistent"))) == "Untitled")
    }

    @Test func tabTitleForSpecialSelections() throws {
        let (model, _) = try tempModel()
        #expect(model.tabTitle(for: .query) == "Query")
        #expect(model.tabTitle(for: .systemPrompt) == "Instructions")
        #expect(model.tabTitle(for: .changeLog) == "Activity")
    }

    @Test func tabTitleForIngestedFile() throws {
        let (model, store) = try tempModel()
        let f1 = try store.ingestFile(filename: "report.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()
        #expect(model.tabTitle(for: .ingestedFile(f1.id)) == "report.pdf")
    }

    // MARK: - tabIcon helper

    @Test func tabIconReturnsExpectedSymbols() throws {
        let (model, _) = try tempModel()
        #expect(model.tabIcon(for: .query) == "bubble.left.and.text.bubble.right")
        #expect(model.tabIcon(for: .systemPrompt) == "sparkles")
        #expect(model.tabIcon(for: .changeLog) == "clock.arrow.circlepath")
        #expect(model.tabIcon(for: .page(PageID(rawValue: "any"))) == "doc.text")
    }
}
