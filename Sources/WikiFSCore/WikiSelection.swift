/// What the sidebar currently has selected. The sidebar is a single
/// `List(selection:)`, so its selection must be ONE `Hashable` type — this enum
/// unifies the singleton system-prompt document, wiki pages, and ingested files.
public enum WikiSelection: Hashable, Sendable {
    /// The user-editable system-prompt document (`CLAUDE.md` / `AGENTS.md`).
    case systemPrompt
    /// The append-only operation log (`log.md`).
    case changeLog
    /// A wiki page, by id.
    case page(PageID)
    /// A raw source file stored in the wiki, by id.
    case ingestedFile(PageID)
}
