import SwiftUI
import WikiFSCore

/// The Bookmarks section — a header bar with compact action buttons on the
/// trailing edge, then "Show" (kind filter) and "Sort by" rows and a search
/// bar (native macOS sidebar pattern), and `NSOutlineView` below.
/// Uses `NSOutlineView` (via `BookmarksOutlineView`) instead of SwiftUI's
/// `List`/`OutlineGroup` for instant selection performance on macOS.
///
/// Sorting and filtering (issue #241) are display-only: they select and order
/// what the outline renders but never rewrite the persisted `position`
/// column that manual drag-and-drop order uses. Like the Sources filter, the
/// choices live in `@State` here, so they reset when the user switches
/// sidebar sections.
struct BookmarksContainerView: View {
    let store: WikiStoreModel
    let fileProvider: FileProviderFacade
    // All closures are main-actor-isolated: they touch the @MainActor
    // WikiStoreModel or present sheets/state on the main actor.
    var onShowPicker: (@MainActor @Sendable (PickerContext) -> Void)
    var onEdit: (@MainActor @Sendable (BookmarkID) -> Void)
    var onNewFolder: (@MainActor @Sendable () -> Void)

    @State private var searchText: String = ""
    /// Kind filter backing the "Show" picker (issue #241). View-level state,
    /// like `SourceFilter` in `SourcesContainerView`.
    @State private var kindFilter: BookmarkKindFilter = .all
    /// Display sort backing the "Sort by" picker (issue #241). Display-only —
    /// never rewrites the persisted `position` column.
    @State private var sortOrder: BookmarkSortOrder = .manual

