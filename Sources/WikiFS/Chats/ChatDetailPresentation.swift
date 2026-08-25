// pattern: Functional Core

import Foundation
import WikiFSEngine
import WikiFSCore

struct ChatDetailPresentation {
    enum ContentState: Equatable {
        case internals
        case loadingChat
        case deletedChat
        case failedToLoadChat(String)
        case chatSurface
    }

    struct RemoteState {
        let runState: ChatRunState
        let sessionChatID: ChatID?
        let runningKind: WikiOperation.Kind?
        let preflightError: String?
        let pendingPermissions: [PendingPermission]
        let runStartedAt: Date?
        let transcript: ChatDisplayTranscript
        let exitStatus: Int32?

    }

    struct Controls {
        let showsDebugControls: Bool
    }

    struct Transcript {
        let displayTranscript: ChatDisplayTranscript
        let emptyStateMessage: String
        let isAnswering: Bool
    }

    struct Composer {
        let isEnabled: Bool
        let caption: String?
        let canSend: Bool
        let sendButtonTitle: String
        let showsStopButton: Bool
        let showsQueueButton: Bool
    }

    let contentState: ContentState
    let controls: Controls
    let transcript: Transcript
    let composer: Composer
    let livePendingPermission: PendingPermission?
    let preflightBannerMessage: String?
    let showsThinkingIndicator: Bool
    let outlineEntries: [ChatOutlineEntry]
    let chatInspectorAvailable: Bool

    static func make(
        chatID: ChatID?,
        chatResolution: ChatResolution?,
        showsInternals: Bool,
        remoteSession: RemoteState,
        persistedTranscriptItems: [PersistedChatTranscriptItem],
        queuedMessages: [PendingQueuedMessage],
        hasDraftText: Bool,
        isChatOperationConfigured: Bool
    ) -> Self {
        let isLiveChat = chatID.map {
            remoteSession.sessionChatID == $0 && remoteSession.runState.isLive
        } ?? false
        let displayTranscript = isLiveChat
            ? remoteSession.transcript
            : ChatDisplayProjection.project(
                items: persistedTranscriptItems.map(\.item),
                activeContentBlock: nil
            ).transcript
        let controls = Controls(
            showsDebugControls: showsDebugControls(
                runState: remoteSession.runState,
                runningKind: remoteSession.runningKind
            )
        )
        let transcriptIsAnswering = transcriptIsAnswering(
            isLiveChat: isLiveChat,
            runState: remoteSession.runState
        )
        let composerEnabled = isComposerEnabled(
            chatID: chatID,
            isLiveChat: isLiveChat,
            remoteSession: remoteSession,
            isChatOperationConfigured: isChatOperationConfigured
        )
        let canSend = canSendPredicate(
            hasMount: true,
            runState: remoteSession.runState,
            hasDraftText: hasDraftText,
            isChatOperationConfigured: isChatOperationConfigured
        )
        let outlineEntries = buildOutlineEntries(
            displayTranscript: displayTranscript,
            cachedResponseSummaries: isLiveChat
                ? [:]
                : cachedResponseSummaries(from: persistedTranscriptItems)
        )
        let contentState: ContentState
        if showsInternals && controls.showsDebugControls {
            contentState = .internals
        } else if chatID != nil && !isLiveChat {
            switch chatResolution {
            case .available:
                contentState = .chatSurface
            case .notFound:
                contentState = .deletedChat
            case .failed(let message):
                contentState = .failedToLoadChat(message)
            case nil:
                contentState = .loadingChat
            }
        } else {
            contentState = .chatSurface
        }

        return Self(
            contentState: contentState,
            controls: controls,
            transcript: Transcript(
                displayTranscript: displayTranscript,
                emptyStateMessage: transcriptEmptyMessage(chatID: chatID, isLiveChat: isLiveChat),
                isAnswering: transcriptIsAnswering
            ),
            composer: Composer(
                isEnabled: composerEnabled,
                caption: composerCaptionText(
                    runState: remoteSession.runState,
                    hasChatID: chatID != nil,
                    isLiveChat: isLiveChat,
                    isChatOperationConfigured: isChatOperationConfigured
                ),
                canSend: canSend,
                sendButtonTitle: sendButtonTitle(
                    remoteSession: remoteSession,
                    queuedMessages: queuedMessages
                ),
                showsStopButton: showsStopButton(
                    runState: remoteSession.runState,
                    runningKind: remoteSession.runningKind
                ),
                showsQueueButton: showsQueueButton(
                    runState: remoteSession.runState,
                    runningKind: remoteSession.runningKind,
                    queuedMessages: queuedMessages
                )
            ),
            livePendingPermission: livePendingPermission(
                isLiveChat: isLiveChat,
                pendingPermissions: remoteSession.pendingPermissions
            ),
            preflightBannerMessage: preflightBannerMessage(
                preflightError: remoteSession.preflightError,
                chatID: chatID,
                isLiveChat: isLiveChat
            ),
            showsThinkingIndicator: transcriptIsAnswering,
            outlineEntries: outlineEntries,
            chatInspectorAvailable: !outlineEntries.isEmpty
        )
    }

    static func transcriptEmptyMessage(chatID: ChatID?, isLiveChat: Bool) -> String {
        if chatID == nil {
            return "Ask a question, or ask the Agent to update the wiki…"
        }
        return isLiveChat ? "Ask a question to start a chat." : "No messages were persisted for this chat."
    }

    static func transcriptIsAnswering(isLiveChat: Bool, runState: ChatRunState) -> Bool {
        isLiveChat && runState.isAnswering
    }

