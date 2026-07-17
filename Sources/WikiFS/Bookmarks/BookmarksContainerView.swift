import SwiftUI
import WikiFSCore

/// The Bookmarks section — a header bar with compact action buttons on the
/// trailing edge (native macOS sidebar pattern), and `NSOutlineView` below.
/// Uses `NSOutlineView` (via `BookmarksOutlineView`) instead of SwiftUI's
/// `List`/`OutlineGroup` for instant selection performance on macOS.
struct BookmarksContainerView: View {
    let store: WikiStoreModel
    let fileProvider: FileProviderFacade
    var onShowPicker: (PickerContext) -> Void
    var onEdit: (String) -> Void
    var onNewFolder: () -> Void

    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Section header: title on the left, compact action buttons on the
            // right — the native macOS pattern (Finder, Notes, Mail).
            bookmarksHeader

            // Search field: substring filter over bookmark labels and resolved
            // page/source/chat titles (issue #240).
            if !store.bookmarkNodes.isEmpty {
                bookmarksSearchBar
                Divider()
            }

            Divider()

            // NSOutlineView — instant selection, native macOS performance
            BookmarksOutlineView(
                store: store,
                nodes: filteredNodes,
                forceExpandAll: !searchText.isEmpty,
                fileProvider: fileProvider,
                onOpen: { selections in
                    for sel in selections { store.openTab(sel) }
                },
                onOpenBackground: { selections in
                    for sel in selections { store.openTabInBackground(sel) }
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

    /// When search is active, returns only matching nodes plus their ancestor
    /// folders (so hits inside nested folders are visible). When search is
    /// empty, returns all nodes unchanged.
    private var filteredNodes: [BookmarkNode] {
        let allNodes = store.bookmarkNodes
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return allNodes
        }
        return Self.filterNodes(
            allNodes,
            query: searchText,
            resolveTitle: { Self.resolveTitle(for: $0, in: store) }
        )
    }

    /// Resolves the display title for a bookmark node: folder label, or for
    /// refs, the title/name of the target page/source/chat.
    static func resolveTitle(for node: BookmarkNode, in store: WikiStoreModel) -> String {
        switch node.kind {
        case .folder:
            return node.label ?? ""
        case .pageRef:
            return node.targetID.flatMap { id in
                store.summaries.first { $0.id == id }?.title
            } ?? ""
        case .sourceRef:
            return node.targetID.flatMap { id in
                store.sources.first { $0.id == id }?.effectiveName
            } ?? ""
        case .chatRef:
            return node.targetID.flatMap { id in
                store.chats.first { $0.id == id }?.title
            } ?? ""
        }
    }

    /// Pure filtering logic: returns nodes whose resolved title matches `query`
    /// (case-insensitive substring), plus all ancestor folders so nested hits
    /// are visible. Extracted so the rule is unit-testable without a live store.
    nonisolated static func filterNodes(
        _ nodes: [BookmarkNode],
        query: String,
        resolveTitle: (BookmarkNode) -> String
    ) -> [BookmarkNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nodes }

        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        // Collect ids of nodes that match the query.
        var matchingIDs = Set<String>()
        for node in nodes {
            let title = resolveTitle(node)
            if title.localizedCaseInsensitiveContains(q) {
                matchingIDs.insert(node.id)
            }
        }

        // Expand to include all ancestors of matching nodes (so a hit inside a
        // nested folder is visible when the folder would otherwise be collapsed).
        var visibleIDs = Set<String>()
        for id in matchingIDs {
            var current: String? = id
            while let cid = current, let node = byID[cid] {
                visibleIDs.insert(cid)
                current = node.parentID
            }
        }

        return nodes.filter { visibleIDs.contains($0.id) }
    }
}

struct PickerContext: Identifiable {
    let id: UUID
    let parentID: String?
    let kind: ItemPickerKind
}

struct EditBookmarkContext: Identifiable {
    let id = UUID()
    let nodeID: String
}
