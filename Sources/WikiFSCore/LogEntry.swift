import Foundation

/// One row of the append-only chronological `log` (Phase B). The managing agent
/// appends an entry per operation (an ingest, a query, a lint), and the File
/// Provider projection renders the whole table read-only at the wiki root as
/// `log.md` — one grep-able line per entry.
///
/// Unlike the `system_prompt` / `wiki_index` singletons, `log` is a normal
/// many-row table: each `wikictl log append` inserts a fresh ULID-keyed row
/// (`id` is sortable == chronological), so it never UPSERTs and never bumps a
/// per-row version. `changeToken()` folds in the row COUNT instead (see
/// `SQLiteWikiStore.changeToken()`).
public struct LogEntry: Equatable, Sendable {
    public var id: PageID
    public var timestamp: Date
    public var kind: Kind
    public var title: String
    public var note: String?

    public init(id: PageID, timestamp: Date, kind: Kind, title: String, note: String?) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.note = note
    }

    /// The operation that produced a log entry. A closed set (the three
    /// agent operations) so `wikictl log append --kind …` can validate its
    /// argument and the rendered `log.md` lines are predictable to `grep`.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case ingest
        case query
        case lint
    }
}
