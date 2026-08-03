import Foundation

/// Lightweight page descriptor for the sidebar list. Identifiable + Hashable so
/// it drives a `List(selection:)` directly without an explicit `id:` keypath
/// (SWIFTUI-RULES §3.4 — identify rows by an immutable id, never by instance).
public struct WikiPageSummary: Identifiable, Hashable, Sendable {
    public let id: PageID
    public let title: String
    public let updatedAt: Date
    public let createdAt: Date

    public init(id: PageID, title: String, updatedAt: Date, createdAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}
