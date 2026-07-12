import SwiftUI
import WikiFSCore

/// What kind of item the picker shows.
enum ItemPickerKind: String {
    case pages
    case sources
}

/// A search-and-select sheet for adding page or source references to a folder.
/// Shows all items with a simple text filter — no semantic search needed for a
/// picker. Multi-select with an "Add" button.
struct ItemPickerSheet: View {
    /// All items, pre-snapshotted by the caller (no live store observation).
    let allItems: [PickerItem]
    let onConfirm: ([PageID]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var selectedIDs: Set<PageID> = []

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            searchBar
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredItems) { item in
                        row(for: item)
                    }
                    if filteredItems.isEmpty {
                        Text(searchText.isEmpty ? "No items available" : "No results")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Divider()

            HStack {
                Text("\(selectedIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    DebugLog.tabs("ItemPickerSheet: Cancel button — dismissing")
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    DebugLog.tabs("ItemPickerSheet: Add button — \(selectedIDs.count) items, calling onConfirm")
                    onConfirm(Array(selectedIDs))
                    DebugLog.tabs("ItemPickerSheet: onConfirm done, dismissing")
                    dismiss()
                    DebugLog.tabs("ItemPickerSheet: dismiss() called")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .onAppear {
            DebugLog.tabs("ItemPickerSheet: appeared — \(allItems.count) items")
        }
        .onDisappear {
            DebugLog.tabs("ItemPickerSheet: disappeared")
        }
    }

    private var title: String {
        allItems.first?.isPage == true ? "Add Pages" : "Add Sources"
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Search…", text: $searchText)
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

    // MARK: - Results

    /// Simple case-insensitive text filter — instant, no ML inference.
    private var filteredItems: [PickerItem] {
        guard !searchText.isEmpty else { return allItems }
        return allItems.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    @ViewBuilder
    private func row(for item: PickerItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .font(.callout)
            Image(systemName: item.isPage ? ResourceKind.page.systemImageName : ResourceKind.source.systemImageName)
                .foregroundStyle(.secondary)
                .font(.callout)
            Text(item.title)
                .font(.callout)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        }
    }
}

/// A flat item used by the picker — just an id + label + kind.
struct PickerItem: Identifiable, Hashable {
    let id: PageID
    let title: String
    let isPage: Bool
}
