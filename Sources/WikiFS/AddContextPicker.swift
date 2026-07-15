import SwiftUI
import WikiFSCore

/// The composer's "+" add-context button: a compact chip that opens a native
/// popover with a search field over a flat list of the wiki's pages, sources,
/// and chats. Selecting a row attaches it as context for the next message —
/// the click-to-add counterpart to the sidebar drag-and-drop path (issue #385).
///
/// Modeled on `ProviderSelector` / `PermissionModeSelector` so it reads as a
/// sibling chip in the composer toolbar: a glyph trigger, a searchable popover,
/// hover-highlighted rows. It emits a `SidebarDragPayload` (the app's existing
/// attach currency) via `onAdd`, so `ChatView` builds the `ChatAttachment` with
/// the same code that a sidebar drop uses.
struct AddContextPicker: View {
    @Bindable var store: WikiStoreModel
    /// Called with the selected item's payload. The composer turns it into a
    /// `ChatAttachment` and appends it (de-duplicating).
    let onAdd: (SidebarDragPayload) -> Void

    @State private var isPresented = false
    @State private var searchText = ""
    @State private var hoveredID: String?

    /// Cap the unfiltered list so a large wiki doesn't render thousands of rows
    /// before the user has typed anything to narrow it.
    private static let unfilteredLimit = 50

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            popoverContent
        }
        .help("Add a page, source, or chat as context")
    }

    // MARK: - Row model

    private struct Item: Identifiable {
        let kind: SidebarDragPayload.Kind
        let itemID: String
        let name: String

        var id: String { "\(kind.rawValue):\(itemID)" }

        var glyph: String {
            switch kind {
            case .page:   return "doc.text"
            case .source: return "doc"
            case .chat:   return "bubble.left.and.bubble.right"
            }
        }

        var kindLabel: String {
            switch kind {
            case .page:   return "Page"
            case .source: return "Source"
            case .chat:   return "Chat"
            }
        }

        var payload: SidebarDragPayload {
            SidebarDragPayload(kind: kind, id: itemID)
        }
    }

    /// Every attachable item in the wiki (pages + sources + chats), unfiltered.
    private var allItems: [Item] {
        let pages = store.summaries.map {
            Item(kind: .page, itemID: $0.id.rawValue, name: $0.title)
        }
        let sources = store.sources
            .filter(\.isPrimary)
            .map { Item(kind: .source, itemID: $0.id.rawValue, name: $0.effectiveName) }
        let chats = store.chats.map {
            Item(kind: .chat, itemID: $0.id.rawValue, name: $0.title)
        }
        return pages + sources + chats
    }

    /// Items after the search filter. Empty query shows a capped prefix so the
    /// popover stays snappy; a query matches on the display name.
    private var filteredItems: [Item] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Array(allItems.prefix(Self.unfilteredLimit)) }
        return allItems.filter { $0.name.lowercased().contains(query) }
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            itemList
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
            TextField("Search pages, sources, and chats", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if filteredItems.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ForEach(filteredItems) { item in
                        row(item)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: listHeight)
    }

    /// Hug the rows up to a cap so a short list makes a short popover.
    private var listHeight: CGFloat {
        let rowHeight: CGFloat = 34
        let count = max(filteredItems.count, 1)
        return min(CGFloat(count) * rowHeight + 8, 360)
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.glyph)
                .frame(width: 16)
                .foregroundStyle(Color.blue)
            Text(item.name)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.kindLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hoveredID == item.id ? Color.primary.opacity(0.08) : .clear)
                .padding(.horizontal, 4)
        )
        .onHover { inside in
            if inside { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
        }
        .onTapGesture { select(item) }
    }

    private func select(_ item: Item) {
        onAdd(item.payload)
        isPresented = false
        searchText = ""
    }
}
