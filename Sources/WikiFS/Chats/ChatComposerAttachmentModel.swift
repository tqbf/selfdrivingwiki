import SwiftUI
import WikiFSCore

/// The chat composer's attachment chips, as one observable model.
///
/// Extracted from `ChatDetailView`'s former `@State attachments` array so the
/// chip list has a single owner with a small, explicit API — and so hosted
/// tests can assert the real chip contents through
/// `ChatDetailView.onComposerPanePropsBuilt` (the value this model feeds into
/// `ChatComposerPaneProps.attachments`), not through AppKit-tree introspection.
///
/// API shape notes:
/// - `add` dedupes by chip id (the former `addAttachment` rule) and preserves
///   insertion order.
/// - `replace(with:)` swaps the whole array — the queued recall and edit
///   restores swap the composer's chips for the queued message's captured
///   set; appending would duplicate them.
/// - `applyTargets` maps typed `ChatAttachmentTarget`s through the one
///   String-boundary adapter (`ChatAttachment.init(target:store:)`).
@Observable
@MainActor
final class ChatComposerAttachmentModel {
    private(set) var attachments: [ChatAttachment] = []

    /// Add a chip unless an equal one is already present.
    func add(_ attachment: ChatAttachment) {
        guard !attachments.contains(attachment) else { return }
        attachments.append(attachment)
    }

    /// Swap the whole chip list for `newAttachments` (queued restore path).
    func replace(with newAttachments: [ChatAttachment]) {
        attachments = newAttachments
    }

    /// Remove the chip matching `attachment`'s identity.
    func remove(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// Remove every chip (send and queue paths).
    func clear() {
        attachments = []
    }

    /// Map the typed targets of a pending chat-attachment request to chips
    /// through the typed adapter, adding each in order with the usual dedupe.
    func applyTargets(_ targets: [ChatAttachmentTarget], store: WikiStoreModel) {
        for target in targets {
            add(ChatAttachment(target: target, store: store))
        }
    }
}
