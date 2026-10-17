import SwiftUI
import WikiFSCore

/// The chat composer's attachment chips, as one observable model with a
/// persistence binding. When bound to a store + chat, every mutation
/// (add/remove/replace/clear/applyTargets) writes the chip set through to
/// `chat_attachments` via `WikiStoreModel.setChatAttachments`, so chips
/// survive tab close and app restart. Unbound (or bound to the legacy draft
/// surface, `chatID == nil`), the model behaves exactly like the former
/// plain array: local state, no persistence.
///
/// The binding lifecycle is ONE operation per mount:
///   1. `bind(store:chatID:)` — disarms persistence and records the target.
///   2. `restoreFromStore()` — reads the persisted targets and applies them
///      as ONE deduped batch while persistence is still disarmed (a mount is
///      one read and zero writes).
///   3. `armPersistence()` — arms write-through for later mutations.
///
/// Hosted tests assert the real chip contents through
/// `ChatDetailView.onComposerPanePropsBuilt` (the value this model feeds
/// into `ChatComposerPaneProps.attachments`), not through AppKit-tree
/// introspection.
///
/// API shape notes:
/// - `add` dedupes by chip id (the former `addAttachment` rule) and keeps
///   insertion order.
/// - `replace(with:)` swaps the whole array — the failed-send restore and
///   the queued recall/edit restores swap the composer's chips for a
///   captured set; appending would duplicate them.
/// - `applyTargets` is one deduped batch assignment with ONE persistence
///   call (never one write per target).
@Observable
@MainActor
final class ChatComposerAttachmentModel {
    private(set) var attachments: [ChatAttachment] = []

    private weak var boundStore: WikiStoreModel?
    private(set) var boundChatID: ChatID?
    private(set) var isPersistenceArmed = false

    /// Bind the model to a chat. `chatID == nil` (the legacy `.newChat`
    /// draft surface) never persists; local chips are kept. Binding disarms
    /// persistence — the mount restores first and arms afterwards.
    func bind(store: WikiStoreModel, chatID: ChatID?) {
        isPersistenceArmed = false
        boundStore = store
        boundChatID = chatID
    }

    /// Apply the chat's persisted targets as one deduped batch. Nonpersisting
    /// by design: persistence is disarmed until `armPersistence()`.
    func restoreFromStore() {
        guard !isPersistenceArmed, let store = boundStore, let chatID = boundChatID else { return }
        let targets = store.chatAttachments(chatID: chatID)
        applyTargets(targets, store: store)
    }

    /// Arm write-through. A no-op for the unbound or draft-surface model.
    func armPersistence() {
        guard boundChatID != nil, boundStore != nil else { return }
        isPersistenceArmed = true
    }

    /// Add a chip unless an equal one is already present.
    func add(_ attachment: ChatAttachment) {
        guard !attachments.contains(attachment) else { return }
        attachments.append(attachment)
        persistCurrentState()
    }

    /// Swap the whole chip list for `newAttachments` (queued restore path).
    func replace(with newAttachments: [ChatAttachment]) {
        guard attachments != newAttachments else { return }
        attachments = newAttachments
        persistCurrentState()
    }

    /// Remove the chip matching `attachment`'s identity.
    func remove(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        persistCurrentState()
    }

    /// Remove every chip (send and queue paths).
    func clear() {
        guard !attachments.isEmpty else { return }
        attachments = []
        persistCurrentState()
    }

    /// Map the typed targets through the typed adapter and apply them as one
    /// deduped batch — one persistence call, never one write per target.
    func applyTargets(_ targets: [ChatAttachmentTarget], store: WikiStoreModel) {
        var next = attachments
        for target in targets {
            let chip = ChatAttachment(target: target, store: store)
            guard !next.contains(chip) else { continue }
            next.append(chip)
        }
        replace(with: next)
    }

    /// Write the current chip set through to the chat's persisted targets.
    /// Failures are logged and surfaced non-fatally: the in-memory chips stay
    /// authoritative and the next mutation retries the write.
    private func persistCurrentState() {
        guard isPersistenceArmed, let store = boundStore, let chatID = boundChatID else { return }
        store.setChatAttachments(
            chatID: chatID,
            targets: attachments.map(\.attachmentTarget))
    }
}

extension ChatAttachment {
    /// The persistence-boundary conversion: chip identity (kind + raw id)
    /// re-typed as a target. Raw strings are the SQLite contract; this is the
    /// app-layer conversion point.
    var attachmentTarget: ChatAttachmentTarget {
        switch kind {
        case .page: return .page(PageID(rawValue: itemID))
        case .source: return .source(SourceID(rawValue: itemID))
        case .chat: return .chat(ChatID(rawValue: itemID))
        }
    }
}
