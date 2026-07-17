import Foundation

/// The user-editable "system prompt" document — a single, app-wide singleton
/// (NOT a wiki page). It is the first thing the managing agent reads on every
/// run: the File Provider projection surfaces its body read-only at the wiki
/// root as BOTH `CLAUDE.md` and `AGENTS.md` (identical bytes), the two filenames
/// the common CLI agents look for. The user edits it in the app; the projection
/// is read-only like everything else.
///
/// Persisted as one row in the `system_prompt` table (`id = 1`). Carries a
/// `version` (bumped on every edit) so it can fold into the whole-database
/// `changeToken()` sync anchor — editing ONLY the prompt must still advance the
/// anchor or the projected `CLAUDE.md`/`AGENTS.md` would never refresh.
public struct SystemPrompt: Equatable, Sendable {
    public var body: String
    public var updatedAt: Date
    public var version: Int

    public init(body: String, updatedAt: Date, version: Int) {
        self.body = body
        self.updatedAt = updatedAt
        self.version = version
    }

    /// Seeded into a fresh DB (the v2→3 migration) and used as the projection's
    /// fallback when the row/table can't be read (e.g. a read connection opened
    /// against a not-yet-migrated DB), so `CLAUDE.md`/`AGENTS.md` always exist.
    public static let defaultBody: String = GeneratedPrompts.systemPromptDefault
}
