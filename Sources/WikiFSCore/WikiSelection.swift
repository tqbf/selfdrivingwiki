/// What the sidebar currently has selected. The sidebar is a single
/// `List(selection:)`, so its selection must be ONE `Hashable` type — this enum
/// unifies the singleton system-prompt document, wiki pages, and ingested files.
public enum WikiSelection: Hashable, Sendable {
    /// A new-chat composer with no persisted chat id yet (the draft tab state).
    /// The first send retargets the tab in place to `.chat(id)`.
    case newChat
    /// The user-editable system-prompt document (`CLAUDE.md` / `AGENTS.md`).
    case systemPrompt
    /// The append-only operation log (`log.md`).
    case changeLog
    /// A wiki page, by id.
    case page(PageID)
    /// A raw source stored in the wiki, by id.
    case source(PageID)
    /// A bookmark node (folder, page ref, source ref) — by node id. Selecting
    /// a bookmark folder highlights it but does not open a tab.
    case bookmark(String)
    /// A persisted agent chat, by id (issue #119).
    case chat(PageID)
}
