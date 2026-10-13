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

    /// Map an ordered page selection to targets, preserving row order.
    public static func pages(_ ids: [PageID]) -> [ChatAttachmentTarget] {
        ids.map { .page($0) }
    }

    /// Map an ordered source selection to targets, preserving row order.
    public static func sources(_ ids: [SourceID]) -> [ChatAttachmentTarget] {
        ids.map { .source($0) }
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