    static func showsDebugControls(
        runState: ChatRunState,
        runningKind: WikiOperation.Kind?
    ) -> Bool {
        (runState.isAnswering || runState == .queued) && runningKind == .query
    }

    static func livePendingPermission(
        isLiveChat: Bool,
        pendingPermissions: [PendingPermission]
    ) -> PendingPermission? {
        guard isLiveChat else { return nil }
        return pendingPermissions.first
    }

    static func buildOutlineEntries(
        displayTranscript: ChatDisplayTranscript,
        cachedResponseSummaries: [ChatMessageID: String] = [:]
    ) -> [ChatOutlineEntry] {
        displayTranscript.sections.compactMap { section -> ChatOutlineEntry? in
            guard case .turn(let turn) = section,
                  let prompt = turn.prompt else { return nil }
            let response = turn.rows.first { row in
                if case .assistantMessage = row { return true }
                return false
            }
            let cachedSummary: String?
            if case .assistantMessage(let responseID, _, _, _, _) = response {
                cachedSummary = cachedResponseSummaries[responseID]
            } else {
                cachedSummary = nil
            }
            let summary = cachedSummary ?? response.map {
                ChatSummary.summaryExtract(from: $0.textForSearch, maxLength: 200)
            }
            return ChatOutlineEntry(
                id: .turn(turnID: turn.turnID, promptRowID: prompt.id),
                question: humanizeAttachmentRefs(in: prompt.textForSearch),
                response: summary.flatMap { $0.isEmpty ? nil : $0 },
                questionTimestamp: prompt.timestamp,
                responseTimestamp: response?.timestamp
            )
        }
    }

    /// Summary cache and display row identity meet only at the persisted
    /// transcript boundary. `cachedResponseSummary` was joined by cursor/seq;
    /// this extracts the transcript message ID from that same row rather than
    /// converting the unrelated compatibility `chat_messages.id` namespace.
    private static func cachedResponseSummaries(
        from persistedItems: [PersistedChatTranscriptItem]
    ) -> [ChatMessageID: String] {
        var summaries: [ChatMessageID: String] = [:]
        for persistedItem in persistedItems {
            guard let summary = persistedItem.cachedResponseSummary,
                  case .message(let message) = persistedItem.item,
                  message.role == .assistant
            else { continue }
            summaries[message.messageID] = summary
        }
        return summaries
    }

    private static func isComposerEnabled(
        chatID: ChatID?,
        isLiveChat: Bool,
        remoteSession: RemoteState,
        isChatOperationConfigured: Bool
    ) -> Bool {
        guard isChatOperationConfigured else { return false }
        guard chatID != nil, !isLiveChat else { return true }
        return remoteSession.runState != .answering && remoteSession.runState != .queued
    }

    static func composerCaptionText(
        runState: ChatRunState,
        hasChatID: Bool,
        isLiveChat: Bool,
        isChatOperationConfigured: Bool
    ) -> String? {
        _ = hasChatID
        if isChatOperationConfigured == false {
            return "Configure an enabled provider and model in Settings → Providers before sending."
        }
        if runState == .queued {
            return "Waiting for the other session to finish before sending…"
        }
        if runState.isAnswering {
            return isLiveChat
                ? "Agent is responding…"
                : "Another chat is responding — wait or stop it."
        }
        return nil
    }

    static func canSendPredicate(
        hasMount: Bool,
        runState: ChatRunState,
        hasDraftText: Bool,
        isChatOperationConfigured: Bool
    ) -> Bool {
        _ = hasMount
        return isChatOperationConfigured
            && !runState.isAnswering
            && runState != .queued
            && hasDraftText
    }

    private static func showsStopButton(
        runState: ChatRunState,
        runningKind: WikiOperation.Kind?
    ) -> Bool {
        (runState.isAnswering || runState == .queued) && runningKind == .query
    }

    private static func showsQueueButton(
        runState: ChatRunState,
        runningKind: WikiOperation.Kind?,
        queuedMessages: [PendingQueuedMessage]
    ) -> Bool {
        runState.isAnswering && runningKind == .query && queuedMessages.isEmpty
    }

    private static func sendButtonTitle(
        remoteSession: RemoteState,
        queuedMessages: [PendingQueuedMessage]
    ) -> String {
        if remoteSession.runState == .queued {
            return "Waiting for the other session to finish before sending…"
        }
        if remoteSession.runState.isAnswering {
            return queuedMessages.isEmpty
                ? "Queue for when the response finishes"
                : "Queued — will send when the response finishes"
        }
        return remoteSession.runState.isLive ? "Send" : "Start Query"
    }

    static func shouldShowPreflightBanner(
        preflightError: String?,
        chatID: ChatID?,
        isLiveChat: Bool
    ) -> Bool {
        guard let message = preflightError, !message.isEmpty else { return false }
        return chatID == nil || !isLiveChat
    }

    static func preflightBannerMessage(
        preflightError: String?,
        chatID: ChatID?,
        isLiveChat: Bool
    ) -> String? {
        guard shouldShowPreflightBanner(
            preflightError: preflightError,
            chatID: chatID,
            isLiveChat: isLiveChat
        ) else {
            return nil
        }
        return preflightError
    }

    static func debugFolderButtonHelpText(debugURL: URL?) -> String {
        if debugURL != nil {
            return "Open the complete debug trace folder (ACP messages, permissions, usage)"
        }
        return "No debug folder on disk for this chat"
    }
}
