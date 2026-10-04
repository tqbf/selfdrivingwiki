import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Sidebar host: a section-selector bar (Pages / Sources / Bookmarks / Chats)
/// above the active section's view. Each section is now an independent view:
/// Pages, Sources, and Bookmarks are native AppKit `NSTableView`/`NSOutlineView`
/// (instant selection, native double-click); Chats is a small SwiftUI `List`.
/// The shared SwiftUI `List(selection:)` and cross-section multi-select
/// machinery are gone — each view owns its selection.
struct SidebarView: View {
    @Bindable var store: WikiStoreModel
    /// App-scoped registry — backs the switcher header at the top of the list.
    @Bindable var registry: WikiRegistryClient
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: any WikiSessionProtocol
    /// Used to open an ingested file in its default app via its user-visible URL.
    let fileProvider: FileProviderFacade
    /// Required to launch the LLM lint from the sidebar context menu.
    @Bindable var launcher: AgentLauncher
    /// Files whose agent run is in flight (agent phase) — shows the
    /// "Ingesting…" spinner on those rows.
    var ingestingSourceIDs: Set<SourceID> = []

    @Binding var showingImportMarkdown: Bool
    var onAddFromURL: () -> Void
    var onNewPage: () -> Void

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
        case pages, sources, bookmarks, chats

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pages: "Pages"
            case .sources: "Sources"
            case .bookmarks: "Bookmarks"
            case .chats: "Chats"
            }
        }

        var systemImage: String {
            switch self {
            case .pages: ResourceKind.page.systemImageName
            case .sources: ResourceKind.source.systemImageName
            case .bookmarks: ResourceKind.bookmark.systemImageName
            case .chats: ResourceKind.chat.systemImageName
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionSelectorBar
                .padding(.top, 8)
            Divider()
            bookmarksOrList
            Divider()
            wikiSwitcherRow
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            strategyFooterRow
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .navigationTitle(activeWikiName)
        .navigationSplitViewColumnWidth(min: PageEditorMetrics.sidebarMinWidth,
                                         ideal: PageEditorMetrics.sidebarIdealWidth)
        .modifier(BookmarkPickerSheetModifier(
            context: $bookmarkPickerContext,
            store: store))
        .sheet(item: $editBookmarkNodeID) { ctx in
            EditBookmarkSheet(store: store, nodeID: ctx.nodeID)
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
        // "Show In List" reveal (issue #183): a detail-view button asked the
        // sidebar to surface a page/source. Switch to the matching section and
        // drop any active search that would hide the target row. The actual
        // scroll + select happens in the list view once it mounts.
        .onChange(of: store.pendingSidebarRevealVersion) { _, _ in
            guard let target = store.pendingSidebarReveal else { return }
            switch target {
            case .page(let id):
                selectedSection = .pages
                // Clearing to "" resets searchResults synchronously (scheduleSearch
                // sets [] on empty), so the full list is visible when the row is
                // looked up.
                if !store.searchQuery.isEmpty,
                   !store.searchResults.contains(where: { $0.id == id }) {
                    store.searchQuery = ""
                }
            case .source(let id):
                selectedSection = .sources
                if !store.sourceSearchQuery.isEmpty,
                   !store.sourceSearchResults.contains(where: { $0.id == id }) {
                    store.sourceSearchQuery = ""
                }
            case .chat(let id):
                selectedSection = .chats
                // Same search-drop as pages/sources: a hidden row can't be
                // revealed. (The date filter is AgentToolsView state; that
                // view resets it on its own reveal observation.)
                if !store.chatSearchQuery.isEmpty,
                   !store.chatSearchResults.contains(where: { $0.id == id }) {
                    store.chatSearchQuery = ""
                }
            default:
                break
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
        .help(section.title)
    }

    @ViewBuilder
    private var bookmarksOrList: some View {
        switch selectedSection {
        case .pages:
            PagesContainerView(store: store, fileProvider: fileProvider,
                               session: session, registry: registry,
                               launcher: launcher,
                               onNewPage: onNewPage)
        case .sources:
            SourcesContainerView(store: store, fileProvider: fileProvider,
                                 session: session, launcher: launcher,
                                 queueEngine: session.queueEngine,
                                 extractionProvider: session.extractionProvider,
                                 ingestingSourceIDs: ingestingSourceIDs,
                                 showingImportMarkdown: $showingImportMarkdown,
                                 onAddFromURL: onAddFromURL)
        case .bookmarks:
            BookmarksContainerView(store: store, fileProvider: fileProvider,
                onShowPicker: { bookmarkPickerContext = $0 },
                onEdit: { editBookmarkNodeID = EditBookmarkContext(nodeID: $0) },
                onNewFolder: {
                    showingNewBookmarkFolder = true
                    newBookmarkFolderName = ""
                })
        case .chats:
            AgentToolsView(store: store)
        }
    }

    /// The active wiki's display name for the window title (falls back to the app
    /// name when no wiki is selected yet).
    private var activeWikiName: String {
        session.descriptor.displayName
    }

    /// The wiki switcher pill — the top-level container switch (each wiki is
    /// its own DB + File Provider domain). Sits directly above the Strategy
    /// row so the sidebar footer reads as one cluster: which wiki you are in,
    /// then that wiki's editorial strategy.
    private var wikiSwitcherRow: some View {
        WikiSwitcher(registry: registry, currentWikiID: session.wikiID)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The wiki-scoped Strategy entry: a pinned footer row below the section
    /// lists. The row names the ACTIVE wiki — it edits that wiki's strategy,
    /// not a global setting — and shows an "Edited" marker while a strategy
    /// draft has unsaved changes, so the draft is visible from anywhere in
    /// the sidebar. Opens (or focuses) the Strategy tab through the normal
    /// `openTab` dedup.
    private var strategyFooterRow: some View {
        let isSelected = store.selection == .strategy
        return Button {
            store.openTab(.strategy)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Strategy")
                        .font(.callout.weight(.medium))
                    Text(activeWikiName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                if store.isStrategyDraftDirty {
                    Text("Edited")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, WikiStrategyEditorMetrics.editedCapsuleHorizontalPadding)
                        .padding(.vertical, WikiStrategyEditorMetrics.editedCapsuleVerticalPadding)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Strategy for \(activeWikiName)")
        .help("Edit the editorial strategy for \(activeWikiName)")
    }
}

/// Presents the bookmark item-picker sheet. Lives as a `ViewModifier` on
/// `SidebarView`'s outer body (outside the list) so the sheet isn't virtualized
/// by row recycling.
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
                        switch id {
                        case .page(let pageID): store.addPageRef(parentID: parentID, pageID: pageID)
                        case .source(let sourceID): store.addSourceRef(parentID: parentID, sourceID: sourceID)
                        }
                    }
                }
            )
        }
    }

    private func pickerItems(for kind: ItemPickerKind) -> [PickerItem] {
        switch kind {
        case .pages:
            return store.summaries.map { PickerItem(id: .page($0.id), title: $0.title, isPage: true) }
        case .sources:
            return store.sources.map { PickerItem(id: .source($0.id), title: $0.effectiveName, isPage: false) }
        }
    }
}
