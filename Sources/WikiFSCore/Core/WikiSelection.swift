/// What the sidebar currently has selected. The sidebar is a single
/// `List(selection:)`, so its selection must be ONE `Hashable` type — this enum
/// unifies wiki pages and ingested files.
public enum WikiSelection: Hashable, Sendable {
    /// A compatibility draft composer with no persisted chat id (legacy
    /// navigation intent; omnibox bookmark-folder navigation still lands
    /// here). Durable new chats never use this state — `beginNewChat()`
    /// persists the row and opens `.chat(id)` directly. A legacy send from
    /// this surface retargets the tab in place to `.chat(id)`.
    case newChat
    /// The append-only operation log (`log.md`).
    case changeLog
    /// A wiki page, by id.
    case page(PageID)
    /// A raw source stored in the wiki, by id.
    case source(SourceID)
    /// A bookmark node (folder, page ref, source ref) — by node id. Selecting
    /// a bookmark folder highlights it but does not open a tab.
    case bookmark(String)
    /// A persisted agent chat, by id (issue #119).
    case chat(ChatID)
}
