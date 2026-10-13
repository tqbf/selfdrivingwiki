import Foundation

/// A typed attachment target for a chat composer chip: one sidebar row the
/// user wants the agent to see. The case tag keeps the `PageID` and
/// `SourceID` namespaces apart (see `BookmarkNode.Content` for the same
/// mixed-target pattern), so a page id and a source id with identical raw
/// text can never compare equal.
///
/// This is model-layer state; it crosses `beginNewChat(attachments:)` and the
/// one-shot `PendingChatAttachmentRequest` hand-off. The app layer converts a
/// target to a composer chip in exactly one place (`ChatAttachment.init(
/// target:store:)`); pasteboard transport stays `SidebarDragPayload`, whose
/// raw-String ids are an external-format compatibility contract.
public enum ChatAttachmentTarget: Hashable, Sendable {
    /// A page row from the `pages` table.
    case page(PageID)
    /// A source row from the `sources` table.
    case source(SourceID)
    /// A chat row from the `chats` table (attachable from the context picker
    /// and by dropping a Chats-list row).
    case chat(ChatID)

    /// Map an ordered page selection to targets, preserving row order.
    public static func pages(_ ids: [PageID]) -> [ChatAttachmentTarget] {
        ids.map { .page($0) }
    }

    /// Map an ordered source selection to targets, preserving row order.
    public static func sources(_ ids: [SourceID]) -> [ChatAttachmentTarget] {
        ids.map { .source($0) }
    }

    /// The SQLite `chat_attachments.kind` tag (persistence boundary).
    public var kindTag: String {
        switch self {
        case .page: return "page"
        case .source: return "source"
        case .chat: return "chat"
        }
    }

    /// The SQLite `chat_attachments.raw_id` text (persistence boundary).
    public var rawID: String {
        switch self {
        case .page(let id): return id.rawValue
        case .source(let id): return id.rawValue
        case .chat(let id): return id.rawValue
        }
    }

    /// Checked decode of a `chat_attachments` row. An unknown tag throws —
    /// a silently skipped chip would be indistinguishable from data loss.
    public static func decode(
        kindTag: String, rawID: String
    ) throws -> ChatAttachmentTarget {
        switch kindTag {
        case "page": return .page(PageID(rawValue: rawID))
        case "source": return .source(SourceID(rawValue: rawID))
        case "chat": return .chat(ChatID(rawValue: rawID))
        default:
            throw WikiStoreError.unexpected(
                "chat_attachments: unknown kind tag '\(kindTag)'")
        }
    }
}

/// The one-shot hand-off from `WikiStoreModel.beginNewChat(attachments:)` to
/// the chat surface: the chat the request belongs to, plus the typed targets
/// to attach to its composer. The chatID makes consumption chat-scoped — a
/// request can only ever be applied by its own chat's first mount.
public struct PendingChatAttachmentRequest: Equatable, Sendable {
    /// The chat this request was created for.
    public let chatID: ChatID
    /// The ordered attachment targets for that chat's composer.
    public let targets: [ChatAttachmentTarget]

    public init(chatID: ChatID, targets: [ChatAttachmentTarget]) {
        self.chatID = chatID
        self.targets = targets
    }
}
