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
/// `GRDBWikiStore.changeToken()`).
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

    /// The operation that produced a log entry. A closed set so `wikictl log
    /// append --kind …` can validate its argument and rendered `log.md` lines
    /// remain predictable to `grep`.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case ingest
        case query
        case lint
        /// A tracked-repository pass — the wiki being brought up to date with new
        /// commits. Distinct from `.ingest` (a one-shot source) so `log.md` can be
        /// grepped for "when was this repo last covered, and through which commit".
        case repo

        /// The `a|b|c` list used in the CLI's usage/validation text and the
        /// on-mount cheatsheets, derived from the cases so it can never drift.
        public static var optionList: String {
            allCases.map(\.rawValue).joined(separator: "|")
        }
    }
}
