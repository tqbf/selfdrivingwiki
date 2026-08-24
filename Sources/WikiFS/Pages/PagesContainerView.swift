import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The Pages section of the sidebar — a native header (title, New Page, sort
/// picker, search) above an AppKit `NSTableView` (`PagesListView`). Mirrors
/// `BookmarksContainerView`: SwiftUI chrome on top, AppKit list below for
/// instant selection + native double-click.
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
    /// Non-nil while the incoming-reference delete confirmation is open. Set
    /// when the user deletes a page that other pages link to or bookmarks point
    /// at (issue #219).
    @State private var pendingDeletion: PendingPageDeletion?

    private var visible: [WikiPageSummary] {
        store.searchQuery.isEmpty ? store.summaries : store.searchResults
    }

    var body: some View {
        VStack(spacing: 0) {
            pagesHeader
            Divider()
            ZStack(alignment: .topLeading) {
                PagesListView(store: store, fileProvider: fileProvider,
                              session: session, launcher: launcher,
                              callbacks: callbacks)
                if visible.isEmpty && !store.searchQuery.isEmpty {
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
        .confirmationDialog(
            pendingDeletion.map { deletionDialogTitle(ids: $0.ids) } ?? "",
            isPresented: deletionDialogPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { pending in
            deletionDialogActions(for: pending)
        } message: { pending in
            Text(deletionDialogMessage(for: pending))
        }
    }

    /// Header: title + compact New Page button, then the sort picker and search
    /// bar (matching the prior pagesSection layout, with the bookmarks-style
    /// compact action button).
    private var pagesHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("Pages").font(.headline).foregroundStyle(.primary)
                Spacer()
                headerButton(systemImage: "plus", help: "New Page") {
                    onNewPage()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            HStack {
                Text("Sort by").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $store.pageSortOrder) {
                    Text("Last Updated").tag(PageSortOrder.lastUpdated)
                    Text("Newest First").tag(PageSortOrder.newestFirst)
                    Text("Title A–Z").tag(PageSortOrder.titleAZ)
                }
                .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            searchBar
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
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
                        _ = try await session.queueEngine.enqueue(QueueItemRequest(
                            queue: .ingestion,
                            wikiID: session.wikiID,
                            payload: QueueItemPayload(sourceIDs: [], lintPageIDs: ids)
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

    // MARK: - Delete with incoming-reference warning (issue #219)

    /// Aggregate the incoming links + bookmarks for the selected pages, then
    /// either delete immediately (nothing references them) or open the
    /// confirmation dialog so the user can see and choose how to handle them.
    private func requestPageDeletion(_ ids: [PageID]) {
        let deletedIDs = Set(ids)
        var linkingIDs: [PageID] = []
        var bookmarkFolders: Set<String> = []
        var bookmarkCount = 0
        for id in ids {
            let impact = store.deletionImpact(forPage: id)
            linkingIDs.append(contentsOf: impact.linkingPageIDs)
            bookmarkCount += impact.bookmarkLabels.count
            bookmarkFolders.formUnion(impact.bookmarkLabels)
        }
        // Drop pages that are themselves being deleted (they vanish with the
        // batch), then dedupe for display.
        let displayTitles = Array(Set(linkingIDs))
            .filter { !deletedIDs.contains($0) }
            .compactMap { id in store.summaries.first { $0.id == id }?.title }
            .sorted()

        if displayTitles.isEmpty && bookmarkCount == 0 {
            confirmPageDeletion(ids: ids, unlink: false)
        } else {
            pendingDeletion = PendingPageDeletion(
                ids: ids,
                linkingPageTitles: displayTitles,
                bookmarkCount: bookmarkCount,
                bookmarkFolders: bookmarkFolders.sorted())
        }
    }

    private func confirmPageDeletion(ids: [PageID], unlink: Bool) {
        for id in ids { store.delete(id, unlinkIncomingLinks: unlink) }
        // If a deleted page was the home page, clear the stale homePageID so the
        // Home button doesn't linger as dead UI.
        if let homeID = session.descriptor.homePageID, ids.contains(homeID) {
            registry.setHomePage(id: session.wikiID, pageID: nil)
            var d = session.descriptor
            d.homePageID = nil
            session.updateDescriptor(d)
        }
        pendingDeletion = nil
    }

    private var deletionDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func deletionDialogTitle(ids: [PageID]) -> String {
        ids.count == 1 ? "Delete Page?" : "Delete \(ids.count) Pages?"
    }

    private func deletionDialogMessage(for pending: PendingPageDeletion) -> String {
        var lines: [String] = []
        if !pending.linkingPageTitles.isEmpty {
            let names = pending.linkingPageTitles.joined(separator: ", ")
            let noun = pending.linkingPageTitles.count == 1 ? "page" : "pages"
            lines.append("Linked from \(pending.linkingPageTitles.count) \(noun): \(names).")
        }
        if pending.bookmarkCount > 0 {
            let noun = pending.bookmarkCount == 1 ? "bookmark" : "bookmarks"
            let where_ = pending.bookmarkFolders.joined(separator: ", ")
            lines.append("\(pending.bookmarkCount) \(noun) point to this and will be removed (\(where_)).")
        }
        if !pending.linkingPageTitles.isEmpty {
            lines.append("Unlink and Delete converts the links to plain text.")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func deletionDialogActions(for pending: PendingPageDeletion) -> some View {
        if !pending.linkingPageTitles.isEmpty {
            Button("Unlink and Delete", role: .destructive) {
                confirmPageDeletion(ids: pending.ids, unlink: true)
            }
            Button("Delete", role: .destructive) {
                confirmPageDeletion(ids: pending.ids, unlink: false)
            }
        } else {
            Button("Delete", role: .destructive) {
                confirmPageDeletion(ids: pending.ids, unlink: false)
            }
        }
        Button("Cancel", role: .cancel) { pendingDeletion = nil }
    }
}

/// State carried by the incoming-reference delete-confirmation dialog
/// (issue #219).
private struct PendingPageDeletion: Identifiable {
    let id = UUID()
    let ids: [PageID]
    let linkingPageTitles: [String]
    let bookmarkCount: Int
    let bookmarkFolders: [String]
}
