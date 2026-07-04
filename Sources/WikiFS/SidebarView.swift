import SwiftUI
import WikiFSCore

/// Sidebar host: a section-selector bar (Pages / Sources / Bookmarks / Agent)
/// above the active section's view. Each section is now an independent view:
/// Pages, Sources, and Bookmarks are native AppKit `NSTableView`/`NSOutlineView`
/// (instant selection, native double-click); Agent is a small SwiftUI `List`.
/// The shared SwiftUI `List(selection:)` and cross-section multi-select
/// machinery are gone — each view owns its selection.
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
        .navigationSplitViewColumnWidth(min: PageEditorMetrics.sidebarMinWidth,
                                         ideal: PageEditorMetrics.sidebarIdealWidth)
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
        switch selectedSection {
        case .pages:
            PagesContainerView(store: store, fileProvider: fileProvider,
                               manager: manager, launcher: launcher,
                               onNewPage: onNewPage)
        case .sources:
            SourcesContainerView(store: store, fileProvider: fileProvider,
                                 manager: manager, launcher: launcher,
                                 ingestingSourceIDs: ingestingSourceIDs,
                                 extractingSourceIDs: extractingSourceIDs,
                                 showingAddFromZotero: $showingAddFromZotero,
                                 showingImportMarkdown: $showingImportMarkdown,
                                 onAddFromURL: onAddFromURL,
                                 isZoteroConfigured: isZoteroConfigured)
        case .bookmarks:
            BookmarksContainerView(store: store, fileProvider: fileProvider,
                onShowPicker: { bookmarkPickerContext = $0 },
                onEdit: { editBookmarkNodeID = EditBookmarkContext(nodeID: $0) },
                onNewFolder: {
                    showingNewBookmarkFolder = true
                    newBookmarkFolderName = ""
                })
        case .agent:
            AgentToolsView(store: store)
        }
    }

    /// The active wiki's display name for the window title (falls back to the app
    /// name when no wiki is selected yet).
    private var activeWikiName: String {
        guard let id = manager.activeWikiID else { return "Self Driving Wiki" }
        return manager.wikis.first { $0.id == id }?.displayName ?? "Self Driving Wiki"
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