    var body: some View {
        VStack(spacing: 0) {
            // Section header: title on the left, compact action buttons on the
            // right — the native macOS pattern (Finder, Notes, Mail).
            bookmarksHeader

            // Filter / sort / search chrome: shown together whenever at
            // least one bookmark exists (issues #240, #241).
            if !store.bookmarkNodes.isEmpty {
                bookmarksFilterRow
                bookmarksSortRow
                bookmarksSearchBar
                Divider()
            }

            Divider()

            // NSOutlineView — instant selection, native macOS performance.
            // The ZStack adds the "no results" overlay for an active filter
            // or search that matches nothing (same pattern as Sources/Pages).
            ZStack(alignment: .topLeading) {
                BookmarksOutlineView(
                    store: store,
                    nodes: filteredNodes,
                    forceExpandAll: !searchText.isEmpty || kindFilter != .all,
                    sortOrder: sortOrder,
                    fileProvider: fileProvider,
                    onOpen: { selections in
                        for sel in selections { store.openTab(sel) }
                    },
                    onOpenBackground: { selections in
                        for sel in selections { store.openTabInBackground(sel) }
                    },
                    onGoToOriginal: { selection in
                        store.requestSidebarReveal(selection)
                    },
                    onEdit: { onEdit($0) },
                    onDelete: { ids in
                        for id in ids { store.deleteBookmarkNode(id: id) }
                    },
                    onAddPage: { onShowPicker(PickerContext(id: UUID(), parentID: $0, kind: .pages)) },
                    onAddSource: { onShowPicker(PickerContext(id: UUID(), parentID: $0, kind: .sources)) },
                    onNewFolder: { onNewFolder() },
                    onNewSubfolder: { id in
                        store.createFolder(parentID: id, name: "New Folder")
                    }
                )
                if filteredNodes.isEmpty && (!searchText.isEmpty || kindFilter != .all) {
                    Text("No matching bookmarks")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 8).padding(.horizontal, 4)
                }
            }
        }
    }

    /// Section header: title on the leading edge, compact action buttons on the
    /// trailing edge — the native macOS pattern (Apple HIG: "include an Add (+)
    /// button on the trailing side of the group's label"). Mirrors Photos,
    /// Mail, and Finder sidebar section headers.
    private var bookmarksHeader: some View {
        HStack(spacing: 2) {
            Text("Bookmarks")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            headerButton(systemImage: "folder.badge.plus", help: "New Folder") {
                onNewFolder()
            }
            headerButton(systemImage: ResourceKind.page.systemImageName, help: "Add Page…") {
                onShowPicker(PickerContext(id: UUID(), parentID: nil, kind: .pages))
            }
            headerButton(systemImage: ResourceKind.source.systemImageName, help: "Add Source…") {
                onShowPicker(PickerContext(id: UUID(), parentID: nil, kind: .sources))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A compact, borderless icon button for the header's trailing edge.
    /// Idle state uses `.secondary`; hover highlights via `.tint` — matches the
    /// subtle treatment of sidebar action buttons in native macOS apps.
    private func headerButton(systemImage: String, help: String,
                              action: @escaping @MainActor @Sendable () -> Void) -> some View {
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

    // MARK: - Show / Sort by pickers

    /// "Show" kind-filter row — same style as `SourcesContainerView`'s
    /// filter row: caption label, trailing menu picker, tight padding.
    private var bookmarksFilterRow: some View {
        HStack {
            Text("Show").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Filter", selection: $kindFilter) {
                Text("All").tag(BookmarkKindFilter.all)
                Text("Folders").tag(BookmarkKindFilter.folders)
                Text("Pages").tag(BookmarkKindFilter.pages)
                Text("Sources").tag(BookmarkKindFilter.sources)
                Text("Chats").tag(BookmarkKindFilter.chats)
            }
            .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// "Sort by" row — same style as `PagesContainerView`'s sort row.
    /// "Custom Order" is the persisted drag-and-drop order (the default).
    private var bookmarksSortRow: some View {
        HStack {
            Text("Sort by").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Sort", selection: $sortOrder) {
                Text("Custom Order").tag(BookmarkSortOrder.manual)
                Text("Name A–Z").tag(BookmarkSortOrder.nameAZ)
                Text("Date Added").tag(BookmarkSortOrder.dateAdded)
                Text("Date Updated").tag(BookmarkSortOrder.dateUpdated)
            }
            .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    // MARK: - Search

    private var bookmarksSearchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search bookmarks…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .disableAutocorrection(true)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .padding(.horizontal, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// Applies the search query and kind filter, then keeps every ancestor
    /// folder of surviving nodes so nested hits stay visible. Under Name A–Z
    /// the model title arrays are touched even with an empty query, so the
    /// @Observable dependency tracks renames and a rename re-sorts the
    /// outline (issue #241).
    private var filteredNodes: [BookmarkNode] {
        if sortOrder == .nameAZ {
            _ = store.summaries.count
            _ = store.sources.count
            _ = store.chats.count
        }
        return Self.filterNodes(
            store.bookmarkNodes,
            query: searchText,
            kindFilter: kindFilter,
            resolveTitle: { Self.resolveTitle(for: $0, in: store) }
        )
    }

    /// Resolves the display title for a bookmark node: folder label, or for
    /// refs, the title/name of the target page/source/chat.
    static func resolveTitle(for node: BookmarkNode, in store: WikiStoreModel) -> String {
        switch node.content {
        case .folder(let label): return label
        case .page(let id): return store.summaries.first { $0.id == id }?.title ?? ""
        case .source(let id): return store.sources.first { $0.id == id }?.effectiveName ?? ""
        case .chat(let id): return store.chats.first { $0.id == id }?.title ?? ""
        }
    }

    /// Pure filtering core: returns nodes satisfying `predicate`, plus all
    /// ancestor folders so nested hits stay visible. One pass over the nodes
    /// plus one ancestor walk per hit; search query and kind filter compose
    /// as a conjunctive predicate before ancestor expansion.
    nonisolated static func visibleNodes(
        _ nodes: [BookmarkNode],
        matching predicate: (BookmarkNode) -> Bool
    ) -> [BookmarkNode] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        var matchingIDs = Set<BookmarkID>()
        for node in nodes where predicate(node) {
            matchingIDs.insert(node.id)
        }

        // Expand to include all ancestors of matching nodes (so a hit inside a
        // nested folder is visible when the folder would otherwise be collapsed).
        var visibleIDs = Set<BookmarkID>()
        for id in matchingIDs {
            var current: BookmarkID? = id
            while let cid = current, let node = byID[cid] {
                visibleIDs.insert(cid)
                current = node.parentID
            }
        }

        return nodes.filter { visibleIDs.contains($0.id) }
    }

    /// Pure filtering logic: returns nodes whose resolved title matches
    /// `query` (case-insensitive substring) AND whose kind matches
    /// `kindFilter`, plus all ancestor folders so nested hits are visible.
    /// An empty query with `.all` returns all nodes unchanged. Extracted so
    /// the rule is unit-testable without a live store.
    nonisolated static func filterNodes(
        _ nodes: [BookmarkNode],
        query: String,
        kindFilter: BookmarkKindFilter = .all,
        resolveTitle: (BookmarkNode) -> String
    ) -> [BookmarkNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || kindFilter != .all else { return nodes }
        return visibleNodes(nodes, matching: { node in
            (q.isEmpty || resolveTitle(node).localizedCaseInsensitiveContains(q))
                && kindFilter.matches(node.kind)
        })
    }
}

struct PickerContext: Identifiable, Sendable {
    let id: UUID
    let parentID: BookmarkID?
    let kind: ItemPickerKind
}

struct EditBookmarkContext: Identifiable {
    let id = UUID()
    let nodeID: BookmarkID
}
