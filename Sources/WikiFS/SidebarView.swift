import SwiftUI
import WikiFSCore

/// Page list. `List(selection:)` bound straight to the model's selection; rows
/// are `WikiPageSummary` (Identifiable, so no explicit `id:`). Both a
/// `.contextMenu` and `.swipeActions` expose Rename/Delete (§4.1 / §7.4), and
/// the modern inset + hidden-background list look matches Notes/Mail (§4.2).
struct SidebarView: View {
    @Bindable var store: WikiStoreModel
    /// The multi-wiki manager — backs the switcher header at the top of the list.
    @Bindable var manager: WikiManager
    /// Used to open an ingested file in its default app via its user-visible URL.
    let fileProvider: FileProviderSpike
    /// Required to launch the LLM lint from the sidebar context menu.
    @Bindable var launcher: AgentLauncher
    /// Files whose agent run is in flight (agent phase) — shows the
    /// "Ingesting…" spinner on those rows.
    var ingestingSourceIDs: Set<PageID> = []
    /// Files whose pdf2md conversion is in flight (extraction phase) — shows the
    /// "Extracting…" spinner on those rows. Independent of `ingestingSourceIDs`.
    var extractingSourceIDs: Set<PageID> = []

    @Binding var showingAddFromZotero: Bool
    @Binding var showingImportMarkdown: Bool
    var onAddFromURL: () -> Void
    var onNewPage: () -> Void
    var isZoteroConfigured: Bool = false

    @State private var renameTarget: WikiPageSummary?
    @State private var renameText: String = ""
    @State private var bookmarkPickerContext: PickerContext?
    @State private var editBookmarkNodeID: EditBookmarkContext?
    @State private var showingNewBookmarkFolder = false
    @State private var newBookmarkFolderName = ""

    /// Which section is currently shown. Like Xcode's navigator, the icon bar at
    /// the top of the sidebar is a mutually-exclusive selector — exactly one
    /// section's "window" is visible at a time. Pure UI state — not persisted.
    @State private var selectedSection: SidebarSection = .pages

