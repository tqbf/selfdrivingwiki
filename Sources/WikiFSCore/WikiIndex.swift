import Foundation

/// The curated catalog document — a single, app-wide singleton (NOT a wiki page),
/// modeled EXACTLY on `SystemPrompt`. The managing agent rewrites it wholesale on
/// each ingest (via `wikictl index set`); the File Provider projection surfaces
/// its body read-only at the wiki root as `index.md`. Kept out of the `pages/`
/// namespace and distinct from the machine `indexes/*.jsonl`.
///
/// Persisted as one row in the `wiki_index` table (`id = 1`). Carries a `version`
/// (bumped on every write) so it folds into the whole-database `changeToken()`
/// sync anchor — editing ONLY the index must still advance the anchor or the
/// projected `index.md` would never refresh.
public struct WikiIndex: Equatable, Sendable {
    public var body: String
    public var updatedAt: Date
    public var version: Int

    public init(body: String, updatedAt: Date, version: Int) {
        self.body = body
        self.updatedAt = updatedAt
        self.version = version
    }

    /// Seeded into a fresh DB (the v4→5 migration) and used as the projection's
    /// fallback when the row/table can't be read (e.g. a read connection opened
    /// against a not-yet-migrated DB), so `index.md` always exists.
    public static let defaultBody: String = GeneratedPrompts.wikiIndexDefault
}
