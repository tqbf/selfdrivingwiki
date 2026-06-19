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

    public init(selection: WikiSelection, title: String) {
        self.id = UUID()
        self.selection = selection
        self.title = title
    }
}

extension WikiStoreModel {
    /// Display title for a `WikiSelection`, used as the tab bar label.
    /// Reads from the live `summaries` / `ingestedFiles` arrays (rebuild from store
    /// after mutations, per SWIFTUI-RULES §3.1).
    public func tabTitle(for selection: WikiSelection) -> String {
        switch selection {
        case .query: return "Query"
        case .systemPrompt: return "Instructions"
        case .changeLog: return "Activity"
        case .page(let id):
            return summaries.first { $0.id == id }?.title
                .nonEmpty ?? "Untitled"
        case .ingestedFile(let id):
            return ingestedFiles.first { $0.id == id }?.filename
                .nonEmpty ?? "File"
        }
    }

    /// SF Symbol name for a `WikiSelection`, used as the tab icon.
    public func tabIcon(for selection: WikiSelection) -> String {
        switch selection {
        case .query: return "bubble.left.and.text.bubble.right"
        case .systemPrompt: return "sparkles"
        case .changeLog: return "clock.arrow.circlepath"
        case .page: return "doc.text"
        case .ingestedFile(let id):
            guard let file = ingestedFiles.first(where: { $0.id == id }) else {
                return "doc"
            }
            switch file.ext.lowercased() {
            case "pdf": return "doc.richtext"
            case "txt", "md", "markdown": return "doc.plaintext"
            default: return "doc"
            }
        }
    }
}

private extension String {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
