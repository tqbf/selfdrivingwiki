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
        #expect(model.activeTabID == nil)
        #expect(model.activeTab == nil)
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
        #expect(model.activeTabID == model.tabs[0].id)
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
        let tabID = model.tabs[0].id

        model.selection = .page(b.id)
        model.handleSelectionChange(to: .page(b.id))

        #expect(model.tabs.count == 1)  // Still one tab — content replaced
        #expect(model.tabs[0].id == tabID)  // Same tab, not a new one
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
        #expect(model.activeTabID == model.tabs[1].id)  // New tab is active
        #expect(model.selection == .page(b.id))
    }

    @Test func openTabForExistingPageReusesTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))  // active is B now
        #expect(model.tabs.count == 2)

        // Opening a page that's already open focuses its existing tab — no
        // duplicate (tab reuse, the operator's requested behavior).
        model.openTab(.page(a.id))
        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == tabA)
        #expect(model.selection == .page(a.id))
    }

    // MARK: - Singleton chat tab

    /// The headline AC: `.newChat` is a singleton key — opening it twice reuses
    /// the same tab rather than spawning a duplicate. (The old dual `.ask`/
    /// `.edit` chat-mode coexistence test is gone — there is now one chat
    @Test func newChatTabIsSingleton() throws {
        let (model, _) = try tempModel()
        model.openTab(.newChat)
        #expect(model.tabs.count == 1)
        #expect(model.tabs.contains { $0.selection == .newChat })
        // Opening again reuses the existing tab (no duplicate).
        model.openTab(.newChat)
        #expect(model.tabs.count == 1)
    }

    // MARK: - Singleton reuse

    @Test func singletonSelectionReusesExistingTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.newChat)
        #expect(model.tabs.count == 2)
        let askTabID = model.tabs[1].id

        // Opening ask again should focus the existing ask tab.
        model.openTab(.newChat)
        #expect(model.tabs.count == 2)  // No duplicate
        #expect(model.activeTabID == askTabID)  // Ask tab is active
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
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        // Both tabs open, B is active.

        model.selectTab(id: tabA)
        #expect(model.activeTabID == tabA)
        #expect(model.selection == .page(a.id))
    }

    @Test func selectTabFlushesOutgoingDraft() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        model.draftBody = "B content has been edited"
        model.bodyChanged()
        model.flushPendingSave()

        // Switch back to tab A. B's draft should have been persisted.
        model.selectTab(id: tabA)
        let bPage = try store.getPage(id: b.id)
        #expect(bPage.bodyMarkdown == "B content has been edited")
    }

    @Test func selectTabWithActiveIDIsNoOp() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.draftBody = "some text"
        let activeID = model.activeTabID!

        // Selecting the already-active tab should not flush/change anything.
        model.selectTab(id: activeID)
        #expect(model.activeTabID == activeID)
        #expect(model.draftBody == "some text")
    }

    @Test func selectTabWithUnknownIDIsNoOp() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let activeID = model.activeTabID!

        model.selectTab(id: UUID())  // never opened
        #expect(model.activeTabID == activeID)
        #expect(model.tabs.count == 1)
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
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        let tabB = model.tabs[1].id
        model.openTab(.page(c.id))
        let tabC = model.tabs[2].id
        #expect(model.tabs.count == 3)

        // Make B active, then close it. The tab now at B's position (C) activates.
        model.selectTab(id: tabB)
        model.closeTab(id: tabB)
        #expect(model.tabs.count == 2)
        #expect(model.tabs.map(\.id) == [tabA, tabC])
        #expect(model.activeTabID == tabC)
    }

    @Test func closeRightmostActiveTabActivatesLeftNeighbor() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        let tabB = model.tabs[1].id
        #expect(model.activeTabID == tabB)

        // Close the rightmost (active) tab.
        model.closeTab(id: tabB)
        #expect(model.tabs.count == 1)
        #expect(model.activeTabID == tabA)
        #expect(model.tabs[0].selection == .page(a.id))
    }

    @Test func closeActiveLeftmostTabActivatesNewLeftmost() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        let tabB = model.tabs[1].id
        model.openTab(.page(c.id))
        let tabC = model.tabs[2].id

        // Activate leftmost (index 0) and close it. The new leftmost (B) activates.
        model.selectTab(id: tabA)
        model.closeTab(id: tabA)
        #expect(model.tabs.map(\.id) == [tabB, tabC])
        #expect(model.activeTabID == tabB)
    }

    @Test func closeLastTabShowsEmptyState() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        #expect(model.tabs.count == 1)
        let tabA = model.tabs[0].id

        model.closeTab(id: tabA)
        #expect(model.tabs.isEmpty)
        #expect(model.activeTabID == nil)
        #expect(model.selection == nil)
    }

    @Test func closeNonActiveTabDoesNotChangeActive() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        model.openTab(.page(c.id))
        let tabC = model.tabs[2].id
        // Active is C.

        // Close A (not active, to the left of active).
        model.closeTab(id: tabA)
        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == tabC)  // Unchanged
        #expect(model.selection == .page(c.id))
    }

    // MARK: - closeOtherTabs

    @Test func closeOtherTabsKeepsOnlySpecifiedActiveTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        let tabB = model.tabs[1].id
        model.openTab(.page(c.id))
        // C active, three tabs.

        model.selectTab(id: tabB)
        model.closeOtherTabs(id: tabB)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == tabB)
        #expect(model.activeTabID == tabB)
        #expect(model.selection == .page(b.id))
        #expect(model.recentlyClosedTabs.count == 2)
    }

    @Test func closeOtherTabsActivatesKeptTabWhenNotActive() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        model.openTab(.page(c.id))
        // C is active; keep A (not active).

        model.closeOtherTabs(id: tabA)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id == tabA)
        #expect(model.activeTabID == tabA)  // kept tab becomes active
        #expect(model.selection == .page(a.id))
    }

    @Test func closeOtherTabsWithSingleTabIsNoOp() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id

        model.closeOtherTabs(id: tabA)
        #expect(model.tabs.count == 1)
        #expect(model.recentlyClosedTabs.isEmpty)
    }

    // MARK: - closeTabsAfter

    @Test func closeTabsAfterClosesRightSideAndActivatesAnchor() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        let tabB = model.tabs[1].id
        model.openTab(.page(c.id))
        // C active. Close tabs after A — B and C close, active (C) was closed.

        model.closeTabsAfter(id: tabA)
        #expect(model.tabs.map(\.id) == [tabA])
        #expect(model.activeTabID == tabA)  // anchor activated
        #expect(model.selection == .page(a.id))
        #expect(model.recentlyClosedTabs.count == 2)
        _ = tabB
    }

    @Test func closeTabsAfterLeavesActiveUnchangedWhenAnchorIsActive() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        model.openTab(.page(c.id))

        // Active is A (the anchor). Closing tabs after A keeps A active.
        model.selectTab(id: tabA)
        model.closeTabsAfter(id: tabA)
        #expect(model.tabs.map(\.id) == [tabA])
        #expect(model.activeTabID == tabA)
    }

    @Test func closeTabsAfterLeavesActiveUnchangedWhenActiveIsLeftOfAnchor() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        let tabB = model.tabs[1].id
        model.openTab(.page(c.id))

        // Active is A (left of anchor B). Close tabs after B (closes C only).
        model.selectTab(id: tabA)
        model.closeTabsAfter(id: tabB)
        #expect(model.tabs.map(\.id) == [tabA, tabB])
        #expect(model.activeTabID == tabA)  // unchanged, A still present
    }

    @Test func closeTabsAfterRightmostIsNoOp() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        let tabB = model.tabs[1].id

        model.closeTabsAfter(id: tabB)  // nothing to the right
        #expect(model.tabs.count == 2)
        #expect(model.recentlyClosedTabs.isEmpty)
    }

    // MARK: - closeAllTabs

    @Test func closeAllTabsClearsAllAndEntersEmptyState() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.page(b.id))
        #expect(model.tabs.count == 2)

        model.closeAllTabs()
        #expect(model.tabs.isEmpty)
        #expect(model.activeTabID == nil)
        #expect(model.selection == nil)
        #expect(model.recentlyClosedTabs.count == 2)
    }

    @Test func closeAllTabsWithNoTabsIsNoOp() throws {
        let (model, _) = try tempModel()
        model.closeAllTabs()
        #expect(model.tabs.isEmpty)
        #expect(model.recentlyClosedTabs.isEmpty)
    }

    // MARK: - Reopen closed tab

    @Test func reopenLastClosedTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.closeTab(id: tabA)
        #expect(model.tabs.isEmpty)

        model.reopenLastClosedTab()
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].selection == .page(a.id))
        #expect(model.activeTabID == model.tabs[0].id)
    }

    @Test func closeTabPreservesInRecentlyClosedStack() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        let tabA = model.tabs[0].id
        model.closeTab(id: tabA)

        #expect(model.recentlyClosedTabs.count == 1)
        #expect(model.recentlyClosedTabs[0].title == "A")
    }

    @Test func reopenWhenStackIsEmptyIsNoOp() throws {
        let (model, _) = try tempModel()
        #expect(model.recentlyClosedTabs.isEmpty)
        model.reopenLastClosedTab()
        #expect(model.tabs.isEmpty)
    }

    @Test func recentlyClosedStackCapsAtTen() throws {
        let (model, store) = try tempModel()
        // Open and close 12 distinct pages.
        var firstTitle: String?
        for i in 0..<12 {
            let title = "P\(i)"
            if firstTitle == nil { firstTitle = title }
            let page = try store.createPage(title: title)
            model.reloadFromStore()
            model.openTab(.page(page.id))
            model.closeTab(id: model.tabs[0].id)
        }
        #expect(model.recentlyClosedTabs.count == 10)
        // The two oldest entries (P0, P1) were evicted from the front.
        #expect(!model.recentlyClosedTabs.contains { $0.title == "P0" })
        #expect(!model.recentlyClosedTabs.contains { $0.title == "P1" })
        #expect(model.recentlyClosedTabs.last?.title == "P11")
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
        let tabA = model.tabs[0].id
        model.openTab(.page(b.id))
        // Active is B.

        model.delete(b.id)
        #expect(model.tabs.count == 1)
        #expect(model.activeTabID == tabA)
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
        let activeBefore = model.activeTabID

        // Delete C — not open in any tab.
        model.delete(c.id)
        #expect(model.tabs.count == 2)
        #expect(model.activeTabID == activeBefore)
    }

    // MARK: - Delete ingested file closes affected tab

    @Test func deleteSource_closesAffectedTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let f1 = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()

        model.selection = .page(a.id)
        model.handleSelectionChange(to: .page(a.id))
        model.openTab(.source(f1.id))
        #expect(model.tabs.count == 2)

        model.deleteSource(f1.id)
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
        model.openTab(.newChat)
        #expect(model.tabs.count == 3)

        model.rename(a.id, to: "Renamed A")
        #expect(model.tabs[0].title == "Renamed A")  // page A
        #expect(model.tabs[1].title == "B")          // page B unchanged
        #expect(model.tabs[2].title == "Chat")        // Chat tab unchanged
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
        #expect(model.activeTabID == model.tabs[0].id)

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
        #expect(model.tabTitle(for: .newChat) == "Chat")
        #expect(model.tabTitle(for: .systemPrompt) == "Instructions")
        #expect(model.tabTitle(for: .changeLog) == "Activity")
    }

    @Test func tabTitleForSourceFallsBackToFilenameWhenNoDisplayName() throws {
        let (model, store) = try tempModel()
        let f1 = try store.addSource(filename: "report.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()
        #expect(model.tabTitle(for: .source(f1.id)) == "report.pdf")
    }

    @Test func tabTitleForSourcePrefersDisplayNameOverFilename() throws {
        let (model, store) = try tempModel()
        let f1 = try store.addSource(filename: "report.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()
        model.renameSource(id: f1.id, to: "My Custom Title")
        #expect(model.tabTitle(for: .source(f1.id)) == "My Custom Title")
    }

    @Test func sourceTabTitleUpdatesOnRename() throws {
        let (model, store) = try tempModel()
        let f1 = try store.addSource(filename: "doc.pdf", data: Data("pdf".utf8))
        model.reloadFromStore()
        model.openTab(.source(f1.id))
        #expect(model.tabs[0].title == "doc.pdf")

        model.renameSource(id: f1.id, to: "Annual Report")
        #expect(model.tabs[0].title == "Annual Report")
    }

    // MARK: - tabIcon helper

    @Test func tabIconReturnsExpectedSymbols() throws {
        let (model, _) = try tempModel()
        #expect(model.tabIcon(for: .newChat) == "bubble.left.and.bubble.right")
        #expect(model.tabIcon(for: .systemPrompt) == "sparkles")
        #expect(model.tabIcon(for: .changeLog) == "clock.arrow.circlepath")
        #expect(model.tabIcon(for: .page(PageID(rawValue: "any"))) == "doc.text")
    }

    // MARK: - Batch open

    @Test func batchOpenCreatesAllTabs() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        // Simulate batch opening all three pages.
        for id in [a.id, b.id, c.id] { model.openTab(.page(id)) }

        #expect(model.tabs.count == 3)
        #expect(model.tabs.map(\.title) == ["A", "B", "C"])
        // The last-opened page is active.
        #expect(model.tabs.last?.selection == .page(c.id))
        #expect(model.activeTabID == model.tabs.last?.id)
    }

    @Test func batchOpenBackgroundCreatesAllTabsWithoutSwitching() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        let c = try store.createPage(title: "C")
        model.reloadFromStore()

        // Open A first (active), then batch-open B and C in background.
        model.openTab(.page(a.id))
        for id in [b.id, c.id] { model.openTabInBackground(.page(id)) }

        #expect(model.tabs.count == 3)
        // A stays active — background opens don't switch focus.
        #expect(model.activeTabID == model.tabs.first?.id)
        #expect(model.tabs.first?.selection == .page(a.id))
    }

    @Test func batchOpenSkipsDuplicateTabs() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        // Open A first, then batch-open including A again.
        model.openTab(.page(a.id))
        #expect(model.tabs.count == 1)

        // A second openTab for the same page refocuses, doesn't duplicate.
        model.openTab(.page(a.id))
        #expect(model.tabs.count == 1)
    }

    @Test func batchOpenBackgroundSkipsDuplicateTabs() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        model.reloadFromStore()

        model.openTabInBackground(.page(a.id))
        #expect(model.tabs.count == 1)

        // Batch background open of A (duplicate) and B (new).
        for id in [a.id, b.id] { model.openTabInBackground(.page(id)) }
        // A is a no-op (already open); B is added.
        #expect(model.tabs.count == 2)
        #expect(model.tabs.map(\.title).sorted() == ["A", "B"])
    }

    @Test func backgroundOpenOnEmptyBarFocusesTheNewTab() throws {
        let (model, store) = try tempModel()
        let a = try store.createPage(title: "A")
        model.reloadFromStore()

        // No tabs open yet — "Open in Background" has nothing to keep focused,
        // so it must fall back to opening AND activating the tab (issue #138).
        #expect(model.tabs.isEmpty)
        #expect(model.activeTabID == nil)

        model.openTabInBackground(.page(a.id))

        #expect(model.tabs.count == 1)
        #expect(model.tabs.first?.selection == .page(a.id))
        #expect(model.activeTabID == model.tabs.first?.id)
    }
}
