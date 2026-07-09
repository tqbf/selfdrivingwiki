import SwiftUI
import WikiFSCore

/// What kind of item a `BookmarkTargetPickerContext` carries. Distinct from
/// `ItemPickerKind` (which drives the folder-level "Add Page…/Add Source…"
/// browse-and-pick flow and has no chat case) — this one backs the "already
/// have the item(s), pick a destination folder" flow, which does support chats.
enum BookmarkRefKind: String {
    case pages
    case sources
    case chats
}

/// Fixed item selection carried into the bookmark-target picker — the "inverse"
/// of `PickerContext`. Here the items are already chosen (a multi-row selection
/// from the Pages/Sources list, or the active chat) and the user picks the
/// destination folder.
struct BookmarkTargetPickerContext: Identifiable {
    let id = UUID()
    let kind: BookmarkRefKind
    let ids: [PageID]
}

/// The inverse of `ItemPickerSheet`: the item selection is fixed, and the user
/// picks (or creates) the destination bookmark folder. Confirming calls
/// `onConfirm` with the chosen folder's id (or `nil` for the bookmarks root),
/// and the caller creates one ref per selected item via
/// `WikiStoreModel.addPageRef` / `addSourceRef` / `addChatRef`.
///
/// Reads `store.bookmarkNodes` live so an inline "Create" folder shows up
/// immediately and auto-selects.
struct BookmarkTargetPickerSheet: View {
    @Bindable var store: WikiStoreModel
    let kind: BookmarkRefKind
    let ids: [PageID]
    /// Receives the chosen destination folder id (`nil` = bookmarks root).
    let onConfirm: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var selectedFolderID: String? = nil
    @State private var newFolderName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Text(headerTitle)
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            searchBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredFolders) { folder in
                        row(for: folder)
                    }
                    if filteredFolders.isEmpty {
                        Text(searchText.isEmpty
                             ? "No folders yet — create one below."
                             : "No matching folders")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            newFolderRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            HStack {
                Text("\(ids.count) item\(ids.count == 1 ? "" : "s") will be added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    DebugLog.tabs("BookmarkTargetPickerSheet: Cancel — dismissing")
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    DebugLog.tabs("BookmarkTargetPickerSheet: Add — parentID=\(selectedFolderID ?? "nil"), \(ids.count) items")
                    onConfirm(selectedFolderID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedFolderID == nil)
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .onAppear {
            DebugLog.tabs("BookmarkTargetPickerSheet: appeared — kind=\(kind.rawValue) count=\(ids.count)")
        }
    }

    // MARK: - Derived

    /// All folders, sorted by their full display path so siblings cluster
    /// under a shared parent prefix.
    private var folders: [BookmarkNode] {
        store.bookmarkNodes
            .filter { $0.kind == .folder }
            .sorted {
                path(for: $0) < path(for: $1)
            }
    }

    private var filteredFolders: [BookmarkNode] {
        guard !searchText.isEmpty else { return folders }
        return folders.filter {
            path(for: $0).localizedCaseInsensitiveContains(searchText)
        }
    }

    private func path(for node: BookmarkNode) -> String {
        BookmarkNode.displayPath(id: node.id, in: store.bookmarkNodes)
    }

    private var headerTitle: String {
        let noun: String
        let plural: String
        switch kind {
        case .pages: noun = "Page"; plural = "Pages"
        case .sources: noun = "Source"; plural = "Sources"
        case .chats: noun = "Conversation"; plural = "Conversations"
        }
        let count = ids.count
        let nounText = count == 1 ? noun : plural
        return "Add \(count == 1 ? "" : "\(count) ")\(nounText) to Bookmarks"
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search folders…", text: $searchText)
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
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Folder row (single-select)

    @ViewBuilder
    private func row(for folder: BookmarkNode) -> some View {
        let isSelected = selectedFolderID == folder.id
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.callout)
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(path(for: folder))
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFolderID = (isSelected ? nil : folder.id)
        }
    }

    // MARK: - Inline new-folder row

    private var newFolderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("New folder name", text: $newFolderName)
                .textFieldStyle(.plain)
                .font(.callout)
                .disableAutocorrection(true)
                .onSubmit(createFolder)
            Button("Create", action: createFolder)
                .buttonStyle(.bordered)
                .disabled(trimmedFolderName.isEmpty)
        }
    }

    private var trimmedFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createFolder() {
        let name = trimmedFolderName
        guard !name.isEmpty else { return }
        DebugLog.tabs("BookmarkTargetPickerSheet: createFolder — name=\(name)")
        if let newID = store.createFolder(parentID: nil, name: name) {
            selectedFolderID = newID
            newFolderName = ""
            searchText = ""
        }
    }
}
