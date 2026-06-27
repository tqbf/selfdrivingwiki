/// What the sidebar currently has selected. The sidebar is a single
/// `List(selection:)`, so its selection must be ONE `Hashable` type — this enum
/// unifies the singleton system-prompt document, wiki pages, and ingested files.
public enum WikiSelection: Hashable, Sendable {
    /// The read-only Ask conversation for the current wiki. The agent runs under
    /// a physically-enforced read-only seatbelt — it cannot write the wiki.
    case ask
    /// The Edit conversation for the current wiki. The agent may write the wiki
    /// (governed by the global sandbox toggle).
    case edit
    /// The user-editable system-prompt document (`CLAUDE.md` / `AGENTS.md`).
    case systemPrompt
    /// The append-only operation log (`log.md`).
    case changeLog
    /// Run a lint health-check on the wiki.
    case lint
    /// A wiki page, by id.
    case page(PageID)
    /// A raw source stored in the wiki, by id.
    case source(PageID)
}
