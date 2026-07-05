import SwiftUI
import WikiFSCore

/// The Bookmarks section — a header bar with compact action buttons on the
/// trailing edge (native macOS sidebar pattern), and `NSOutlineView` below.
/// Uses `NSOutlineView` (via `BookmarksOutlineView`) instead of SwiftUI's
/// `List`/`OutlineGroup` for instant selection performance on macOS.
struct BookmarksContainerView: View {
    let store: WikiStoreModel
    let fileProvider: FileProviderSpike
    var onShowPicker: (PickerContext) -> Void
    var onEdit: (String) -> Void
    var onNewFolder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Section header: title on the left, compact action buttons on the
            // right — the native macOS pattern (Finder, Notes, Mail).
            bookmarksHeader

            Divider()

            // NSOutlineView — instant selection, native macOS performance
            BookmarksOutlineView(
                store: store,
                nodes: store.bookmarkNodes,
                fileProvider: fileProvider,
                onOpen: { sel in store.openTab(sel) },
                onEdit: { onEdit($0) },
                onDelete: { store.deleteBookmarkNode(id: $0) },
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
            headerButton(systemImage: "doc.text", help: "Add Page…") {
                onShowPicker(PickerContext(id: UUID(), parentID: nil, kind: .pages))
            }
            headerButton(systemImage: "doc", help: "Add Source…") {
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