    /// The sidebar's sections. Each gets an icon in the selector bar and, when
    /// selected, fills the list below.
    enum SidebarSection: String, CaseIterable, Identifiable {
        case pages, sources, bookmarks, agent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pages: "Pages"
            case .sources: "Sources"
            case .bookmarks: "Bookmarks"
            case .agent: "Agent"
            }
        }

        var systemImage: String {
            switch self {
            case .pages: "doc.text"
            case .sources: "tray.full"
            case .bookmarks: "bookmark"
            case .agent: "sparkles"
            }
        }
    }

    // MARK: - Multi-select

    /// Native multi-select binding for the List — supports Shift+Arrow,
    /// Shift+Click, and Command+Click. Synced to `store.selection` for
    /// single-item navigation.
    @State private var listSelection: Set<WikiSelection> = []

    /// Tracks which section was last clicked, so Cmd+A selects only that section.
    @State private var activeSection: ActiveSection = .pages

    enum ActiveSection { case pages, sources }

    var body: some View {
        VStack(spacing: 0) {
            // The wiki switcher moved into the window toolbar (Safari-style,
            // trailing the omnibox); the sidebar now starts at the section
            // selector.
            sectionSelectorBar
                .padding(.top, 8)
            Divider()
            bookmarksOrList
        }
        .navigationTitle(activeWikiName)
        .onChange(of: listSelection) { _, newValue in selectionDidChange(newValue) }
        .onChange(of: store.selection) { _, newValue in
            if let sel = newValue, !listSelection.contains(sel) { listSelection = [sel] }
        }
        .navigationSplitViewColumnWidth(min: PageEditorMetrics.sidebarMinWidth,
                                         ideal: PageEditorMetrics.sidebarIdealWidth)
        .alert("Rename Page", isPresented: renamePresented) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") { commitRename() }
        }
        .modifier(BookmarkPickerSheetModifier(
            context: $bookmarkPickerContext,
            store: store))
        .sheet(item: $editBookmarkNodeID) { ctx in
            EditBookmarkSheet(store: store, nodeID: ctx.nodeID) { newName in
                store.renameBookmarkNode(id: ctx.nodeID, to: newName)
            }
        }
        .alert("New Folder", isPresented: $showingNewBookmarkFolder) {
            TextField("Folder name", text: $newBookmarkFolderName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                let name = newBookmarkFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.createFolder(parentID: nil, name: name)
            }
        }
    }

    /// A row of evenly-spaced icons — one per section — that selects which
    /// section's "window" is shown, exactly like Xcode's navigator selector.
    private var sectionSelectorBar: some View {
        HStack(spacing: 0) {
            ForEach(SidebarSection.allCases) { section in
                sectionSelectorButton(section)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func sectionSelectorButton(_ section: SidebarSection) -> some View {
        let isSelected = selectedSection == section
        // Nothing to show for an empty Sources list — disable rather than select
        // an empty window.
        let isDisabled = section == .sources && store.sources.isEmpty
        return Button {
            selectedSection = section
        } label: {
            Image(systemName: section.systemImage)
                .font(.body)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(section.title)
    }

    @ViewBuilder
    private var bookmarksOrList: some View {
        if selectedSection == .bookmarks {
            BookmarksContainerView(store: store,
                onShowPicker: { bookmarkPickerContext = $0 },
                onEdit: { editBookmarkNodeID = EditBookmarkContext(nodeID: $0) },
                onNewFolder: {
                    showingNewBookmarkFolder = true
                    newBookmarkFolderName = ""
                })
        } else {
            listContent
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
        }
    }

    private var listContent: some View {
        List(selection: $listSelection) {
            switch selectedSection {
            case .pages: pagesSection()
            case .sources:
                SourcesSectionView(store: store, fileProvider: fileProvider,
                    manager: manager, launcher: launcher,
                    ingestingSourceIDs: ingestingSourceIDs,
                    extractingSourceIDs: extractingSourceIDs,
                    showingAddFromZotero: $showingAddFromZotero,
                    showingImportMarkdown: $showingImportMarkdown,
                    onAddFromURL: onAddFromURL,
                    isZoteroConfigured: isZoteroConfigured,
                    listSelection: $listSelection, activeSection: $activeSection)
            case .bookmarks: EmptyView()
            case .agent: toolsSection()
            }
        }
    }

    /// The active wiki's display name for the window title (falls back to the app
    /// name when no wiki is selected yet).
    private var activeWikiName: String {
        guard let id = manager.activeWikiID else { return "Self Driving Wiki" }
        return manager.wikis.first { $0.id == id }?.displayName ?? "Self Driving Wiki"
    }

    private func toolsSection() -> some View {
        Section {
            SidebarModeRow(title: "Ask", subtitle: "Read-only Q&A",
                systemImage: "bubble.left.and.text.bubble.right")
                .tag(WikiSelection.ask)
                .help("Chat with the agent — read-only, the agent cannot write the wiki.")

            SidebarModeRow(title: "Edit", subtitle: "Ask & update the wiki",
                systemImage: "square.and.pencil")
                .tag(WikiSelection.edit)
                .help("Chat with the agent and let it update the wiki.")

            SidebarModeRow(title: "Lint", subtitle: "Health-check the wiki",
                systemImage: "checkmark.shield")
                .tag(WikiSelection.lint)
                .help("Check the wiki for stale content, broken links, and inconsistencies")

            SidebarModeRow(title: "Activity", subtitle: "Operation log",
                systemImage: "clock.arrow.circlepath")
                .tag(WikiSelection.changeLog)
                .help("Operation history, projected read-only as log.md")

            SidebarModeRow(title: "Instructions", subtitle: "Agent prompt",
                systemImage: "sparkles")
                .tag(WikiSelection.systemPrompt)
                .help("Agent instructions, projected read-only as CLAUDE.md and AGENTS.md")
        } header: { SidebarSectionHeader(title: "Agent") }
    }

    private func pagesSection() -> some View {
        Section {
            Button {
                onNewPage()
            } label: {
                SidebarModeRow(title: "New Page", subtitle: "Create empty page",
                    systemImage: "plus")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help("Create a new page")

            Divider()

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

            pagesSectionRows()
        } header: {
            SidebarSectionHeader(title: "Pages")
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

    /// Extracted to keep the `body` type-checkable.
    private func pagesSectionRows() -> some View {
        Group {
            let source = store.searchQuery.isEmpty ? store.summaries : store.searchResults
            // ---- batch share plumbing ----
            let selectedPageIDs: Set<PageID> = Set(listSelection.compactMap { sel in
                if case .page(let id) = sel { return id } else { return nil }
            })
            // ---- end batch share plumbing ----
            if source.isEmpty, !store.searchQuery.isEmpty {
                Text("No matching pages").foregroundStyle(.secondary).font(.callout)
                    .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(source) { summary in
                SidebarPageRow(summary: summary)
                    .tag(WikiSelection.page(summary.id))
                    .contextMenu {
                        let pageID = summary.id
                        let isBatch = selectedPageIDs.count > 1 && selectedPageIDs.contains(pageID)
                        Button(isBatch ? "Open \(selectedPageIDs.count) Pages" : "Open",
                               systemImage: "arrow.up.forward.app") {
                            if isBatch {
                                for id in selectedPageIDs { store.openTab(.page(id)) }
                            } else {
                                store.openTab(.page(pageID))
                            }
                        }
                        Button(isBatch ? "Open \(selectedPageIDs.count) in Background" : "Open in Background",
                               systemImage: "dock.arrow.down.rectangle") {
                            if isBatch {
                                for id in selectedPageIDs { store.openTabInBackground(.page(id)) }
                            } else {
                                store.openTabInBackground(.page(pageID))
                            }
                        }
                        // Batch share — appears only when this row is part of a
                        // multi-select (2+ pages). Resolves all URLs in parallel
                        // via the daemon, then passes them to one picker.
                        if selectedPageIDs.count > 1, selectedPageIDs.contains(summary.id) {
                            let ids = selectedPageIDs
                            Button("Share \(ids.count) Pages",
                                   systemImage: "square.and.arrow.up") {
                                Task {
                                    let urls: [URL] = await withTaskGroup(of: URL?.self) { group in
                                        for id in ids {
                                            group.addTask { await fileProvider.resolvePageByTitleURL(id: id) }
                                        }
                                        var results: [URL] = []
                                        for await url in group { if let url { results.append(url) } }
                                        return results
                                    }
                                    guard !urls.isEmpty else { return }
                                    let picker = NSSharingServicePicker(items: urls)
                                    let mouseScreen = NSEvent.mouseLocation
                                    guard let window = NSApplication.shared.keyWindow,
                                          let contentView = window.contentView else { return }
                                    let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                                    let viewPoint = contentView.convert(windowPoint, from: nil)
                                    picker.show(
                                        relativeTo: NSRect(origin: viewPoint,
                                                           size: NSSize(width: 1, height: 1)),
                                        of: contentView, preferredEdge: .minY)
                                }
                            }
                        } else if fileProvider.path != nil {
                            Button("Share", systemImage: "square.and.arrow.up") {
                                Task {
                                    guard let url = await fileProvider.resolvePageByTitleURL(id: pageID) else { return }
                                    let picker = NSSharingServicePicker(items: [url])
                                    let mouseScreen = NSEvent.mouseLocation
                                    guard let window = NSApplication.shared.keyWindow,
                                          let contentView = window.contentView else { return }
                                    let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                                    let viewPoint = contentView.convert(windowPoint, from: nil)
                                    picker.show(
                                        relativeTo: NSRect(origin: viewPoint,
                                                           size: NSSize(width: 1, height: 1)),
                                        of: contentView, preferredEdge: .minY)
                                }
                            }
                        }
                        if selectedPageIDs.count <= 1, fileProvider.path != nil {
                            Button("Reveal in Finder", systemImage: "folder") {
                                Task { await fileProvider.revealPageInFinder(id: pageID) }
                            }
                        }
                        Divider()
                        let isBatchLint = selectedPageIDs.count > 1 && selectedPageIDs.contains(summary.id)
                        Button(isBatchLint ? "Lint \(selectedPageIDs.count) Pages" : "Lint Page",
                               systemImage: "checkmark.seal") {
                            Task {
                                if isBatchLint {
                                    let pages = selectedPageIDs.compactMap { id -> (id: PageID, title: String)? in
                                        guard let s = store.summaries.first(where: { $0.id == id }) else { return nil }
                                        return (id: id, title: s.title)
                                    }
                                    await AgentOperationRunner.runLintPages(
                                        pages: pages,
                                        launcher: launcher, store: store,
                                        manager: manager, fileProvider: fileProvider)
                                } else {
                                    await AgentOperationRunner.runLintPages(
                                        pages: [(id: summary.id, title: summary.title)],
                                        launcher: launcher, store: store,
                                        manager: manager, fileProvider: fileProvider)
                                }
                            }
                        }
                        .disabled(store.isAgentRunning)

                        if selectedPageIDs.count <= 1 {
                            Divider()
                            Button("Rename", systemImage: "pencil") { beginRename(summary) }
                        } else {
                            Divider()
                        }
                        let isBatchDelete = selectedPageIDs.count > 1 && selectedPageIDs.contains(pageID)
                        Button(isBatchDelete ? "Delete \(selectedPageIDs.count) Pages" : "Delete",
                               systemImage: "trash", role: .destructive) {
                            if isBatchDelete {
                                for id in selectedPageIDs { store.delete(id) }
                            } else {
                                store.delete(pageID)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { store.delete(summary.id) }
                    }
            }
        }
    }

    private func selectionDidChange(_ newValue: Set<WikiSelection>) {
        // Cmd+A selects everything — filter to the active section only.
        let hasPage = newValue.contains(where: { if case .page = $0 { true } else { false } })
        let hasFile = newValue.contains(where: { if case .source = $0 { true } else { false } })
        if hasPage && hasFile {
            handleSelectAll()
            return
        }

        // Only update activeSection from single clicks (not mass selections).
        if newValue.count == 1, let first = newValue.first {
            switch first {
            case .page: activeSection = .pages
            case .source: activeSection = .sources
            case .bookmark: break  // stay on current section
            default: break
            }
            // Bookmark folders just highlight — don't open a tab.
            if case .bookmark = first {
                DebugLog.tabs("selectionDidChange: .bookmark(\(first)) — highlight only, no openTab")
                return
            }
            // The `listSelection` set is also written programmatically by the
            // `.onChange(of: store.selection)` sync below whenever the model
            // changes the active tab (tab click, close→neighbor, history nav).
            // In that case `first` already equals the active tab's selection, so
            // opening a tab would spawn a duplicate to the right. Only a *fresh*
            // sidebar click lands on a selection that isn't already the active
            // tab — that's the one that should open/focus a tab.
            if first == store.activeTab?.selection {
                DebugLog.tabs(
                    "SidebarView.selectionDidChange: \(first) already active tab — skip openTab (programmatic sync)")
                return
            }
            DebugLog.tabs("SidebarView.selectionDidChange: click \(first) → openTab")
            // Single-click opens the page's tab — reused if already open, else new.
            store.openTab(first)
        }
    }

    private func handleSelectAll() {
        switch activeSection {
        case .sources:
            listSelection = Set(store.sources.map { WikiSelection.source($0.id) })
        case .pages:
            listSelection = Set(store.summaries.map { WikiSelection.page($0.id) })
        }
    }

    private func commitRename() {
        if let target = renameTarget { store.rename(target.id, to: renameText) }
        renameTarget = nil
    }

    private func beginRename(_ summary: WikiPageSummary) {
        renameText = summary.title
        renameTarget = summary
    }

    /// Drive the rename alert off `renameTarget != nil` without a manual
    /// `Binding(get:set:)` for the value itself (we only need a Bool here).
    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }
}

/// Presents the bookmark item-picker sheet. Lives as a `ViewModifier` on
/// `SidebarView`'s outer body (outside the `List`) so the sheet isn't
/// virtualized by the List's row recycling.
private struct BookmarkPickerSheetModifier: ViewModifier {
    @Binding var context: PickerContext?
    let store: WikiStoreModel

    func body(content: Content) -> some View {
        content.sheet(item: $context) { ctx in
            ItemPickerSheet(
                allItems: pickerItems(for: ctx.kind),
                onConfirm: { selectedIDs in
                    let parentID = ctx.parentID
                    for id in selectedIDs {
                        switch ctx.kind {
                        case .pages: store.addPageRef(parentID: parentID, pageID: id)
                        case .sources: store.addSourceRef(parentID: parentID, sourceID: id)
                        }
                    }
                }
            )
        }
    }

    private func pickerItems(for kind: ItemPickerKind) -> [PickerItem] {
        switch kind {
        case .pages:
            return store.summaries.map { PickerItem(id: $0.id, title: $0.title, isPage: true) }
        case .sources:
            return store.sources.map { PickerItem(id: $0.id, title: $0.effectiveName, isPage: false) }
        }
    }
}

/// A plain section header. Visibility is now driven by the icon toggle bar at the
/// top of the sidebar, so the header is a static title rather than a chevron.
struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.headline).foregroundStyle(.primary)
    }
}
