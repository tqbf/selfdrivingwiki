// pattern: Imperative Shell

import Foundation
import WikiFSCore
import WikiFSEngine

/// Owns the send lifecycle for the chat composer: optimistic echo state, the
/// XPC submit, the failure contract, and (compatibility surfaces only) the
/// draft-created transition. All effects are
/// injected as closures (the same wiring pattern as
/// `RemoteChatSession.installHistoryLoader`), which keeps the lifecycle
/// testable without a daemon.
///
/// The controller never removes a failed entry. A failed send stays visible in
/// the transcript until the view remounts; a later send never bulk-deletes it.
/// Retry is edit-and-resend.
@MainActor
@Observable
final class ChatOutgoingMessagesController {
    /// What a send carries, captured atomically at send time. `draftText` and
    /// `attachments` are the composer's original structured content — the
    /// failure restore puts those back, never the wire message with its
    /// inlined attachment references.
    struct OutgoingPayload: Equatable {
        let wireMessage: String
        let draftText: String
        let attachments: [ChatAttachment]
    }

    /// Atomic snapshot of the live composer at decision time. Restoration is
    /// allowed only when this is untouched, so a failure can never overwrite
    /// text or attachments the user added while the send was in flight.
    struct ComposerSnapshot: Equatable {
        let trimmedText: String
        let attachmentIDs: [String]

        var isUntouched: Bool {
            trimmedText.isEmpty && attachmentIDs.isEmpty
        }
    }

    struct Environment {
        let submit: @Sendable (ChatSubmitRequest) async throws -> ChatID
        /// Existing chats only: the reducer overlay renders the turn and its
        /// lifecycle side effects (flipping a cold projection live/queued) are
        /// load-bearing for run state and the queue/stop UI.
        let optimisticSubmit: @MainActor (ChatTurnSubmission) -> Void
        let optimisticSubmitFailed: @MainActor (ChatTurnID) -> Void
        /// Compatibility `.newChat` surfaces only. Durable chats are created
        /// before their tab exists, so the durable wiring leaves this nil and
        /// `completeSend` never transitions identity. A nil-ID submission
        /// (daemon creates the chat) needs the surface to follow the created
        /// chat, exactly like the pre-durable retarget.
        var chatCreated: (@MainActor (ChatID) -> Void)? = nil
        let readComposer: @MainActor () -> ComposerSnapshot
        let restoreDraft: @MainActor (String, [ChatAttachment]) -> Void
        let setPreflightError: @MainActor (String?) -> Void
    }

    /// Ignored by observation: the environment is fixed wiring, not state the
    /// view renders from.
    @ObservationIgnored private(set) var environment: Environment?
    private(set) var pendingOutgoing: [PendingOutgoingMessage] = []

    /// Idempotent. The `.id(chatID)` remount re-runs the caller's `onAppear`,
    /// which re-installs; in-flight tasks keep the environment they captured
    /// at send time, so a re-install cannot redirect them.
    func installEnvironment(_ environment: Environment) {
        self.environment = environment
    }

