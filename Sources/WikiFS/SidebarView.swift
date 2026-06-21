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
    /// Callback when the user clicks "Ingest N Files" in batch mode.
    var onBatchIngest: (([PageID]) -> Void)? = nil
    /// Files whose agent run is in flight (agent phase) — shows the
    /// "Ingesting…" spinner on those rows.
    var ingestingFileIDs: Set<PageID> = []
    /// Files whose pdf2md conversion is in flight (extraction phase) — shows the
    /// "Extracting…" spinner on those rows. Independent of `ingestingFileIDs`.
    var extractingFileIDs: Set<PageID> = []

    @State private var renameTarget: WikiPageSummary?
    @State private var renameText: String = ""
    /// Whether the "Pages" section is expanded. Pure UI state — not persisted.
    @State private var isPagesExpanded = true
    @State private var isToolsExpanded = true
    @State private var isSystemExpanded = true

    // MARK: - Multi-select

    /// Native multi-select binding for the List — supports Shift+Arrow,
    /// Shift+Click, and Command+Click. Synced to `store.selection` for
    /// single-item navigation.
    @State private var listSelection: Set<WikiSelection> = []

    /// Tracks which section was last clicked, so Cmd+A selects only that section.
    @State private var activeSection: ActiveSection = .pages

    enum ActiveSection { case pages, sources }

    var body: some View {
        listContent
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
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
    }

    private var listContent: some View {
        List(selection: $listSelection) {
            WikiSwitcher(manager: manager).listRowSeparator(.hidden)
            toolsSection()
            pagesSection()
            if !store.sources.isEmpty {
                FilesSectionView(store: store, fileProvider: fileProvider,
                    ingestingFileIDs: ingestingFileIDs,
                    extractingFileIDs: extractingFileIDs,
                    onBatchIngest: onBatchIngest,
                    listSelection: $listSelection, activeSection: $activeSection)
            }
            systemSection()
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
            if isToolsExpanded {
                SidebarModeRow(title: "Query", subtitle: "Ask or update",
                    systemImage: "bubble.left.and.text.bubble.right")
                    .tag(WikiSelection.query)
                    .help("Ask questions and decide whether Claude should update the wiki")
            }
        } header: { SidebarSectionHeader(title: "Tools", isExpanded: $isToolsExpanded) }
    }

    private func systemSection() -> some View {
        Section {
            if isSystemExpanded {
                SidebarModeRow(title: "Lint", subtitle: "Health-check the wiki",
                    systemImage: "checkmark.shield")
                    .tag(WikiSelection.lint)
                    .help("Check the wiki for stale content, broken links, and inconsistencies")
                Button {
                    _ = store.recomputeMissingEmbeddings()
                } label: {
                    SidebarModeRow(title: "Reindex Search", subtitle: "Rebuild semantic embeddings",
                        systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.plain)
                .help("Recompute embeddings for all missing pages for semantic search")
                SidebarModeRow(title: "Activity", subtitle: "Operation log",
                    systemImage: "clock.arrow.circlepath")
                    .tag(WikiSelection.changeLog)
                    .help("Operation history, projected read-only as log.md")
                SidebarModeRow(title: "Instructions", subtitle: "Agent prompt",
                    systemImage: "sparkles")
                    .tag(WikiSelection.systemPrompt)
                    .help("Agent instructions, projected read-only as CLAUDE.md and AGENTS.md")
            }
        } header: { SidebarSectionHeader(title: "System", isExpanded: $isSystemExpanded) }
    }

    private func pagesSection() -> some View {
        Section {
            if isPagesExpanded { pagesSectionRows() }
        } header: {
            HStack(spacing: 0) {
                SidebarSectionHeader(title: "Pages", isExpanded: $isPagesExpanded)
                Spacer()
                Picker("Sort", selection: $store.pageSortOrder) {
                    Text("Last Updated").tag(PageSortOrder.lastUpdated)
                    Text("Newest First").tag(PageSortOrder.newestFirst)
                    Text("Title A–Z").tag(PageSortOrder.titleAZ)
                }
                .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
                .help("Sort pages by date or title")
            }
        }
    }

    /// Extracted to keep the `body` type-checkable.
    private func pagesSectionRows() -> some View {
        Group {
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
            .padding(.vertical, 4).padding(.horizontal, 2)
            let source = store.searchQuery.isEmpty ? store.summaries : store.searchResults
            if source.isEmpty, !store.searchQuery.isEmpty {
                Text("No matching pages").foregroundStyle(.secondary).font(.callout)
                    .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(source) { summary in
                SidebarPageRow(summary: summary)
                    .tag(WikiSelection.page(summary.id))
                    .contextMenu {
                        Button("Rename") { beginRename(summary) }
                        Button("Delete", role: .destructive) { store.delete(summary.id) }
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
            default: break
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

/// A collapsible section header with chevron + title.
struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
            Text(title).font(.headline).foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
    }
}
