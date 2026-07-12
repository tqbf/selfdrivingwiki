import Foundation

/// A unified search result from the omnibox — wraps any resource type the
/// omnibox can search across (pages, sources, chats, bookmarks), plus a
/// special "Ask" action that sends the query straight to a new chat (#288).
///
/// Each case provides `displayTitle`, `systemImageName`, and a `selection`
/// (`WikiSelection` for navigation). The `ask` case carries the raw query
/// string and resolves to `.newChat`.
public enum OmniboxResult: Identifiable, Hashable, Sendable {
    case page(WikiPageSummary)
    case source(SourceSummary)
    case chat(ChatSummary)
    case bookmark(node: BookmarkNode, resolvedTitle: String)
    /// A direct-to-chat "Ask" action — opens a new chat with the query
    /// pre-filled in the composer, so the user can hit Enter to send (#288).
    case ask(question: String)

    // MARK: - Identifiable

    public var id: String {
        switch self {
        case .page(let p): return "page:\(p.id.rawValue)"
        case .source(let s): return "source:\(s.id.rawValue)"
        case .chat(let c): return "chat:\(c.id.rawValue)"
        case .bookmark(let node, _): return "bookmark:\(node.id)"
        case .ask: return "ask"
        }
    }

    // MARK: - Display

    public var displayTitle: String {
        switch self {
        case .page(let p): return p.title
        case .source(let s): return s.effectiveName
        case .chat(let c): return c.title
        case .bookmark(_, let title): return title
        case .ask(let question): return "Ask: \(question)"
        }
    }

    public var systemImageName: String {
        switch self {
        case .page: return ResourceKind.page.systemImageName
        case .source: return ResourceKind.source.systemImageName
        case .chat: return ResourceKind.chat.systemImageName
        case .bookmark: return ResourceKind.bookmark.systemImageName
        case .ask: return "sparkles"
        }
    }

    /// A subtitle/metadata line shown below the title in Safari-style rows.
    public var subtitle: String {
        switch self {
        case .page: return "Page"
        case .source: return "Source"
        case .chat(let c): return c.messageCount == 1 ? "1 message" : "\(c.messageCount) messages"
        case .bookmark: return "Bookmark"
        case .ask: return "Send to chat"
        }
    }

    // MARK: - Navigation

    public var selection: WikiSelection {
        switch self {
        case .page(let p): return .page(p.id)
        case .source(let s): return .source(s.id)
        case .chat(let c): return .chat(c.id)
        case .bookmark(let node, _):
            // Bookmarks navigate to their target, not the bookmark node itself.
            switch node.kind {
            case .pageRef: return node.targetID.map { .page($0) } ?? .newChat
            case .sourceRef: return node.targetID.map { .source($0) } ?? .newChat
            case .chatRef: return node.targetID.map { .chat($0) } ?? .newChat
            case .folder: return .newChat // Folders aren't navigable
            }
        case .ask: return .newChat
        }
    }

    /// Whether this result is a real resource navigation (vs. an action like Ask).
    public var isAction: Bool {
        if case .ask = self { return true }
        return false
    }
}