    /// Appends the `submitting` echo synchronously — before any await, so the
    /// message renders on the next frame — then runs the submit in a task.
    /// `makeRequest` receives the submission the controller built so the view
    /// can attach wiki, chat, and provider overrides without owning the turn
    /// identity the echo reconciles by.
    func send(
        chatID: ChatID?,
        payload: OutgoingPayload,
        makeRequest: (ChatTurnSubmission) -> ChatSubmitRequest
    ) {
        guard let environment else {
            // A send must never be a silent no-op.
            assertionFailure("ChatOutgoingMessagesController.send called before installEnvironment")
            DebugLog.agent("ChatOutgoingMessagesController.send ignored: no environment installed")
            return
        }
        let submission = ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: ULID.generate()),
            turnID: ChatTurnID(rawValue: ULID.generate()),
            userText: payload.wireMessage,
            contextReferences: [],
            submittedAt: Date()
        )
        pendingOutgoing.append(PendingOutgoingMessage(
            id: submission.turnID,
            status: .submitting,
            draftText: payload.draftText,
            wireMessage: payload.wireMessage,
            attachments: payload.attachments,
            submittedAt: submission.submittedAt
        ))
        DebugLog.agent(
            "ChatOutgoingMessagesController send accepted "
                + "(chat=\(chatID.map(\.rawValue) ?? "draft"), turn=\(submission.turnID.rawValue))"
        )
        if chatID != nil {
            environment.optimisticSubmit(submission)
        }
        let request = makeRequest(submission)
        Task { [weak self] in
            do {
                let resolvedChatID = try await environment.submit(request)
                self?.completeSend(
                    turnID: submission.turnID,
                    chatID: chatID,
                    resolvedChatID: resolvedChatID,
                    submittedAt: submission.submittedAt,
                    environment: environment
                )
            } catch {
                self?.failSend(
                    turnID: submission.turnID,
                    chatID: chatID,
                    error: error,
                    payload: payload,
                    environment: environment
                )
            }
        }
    }

    private func completeSend(
        turnID: ChatTurnID,
        chatID: ChatID?,
        resolvedChatID: ChatID,
        submittedAt: Date,
        environment: Environment
    ) {
        // Durable chats carry their `ChatID` from creation, so the
        // authoritative turn replaces the echo through the turnID filter and
        // the view never remounts onto a second identity — no retarget.
        // A legacy `chatID == nil` submission (compat draft surface) created
        // the chat daemon-side; the surface follows it via the compatibility
        // hook, and the `.id(chatID)` remount then discards this controller.
        if chatID == nil, let chatCreated = environment.chatCreated {
            chatCreated(resolvedChatID)
        }
        let elapsed = Date().timeIntervalSince(submittedAt)
        DebugLog.agent(
            "ChatOutgoingMessagesController submit completed "
                + "(chatID=\(resolvedChatID.rawValue), turn=\(turnID.rawValue), "
                + "created=\(chatID == nil ? "true" : "false"), "
                + "elapsed=\(String(format: "%.2f", elapsed))s)"
        )
    }

    private func failSend(
        turnID: ChatTurnID,
        chatID: ChatID?,
        error: Error,
        payload: OutgoingPayload,
        environment: Environment
    ) {
        let message = error.localizedDescription
        if let index = pendingOutgoing.firstIndex(where: { $0.id == turnID }) {
            pendingOutgoing[index].status = .failed(message: message)
        }
        if chatID != nil {
            environment.optimisticSubmitFailed(turnID)
        }
        environment.setPreflightError(message)
        // Conservative restore: never overwrite composer content the user
        // added while the send was in flight.
        if environment.readComposer().isUntouched {
            environment.restoreDraft(payload.draftText, payload.attachments)
        }
        DebugLog.agent(
            "ChatOutgoingMessagesController send failed "
                + "(chat=\(chatID.map(\.rawValue) ?? "draft"), turn=\(turnID.rawValue)): \(error)"
        )
    }
}

// MARK: - Queue transforms (pure, contract-pinned)

extension ChatOutgoingMessagesController {
    /// Builds a queued message that carries the structured composer content,
    /// so the queue-and-fire path supplies the identical restore contract as
    /// an immediate send.
    static func makePendingQueuedMessage(
        draftText: String,
        wireMessage: String,
        attachments: [ChatAttachment]
    ) -> PendingQueuedMessage {
        PendingQueuedMessage(
            wireMessage: wireMessage,
            preview: draftText,
            draftText: draftText,
            attachments: attachments
        )
    }

    /// Converts a queued message into the same payload shape `send` consumes.
    static func outgoingPayload(from pending: PendingQueuedMessage) -> OutgoingPayload {
        OutgoingPayload(
            wireMessage: pending.wireMessage,
            draftText: pending.draftText,
            attachments: pending.attachments
        )
    }

    /// Conservative queue restore: returns the queued draft only when the live
    /// composer is provably untouched, so a recall or edit can never overwrite
    /// text or attachments added after the message was queued.
    static func restoreQueuedMessage(
        _ pending: PendingQueuedMessage,
        composer: ComposerSnapshot
    ) -> (draftText: String, attachments: [ChatAttachment])? {
        guard composer.isUntouched else { return nil }
        return (pending.draftText, pending.attachments)
    }
}
