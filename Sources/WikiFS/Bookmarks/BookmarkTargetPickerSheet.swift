import SwiftUI
import WikiFSCore

/// What kind of item a `BookmarkTargetPickerContext` carries. Distinct from
/// `ItemPickerKind` (which drives the folder-level "Add Page…/Add Source…"
/// browse-and-pick flow and has no chat case) — this one backs the "already
/// have the item(s), pick a destination folder" flow, which does support chats.
enum BookmarkRefKind: String, Sendable {
    case pages
    case sources
    case chats
}

/// Fixed item selection carried into the bookmark-target picker — the "inverse"
/// of `PickerContext`. Here the items are already chosen (a multi-row selection
/// from the Pages/Sources list, or the active chat) and the user picks the
/// destination folder.
struct BookmarkTargetPickerContext: Identifiable, Sendable {
    enum Targets: Sendable {
        case pages([PageID])
        case sources([SourceID])
        case chats([PageID])

        var kind: BookmarkRefKind {
            switch self {
            case .pages: .pages
            case .sources: .sources
            case .chats: .chats
            }
        }

        var count: Int {
            switch self {
            case .pages(let ids): ids.count
            case .sources(let ids): ids.count
            case .chats(let ids): ids.count
            }
        }
    }

    let id = UUID()
    let targets: Targets
}

/// The inverse of `ItemPickerSheet`: the item selection is fixed, and the user
/// picks (or creates) the destination bookmark folder. Confirming calls
/// `onConfirm` with the chosen folder's id (or `nil` for the bookmarks root),
/// and the caller creates one ref per selected item via
/// `WikiStoreModel.addPageRef` / `addSourceRef` / `addChatRef`.
///
/// Reads `store.bookmarkNodes` live so an inline "Create" folder shows up
/// immediately and auto-selects.
/// The picker's selection: the bookmarks root or a specific folder (`nil` =
/// deselected). Replaces a bare `String?` whose root was the
/// `"__bookmarks_root__"` sentinel — that sentinel shared a namespace with real
/// folder ids, so "is this the root?" was a comparison against a magic string
/// any call site could forget. The case tag makes root structurally distinct
/// from any folder id, so the question is asked by the type, not remembered.
enum BookmarkFolderSelection: Hashable {
    /// The bookmarks root (`parentID == nil`) — top-level destination.
    case root
    /// A real bookmark folder, by its `BookmarkNode.id`.
    case folder(String)
}

struct BookmarkTargetPickerSheet: View {
    @Bindable var store: WikiStoreModel
    let targets: BookmarkTargetPickerContext.Targets
    /// Receives the chosen destination folder id (`nil` = bookmarks root).
    /// Main-actor: the caller touches the @MainActor WikiStoreModel.
    let onConfirm: (@MainActor @Sendable (String?) -> Void)

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    /// Pre-selected to the bookmarks root so "Add" is enabled immediately,
    /// even in a wiki with no folders yet (#243). `nil` means deselected.
    @State private var selection: BookmarkFolderSelection? = .root
    @State private var newFolderName: String = ""

    /// Converts the selection to the `parentID` value expected by `onConfirm`
    /// — the root and a deselected picker both map to `nil` (top level).
    /// Exposed for testing (#243).
    static func parentID(forSelection selection: BookmarkFolderSelection?) -> String? {
        guard let selection else { return nil }
        switch selection {
        case .root: return nil
        case .folder(let id): return id
        }
    }

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
                    rootRow
                    if !filteredFolders.isEmpty {
                        Divider()
                            .padding(.vertical, 2)
                    }
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
                Text("\(targets.count) item\(targets.count == 1 ? "" : "s") will be added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    DebugLog.tabs("BookmarkTargetPickerSheet: Cancel — dismissing")
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let parentID = Self.parentID(forSelection: selection)
                    DebugLog.tabs("BookmarkTargetPickerSheet: Add — parentID=\(parentID ?? "nil"), \(targets.count) items")
                    onConfirm(parentID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .onAppear {
            DebugLog.tabs("BookmarkTargetPickerSheet: appeared — kind=\(targets.kind.rawValue) count=\(targets.count)")
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
        switch targets.kind {
        case .pages: noun = "Page"; plural = "Pages"
        case .sources: noun = "Source"; plural = "Sources"
        case .chats: noun = "Chat"; plural = "Chats"
        }
        let count = targets.count
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

    // MARK: - Root row (top-level destination)

    /// A pinned row representing the bookmarks root (`parentID == nil`),
    /// so the user can bookmark to the top level without first creating a
    /// folder. Selectable like any folder row (#243).
    @ViewBuilder
    private var rootRow: some View {
        let isSelected = selection == .root
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.callout)
            Image(systemName: "bookmarks")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text("Bookmarks")
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = (isSelected ? nil : .root)
        }
    }

    // MARK: - Folder row (single-select)

    @ViewBuilder
    private func row(for folder: BookmarkNode) -> some View {
        let isSelected = selection == .folder(folder.id)
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
            selection = (isSelected ? nil : .folder(folder.id))
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
            selection = .folder(newID)
            newFolderName = ""
            searchText = ""
        }
    }
}
