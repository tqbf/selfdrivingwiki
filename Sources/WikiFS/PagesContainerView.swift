import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// The Pages section of the sidebar — a native header (title, New Page, sort
/// picker, search) above an AppKit `NSTableView` (`PagesListView`). Mirrors
/// `BookmarksContainerView`: SwiftUI chrome on top, AppKit list below for
/// instant selection + native double-click.
struct PagesContainerView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderSpike
    let manager: WikiManager
    let launcher: AgentLauncher
    let onNewPage: () -> Void

    @State private var renameTarget: WikiPageSummary?
    @State private var renameText = ""
    /// Non-nil while the bookmark-target picker is open for a page selection.
    @State private var addToBookmarksContext: BookmarkTargetPickerContext?

    private var visible: [WikiPageSummary] {
        store.searchQuery.isEmpty ? store.summaries : store.searchResults
    }

    var body: some View {
        VStack(spacing: 0) {
            pagesHeader
            Divider()
            ZStack(alignment: .topLeading) {
                PagesListView(store: store, fileProvider: fileProvider,
                              manager: manager, launcher: launcher,
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
        .sheet(item: $addToBookmarksContext) { ctx in
            BookmarkTargetPickerSheet(
                store: store,
                kind: ctx.kind,
                ids: ctx.ids,
                onConfirm: { parentID in
                    for id in ctx.ids {
                        store.addPageRef(parentID: parentID, pageID: id)
                    }
                }
            )
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
                    let pages = ids.compactMap { id -> (id: PageID, title: String)? in
                        guard let s = store.summaries.first(where: { $0.id == id }) else { return nil }
                        return (id: id, title: s.title)
                    }
                    await AgentOperationRunner.runLintPages(
                        pages: pages, launcher: launcher, store: store,
                        wikiID: manager.activeWikiID ?? "",
                        changeSignaler: fileProvider,
                        wikictlDirectory: HelpersLocation.wikictlDirectory)
                }
            },
            onRename: { summary in beginRename(summary) },
            onDelete: { ids in
                for id in ids { store.delete(id) }
            },
            onAddToBookmarks: { ids in
                addToBookmarksContext = BookmarkTargetPickerContext(kind: .pages, ids: ids)
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
}
