import Foundation

/// A single editor tab. Each tab tracks which wiki content it displays and a
/// display label for the tab bar. `Hashable` + `Sendable` so it can live in the
/// `@Observable` store.
public struct EditorTab: Hashable, Sendable, Identifiable {
    /// Stable identity — survives selection changes within the tab.
    public let id: UUID
    /// The wiki content this tab is showing.
    public var selection: WikiSelection
    /// Display label in the tab bar (page title, "Query", "Instructions", etc.).
    public var title: String
    /// Whether the page editor was open when this tab was last focused.
    /// Persisted here so switching back to the tab restores edit mode.
    public var isEditing: Bool = false
    /// In-progress page draft stashed when the user switches away without saving.
    /// Non-nil only while `isEditing` and the user has unsaved changes.
    public var pendingDraftTitle: String? = nil
    public var pendingDraftBody: String? = nil

    public init(selection: WikiSelection, title: String) {
        self.id = UUID()
        self.selection = selection
        self.title = title
    }
}

extension WikiStoreModel {
    /// Display title for a `WikiSelection`, used as the tab bar label.
    /// Reads from the live `summaries` / `sources` arrays (rebuild from store
    /// after mutations, per SWIFTUI-RULES §3.1).
    public func tabTitle(for selection: WikiSelection) -> String {
        switch selection {
        case .ask: return "Ask"
        case .edit: return "Edit"
        case .systemPrompt: return "Instructions"
        case .changeLog: return "Activity"
        case .lint: return "Lint"
        case .page(let id):
            return summaries.first { $0.id == id }?.title
                .nonEmpty ?? "Untitled"
        case .source(let id):
            guard let source = sources.first(where: { $0.id == id }) else { return "Source" }
            return source.effectiveName.nonEmpty ?? "Source"
        case .bookmark(let id):
            return bookmarkNodes.first(where: { $0.id == id })?.label ?? "Bookmark"
        }
    }

    /// SF Symbol name for a `WikiSelection`, used as the tab icon.
    public func tabIcon(for selection: WikiSelection) -> String {
        switch selection {
        case .ask: return "bubble.left.and.text.bubble.right"
        case .edit: return "square.and.pencil"
        case .systemPrompt: return "sparkles"
        case .changeLog: return "clock.arrow.circlepath"
        case .lint: return "checkmark.shield"
        case .page: return "doc.text"
        case .source(let id):
            guard let source = sources.first(where: { $0.id == id }) else {
                return "doc"
            }
            if source.mimeType == "application/pdf" { return "doc.richtext" }
            if let mime = source.mimeType, mime.hasPrefix("text/") { return "doc.plaintext" }
            return "doc"
        case .bookmark: return "bookmark"
        }
    }
}

private extension String {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
