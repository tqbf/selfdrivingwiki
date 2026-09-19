import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The Pages section of the sidebar — a native header (title, New Page,
/// filter and sort menu icons, search) above an AppKit `NSTableView`
/// (`PagesListView`). Mirrors `BookmarksContainerView` / `SourcesContainerView`:
/// SwiftUI chrome on top, AppKit list below for instant selection + native
/// double-click.
struct PagesContainerView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderFacade
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: any WikiSessionProtocol
    /// App-scoped registry — used for `setHomePage` persistence.
    var registry: WikiRegistryClient
    let launcher: AgentLauncher
    let onNewPage: () -> Void

    @State private var renameTarget: WikiPageSummary?
    @State private var renameText = ""
    /// Non-nil while the bookmark-target picker is open for a page selection.
    @State private var addToBookmarksContext: BookmarkTargetPickerContext?
    /// Non-nil while a delete-confirmation surface is on screen (issue #219
    /// hardening): the typed outcome produced by the shared
    /// `DeletionConfirmationCoordinator`.
    @State private var deletionOutcome: DeletionConfirmationOutcome?
    /// The page ids behind `deletionOutcome` — what the action handler deletes.
    @State private var pendingDeletionIDs: [PageID] = []
    /// "Show" date-window filter backing the filter menu. `all` is the
    /// default and returns the list unchanged.
    @State private var dateFilter: PageDateFilter = .all

    /// "Show" date-window filter for the page list (follow-up to #241's
    /// header treatment; display-only). `WikiPageSummary` carries only
    /// title + dates, so the filter windows compare `updatedAt` against a
    /// reference date at calendar granularity — `now` and `calendar` are
    /// injectable so the predicate is unit-testable without real time.
    enum PageDateFilter: String, CaseIterable {
        case all
        case today
        case week
        case month

        func matches(
            _ date: Date,
            now: Date = Date(),
            calendar: Calendar = .current
        ) -> Bool {
            switch self {
            case .all: return true
            case .today: return calendar.isDate(date, equalTo: now, toGranularity: .day)
            case .week: return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .month: return calendar.isDate(date, equalTo: now, toGranularity: .month)
            }
        }

        /// Pure: pages whose `updatedAt` falls inside the window. `all`
        /// returns the input unchanged.
        func filtered(
            _ pages: [WikiPageSummary],
            now: Date = Date(),
            calendar: Calendar = .current
        ) -> [WikiPageSummary] {
            guard self != .all else { return pages }
            return pages.filter { matches($0.updatedAt, now: now, calendar: calendar) }
        }
    }

    private var visible: [WikiPageSummary] {
        // During search, results are relevance-ranked by the engine — the
        // date filter does not apply (the same rule the sort follows).
        if store.searchQuery.isEmpty {
            return dateFilter.filtered(store.summaries)
        }
        return store.searchResults
    }

    var body: some View {
        VStack(spacing: 0) {
            pagesHeader
            Divider()
            ZStack(alignment: .topLeading) {
                PagesListView(store: store, pages: visible, fileProvider: fileProvider,
                              session: session, launcher: launcher,
                              callbacks: callbacks)
                if visible.isEmpty && (!store.searchQuery.isEmpty || dateFilter != .all) {
                    Text("No matching pages")
                        .foregroundStyle(.secondary).font(.callout)
                        .padding(.vertical, 8).padding(.horizontal, 4)
                }
            }
        }
        .alert("Rename Page", isPresented: renamePresented) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
        }
        .alert(
            "Title Already Exists",
            isPresented: Binding(
                get: { store.renameConflictingTitle != nil },
                set: { if !$0 { store.clearRenameConflict() } }
            )
        ) {
            Button("OK", role: .cancel) { store.clearRenameConflict() }
        } message: {
            if let title = store.renameConflictingTitle {
                Text("A page with the title “\(title)” already exists. Please choose a different name.")
            }
        }
        .sheet(item: $addToBookmarksContext) { ctx in
            BookmarkTargetPickerSheet(
                store: store,
                targets: ctx.targets,
                onConfirm: { parentID in
                    guard case .pages(let ids) = ctx.targets else { return }
                    for id in ids {
                        store.addPageRef(parentID: parentID, pageID: id)
                    }
                }
            )
        }
        .deletionOutcomeDialog($deletionOutcome) { action in
            handleDeletionAction(action)
        }
    }

    /// Header: title + compact New Page button and the filter/sort menu
    /// icons, then the search bar. The filter is a date-window "Show" menu
    /// (display-only); the sort drives `store.pageSortOrder` (model-level,
    /// re-queries the store).
    private var pagesHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("Pages").font(.headline).foregroundStyle(.primary)
                Spacer()
                headerButton(systemImage: "plus", help: "New Page") {
                    onNewPage()
                }
                .keyboardShortcut("n", modifiers: .command)
                filterMenu
                sortMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            searchBar
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
    }

    /// The "Show" date-window filter — a filter icon whose dropdown lists
    /// All / Edited Today / This Week / This Month, the same
    /// `Menu { Picker … }` pattern as the sibling sections' icons. The icon
    /// tints accent while a non-All window is active.
    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $dateFilter) {
                Text("All").tag(PageDateFilter.all)
                Text("Edited Today").tag(PageDateFilter.today)
                Text("This Week").tag(PageDateFilter.week)
                Text("This Month").tag(PageDateFilter.month)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(dateFilter == .all ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show")
    }

    /// The "Sort by" control — a sort icon whose dropdown drives
    /// `store.pageSortOrder` (the model re-queries the store; same choices
    /// as the former caption row). The icon tints accent while a non-default
    /// (non-Last Updated) sort is active.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $store.pageSortOrder) {
                Text("Last Updated").tag(PageSortOrder.lastUpdated)
                Text("Newest First").tag(PageSortOrder.newestFirst)
                Text("Title A–Z").tag(PageSortOrder.titleAZ)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(store.pageSortOrder == .lastUpdated ? Color.secondary : Color.accentColor)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort by")
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary).font(.callout)
            TextField("Search pages…", text: $store.searchQuery)
                .textFieldStyle(.plain).font(.callout).disableAutocorrection(true)
            if !store.searchQuery.isEmpty {
                Button { store.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
        }
    }

    private func headerButton(systemImage: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var callbacks: PagesListCallbacks {
        PagesListCallbacks(
            onOpen: { ids in
                for id in ids { store.openTab(.page(id)) }
            },
            onOpenExternal: { ids, appURL in
                for id in ids { Task { await fileProvider.openPage(id: id, with: appURL) } }
            },
            onOpenBackground: { ids in
                for id in ids { store.openTabInBackground(.page(id)) }
            },
            onShare: { ids in
                Task {
                    let urls: [URL] = await withTaskGroup(of: URL?.self) { group in
                        for id in ids {
                            group.addTask { await fileProvider.resolvePageByTitleURL(id: id) }
                        }
                        var results: [URL] = []
                        for await url in group { if let url { results.append(url) } }
                        return results
                    }
                    SidebarSharing.present(items: urls)
                }
            },
            onReveal: { id in
                Task { await fileProvider.revealPageInFinder(id: id) }
            },
            onLint: { ids in
                Task {
                    do {
                        // Closed-wiki name resolution: record the page
                        // titles already in hand (the wiki is open here) so
                        // the Activity window keeps readable input rows
                        // after this wiki's window closes.
                        let titles = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                            store.summaries.first { $0.id == id }.map { (id.rawValue, $0.title) }
                        })
                        let payload = QueueItemPayload(
                            sourceIDs: [],
                            lintPageIDs: ids,
                            recordedNames: titles.isEmpty ? nil : titles)
                        _ = try await session.queueEngine.enqueue(QueueItemRequest(
                            queue: .ingestion,
                            wikiID: session.wikiID,
                            payload: payload
                        ))
                    } catch {
                        DebugLog.store("PagesContainerView.onLint enqueue failed: \(error)")
                    }
                }
            },
            onRename: { summary in beginRename(summary) },
            onDelete: { ids in
                requestPageDeletion(ids)
            },
            onSetHomePage: { pageID in
                registry.setHomePage(id: session.wikiID, pageID: pageID)
                // Optimistically update the session's in-memory descriptor so
                // the menu toggles immediately (the registry write + wikis
                // reload won't propagate to the session until the app layer
                // bridges it — do it eagerly here). WikiDescriptor is a
                // struct, so we copy-mutate through a local.
                var d = session.descriptor
                d.homePageID = pageID
                session.updateDescriptor(d)
            },
            onAddToBookmarks: { ids in
                addToBookmarksContext = BookmarkTargetPickerContext(targets: .pages(ids))
            })
    }

    private func beginRename(_ summary: WikiPageSummary) {
        renameText = summary.title
        renameTarget = summary
    }

    private func commitRename() {
        if let target = renameTarget { store.rename(target.id, to: renameText) }
        renameTarget = nil
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    // MARK: - Delete with incoming-reference warning (issue #219 hardening)

    /// Aggregate the incoming links + bookmarks for the selected pages via the
    /// shared coordinator, then either delete immediately (nothing references
    /// them) or route to the typed confirmation state.
    private func requestPageDeletion(_ ids: [PageID]) {
        pendingDeletionIDs = ids
        let coordinator = DeletionConfirmationCoordinator(
            kind: .page,
            loadImpacts: {
                try ids.map { try store.deletionImpact(forPage: $0) }
            },
            onDelete: { decision in
                performPageDeletion(ids: ids, decision: decision)
            },
            pageTitle: { id in
                store.summaries.first { $0.id == id }?.title
            },
            selectionCount: ids.count)
        let outcome = coordinator.evaluate()
        if case .deleteImmediately = outcome {
            // No references, no blockers — delete without a dialog.
            coordinator.perform(.delete)
        } else {
            deletionOutcome = outcome
        }
    }

    private func performPageDeletion(ids: [PageID], decision: DeletionDecision) {
        // ONE protected transaction for the whole selection; on failure the
        // model surfaces the store error and returns nil (nothing changed).
        guard let result = store.performPageDeletion(
            ids, unlinkIncomingLinks: decision == .unlink) else { return }
        // If a deleted page was the home page, clear the stale homePageID so
        // the Home button doesn't linger as dead UI. Runs only for pages the
        // store reports as actually deleted.
        let deletedIDs = result.deletedTargets.compactMap(\.pageID)
        if let homeID = session.descriptor.homePageID, deletedIDs.contains(homeID) {
            registry.setHomePage(id: session.wikiID, pageID: nil)
            var d = session.descriptor
            d.homePageID = nil
            session.updateDescriptor(d)
        }
    }

    private func handleDeletionAction(_ action: DeletionDialogAction) {
        let ids = pendingDeletionIDs
        switch action {
        case .unlinkAndDelete: performPageDeletion(ids: ids, decision: .unlink)
        case .delete: performPageDeletion(ids: ids, decision: .preserve)
        case .cancel: break
        }
        pendingDeletionIDs = []
    }
}
