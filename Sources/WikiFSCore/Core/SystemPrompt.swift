import Foundation

/// The system-prompt document — a single, app-wide singleton (NOT a wiki page).
/// It is the first thing the managing agent reads on every run: the File
/// Provider projection surfaces its body read-only at the wiki root as BOTH
/// `CLAUDE.md` and `AGENTS.md` (identical bytes), the two filenames the common
/// CLI agents look for.
///
/// As of v42, the prompt is **compiled-only** — it always comes from
/// ``defaultBody`` (which reads ``GeneratedPrompts/systemPromptDefault``).
/// The user-editable `system_prompt` SQLite table was removed; the prompt is
/// no longer editable in-app. A stable hash of the body drives the
/// ``ChangeToken`` fold so recompiles still advance the sync anchor.
public struct SystemPrompt: Equatable, Sendable {
    public var body: String
    public var updatedAt: Date
    public var version: Int

    public init(body: String, updatedAt: Date, version: Int) {
        self.body = body
        self.updatedAt = updatedAt
        self.version = version
    }

    /// The compiled default body — the ONLY source of truth for the system
    /// prompt. Generated from `prompts/system-prompt.md` by `tools/promptgen`
    /// at build time (`make prompts`).
    public static let defaultBody: String = GeneratedPrompts.systemPromptDefault
}
