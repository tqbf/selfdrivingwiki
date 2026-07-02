import SwiftUI
import WikiFSCore

/// A folder item for the destination picker — a lightweight wrapper that
/// represents either the root level or a specific folder node.
private struct FolderItem: Identifiable, Hashable {
    let id: String          // "root" or the BookmarkNode id
    let label: String
    let depth: Int
}

/// Sheet for choosing where to add a bookmark. Shows the folder tree
/// (folders only, no leaf refs) so the user can pick a destination.
///
/// Matches macOS conventions (Safari "Add Bookmark", Finder "Move To"):
/// - Outline of folders with expandable disclosure
/// - "Root" option at the top (add at the top level)
/// - "New Folder" button to create a folder inline
/// - Cancel / Add buttons
struct BookmarkDestinationSheet: View {
    let store: WikiStoreModel
    let onConfirm: (String?) -> Void  // parentID (nil = root)

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String? = "root"
    @State private var expandedIDs: Set<String> = []
    @State private var showingNewFolder = false
    @State private var newFolderName = ""

    /// Flat list of folders with depth info, sorted by tree position.
    private var folders: [FolderItem] {
        var items: [FolderItem] = []
        // Root is always available
        items.append(FolderItem(id: "root", label: "Bookmarks", depth: 0))
        // Walk the folder nodes in tree order
        let folderNodes = store.bookmarkNodes.filter { $0.kind == .folder }
        let byParent = Dictionary(grouping: folderNodes, by: { $0.parentID })
        func walk(_ parentID: String?, depth: Int) {
            let children = (byParent[parentID] ?? []).sorted { $0.position < $1.position }
            for child in children {
                items.append(FolderItem(id: child.id, label: child.label ?? "Untitled", depth: depth))
                if expandedIDs.contains(child.id) {
                    walk(child.id, depth: depth + 1)
                }
            }
        }
        walk(nil, depth: 1)
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add to Bookmarks")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(folders) { item in
                        folderRow(item)
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    showingNewFolder = true
                    newFolderName = ""
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let parentID = selectedID == "root" ? nil : selectedID
                    onConfirm(parentID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 360, height: 420)
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                let parentID = selectedID == "root" ? nil : selectedID
                if let newID = store.createFolder(parentID: parentID, name: name) {
                    selectedID = newID
                    expandedIDs.insert(parentID ?? "root")
                }
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ item: FolderItem) -> some View {
        let isSelected = selectedID == item.id
        let hasChildren = store.bookmarkNodes.contains {
            $0.parentID == item.id && $0.kind == .folder
        }
        let isExpanded = expandedIDs.contains(item.id)

        HStack(spacing: 4) {
            // Indentation
            Spacer().frame(width: CGFloat(item.depth) * 16)

            // Disclosure triangle for folders with children
            if hasChildren {
                Button {
                    if isExpanded {
                        expandedIDs.remove(item.id)
                    } else {
                        expandedIDs.insert(item.id)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 14)
            }

            Image(systemName: "folder")
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .font(.callout)

            Text(item.label)
                .font(.callout)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if hasChildren {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isExpanded {
                        expandedIDs.remove(item.id)
                    } else {
                        expandedIDs.insert(item.id)
                    }
                }
            }
            selectedID = item.id
        }
    }
}
