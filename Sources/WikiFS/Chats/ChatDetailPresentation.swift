// pattern: Functional Core

import Foundation
import WikiFSEngine
import WikiFSCore

struct ChatDetailPresentation {
    enum ContentState: Equatable {
        case internals
        case missingChat
        case chatSurface
    }

    struct RemoteState {
        let runState: ChatRunState
        let activeChatID: ChatID?
        let runningKind: WikiOperation.Kind?
        let preflightError: String?
        let pendingPermissions: [PendingPermission]
        let runStartedAt: Date?
        let events: [AgentEvent]
        let eventTimestamps: [Date?]
        let exitStatus: Int32?

        var isRunning: Bool { runState.isLive }
        var isGenerating: Bool { runState.isAnswering }
        var isAwaitingGenerationSlot: Bool { runState == .queued }
        var isInteractiveSession: Bool { runState.isLive }
    }

    struct Controls {
        let showsDebugControls: Bool
    }

    struct Transcript {
        let events: [AgentEvent]
        let timestamps: [Date?]
        let emptyStateMessage: String
        let isRunning: Bool
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
        chatSummary: ChatSummary?,
        showsInternals: Bool,
        remoteSession: RemoteState,
        persistedMessages: [ChatMessage],
        queuedMessages: [PendingQueuedMessage],
        hasDraftText: Bool,
        isChatOperationConfigured: Bool
    ) -> Self {
        let isLiveChat = chatID.map { remoteSession.activeChatID == $0 } ?? false
        let displayEvents = displayMessages(
            isLiveChat: isLiveChat,
            launcherEvents: remoteSession.events,
            persistedEvents: persistedMessages.map(\.event)
        )
        let displayTimestamps = displayTimestamps(
            isLiveChat: isLiveChat,
            launcherEvents: remoteSession.events,
            launcherTimestamps: remoteSession.eventTimestamps,
            persistedMessages: persistedMessages
        )
        let controls = Controls(
            showsDebugControls: showsDebugControls(
                isGenerating: remoteSession.isGenerating,
                isAwaitingGenerationSlot: remoteSession.isAwaitingGenerationSlot,
                runningKind: remoteSession.runningKind
            )
        )
        let transcriptIsRunning = transcriptIsRunning(
            isLiveChat: isLiveChat,
            runState: remoteSession.runState
        )
        let composerEnabled = isComposerEnabled(
            chatID: chatID,
            isLiveChat: isLiveChat,
            remoteSession: remoteSession,
            isChatOperationConfigured: isChatOperationConfigured
        )
        let canType = canType(remoteSession: remoteSession)
        let canSend = canSendPredicate(
            hasMount: true,
            canType: canType,
            isGenerating: remoteSession.isGenerating,
            isAwaitingSlot: remoteSession.isAwaitingGenerationSlot,
            hasDraftText: hasDraftText,
            isChatOperationConfigured: isChatOperationConfigured
        )
        let outlineEntries = buildOutlineEntries(
            displayMessages: displayEvents,
            displayTimestamps: displayTimestamps,
            isLiveChat: isLiveChat,
            persistedMessages: persistedMessages
        )
        let contentState: ContentState
        if showsInternals && controls.showsDebugControls {
            contentState = .internals
        } else if chatID != nil && !isLiveChat && chatSummary == nil {
            contentState = .missingChat
        } else {
            contentState = .chatSurface
        }

        return Self(
            contentState: contentState,
            controls: controls,
            transcript: Transcript(
                events: displayEvents,
                timestamps: displayTimestamps,
                emptyStateMessage: transcriptEmptyMessage(chatID: chatID, isLiveChat: isLiveChat),
                isRunning: transcriptIsRunning
            ),
            composer: Composer(
                isEnabled: composerEnabled,
                caption: composerCaptionText(
                    isAwaitingGenerationSlot: remoteSession.isAwaitingGenerationSlot,
                    hasChatID: chatID != nil,
                    isLiveChat: isLiveChat,
                    isGenerating: remoteSession.isGenerating,
                    isChatOperationConfigured: isChatOperationConfigured
                ),
                canSend: canSend,
                sendButtonTitle: sendButtonTitle(
                    remoteSession: remoteSession,
                    queuedMessages: queuedMessages
                ),
                showsStopButton: showsStopButton(
                    isGenerating: remoteSession.isGenerating,
                    isAwaitingGenerationSlot: remoteSession.isAwaitingGenerationSlot,
                    runningKind: remoteSession.runningKind
                ),
                showsQueueButton: showsQueueButton(
                    isGenerating: remoteSession.isGenerating,
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
            showsThinkingIndicator: transcriptIsRunning && remoteSession.isGenerating,
            outlineEntries: outlineEntries,
            chatInspectorAvailable: !outlineEntries.isEmpty
        )
    }

    static func displayMessages(
        isLiveChat: Bool,
        launcherEvents: [AgentEvent],
        persistedEvents: [AgentEvent]
    ) -> [AgentEvent] {
        (isLiveChat ? launcherEvents : persistedEvents).transcriptVisible
    }

    static func displayTimestamps(
        isLiveChat: Bool,
        launcherEvents: [AgentEvent],
        launcherTimestamps: [Date?],
        persistedMessages: [ChatMessage]
    ) -> [Date?] {
        let indices: [Int]
        if isLiveChat {
            indices = launcherEvents.transcriptVisibleIndices
            return indices.map { idx in
                idx < launcherTimestamps.count ? launcherTimestamps[idx] : nil
            }
        }

        let persistedEvents = persistedMessages.map(\.event)
        indices = persistedEvents.transcriptVisibleIndices
        return indices.map { idx in
            idx < persistedMessages.count ? persistedMessages[idx].createdAt : nil
        }
    }

    static func transcriptEmptyMessage(chatID: ChatID?, isLiveChat: Bool) -> String {
        if chatID == nil {
            return "Ask a question, or ask the Agent to update the wiki…"
        }
        return isLiveChat ? "Ask a question to start a chat." : "No messages were persisted for this chat."
    }

    static func transcriptIsRunning(isLiveChat: Bool, runState: ChatRunState) -> Bool {
        isLiveChat && runState.isAnswering
    }

    static func showsDebugControls(
        isGenerating: Bool,
        isAwaitingGenerationSlot: Bool,
        runningKind: WikiOperation.Kind?
    ) -> Bool {
        (isGenerating || isAwaitingGenerationSlot) && runningKind == .query
    }

    static func livePendingPermission(
        isLiveChat: Bool,
        pendingPermissions: [PendingPermission]
    ) -> PendingPermission? {
        guard isLiveChat else { return nil }
        return pendingPermissions.first
    }

    static func buildOutlineEntries(
        displayMessages: [AgentEvent],
        displayTimestamps: [Date?],
        isLiveChat: Bool,
        persistedMessages: [ChatMessage]
    ) -> [ChatOutlineEntry] {
        let cachedSummaries: [String?]
        let cachedSummaryKinds: [ChatMessageSummaryKind?]
        if isLiveChat {
            cachedSummaries = Array(repeating: nil, count: displayMessages.count)
            cachedSummaryKinds = Array(repeating: nil, count: displayMessages.count)
        } else {
            let visiblePersistedMessages = visiblePersistedMessages(persistedMessages)
            cachedSummaries = visiblePersistedMessages.map(\.summary)
            cachedSummaryKinds = visiblePersistedMessages.map(\.summaryKind)
        }

        var entries: [ChatOutlineEntry] = []
        var pendingQuestion: String?
        var pendingQuestionTimestamp: Date?

        for (index, event) in displayMessages.enumerated() {
            let timestamp = index < displayTimestamps.count ? displayTimestamps[index] : nil
            switch event {
            case .userText(let text):
                if let pendingQuestion {
                    entries.append(
                        ChatOutlineEntry(
                            question: pendingQuestion,
                            response: nil,
                            questionTimestamp: pendingQuestionTimestamp,
                            responseTimestamp: nil
                        )
                    )
                }
                pendingQuestion = humanizeAttachmentRefs(in: text)
                pendingQuestionTimestamp = timestamp

            case .assistantText(let text), .result(_, let text):
                guard let question = pendingQuestion else { continue }
                let cachedSummary = index < cachedSummaries.count ? cachedSummaries[index] : nil
                let summary = cachedSummary ?? ChatSummary.summaryExtract(from: text, maxLength: 200)
                if let cachedSummary {
                    let kind = index < cachedSummaryKinds.count ? cachedSummaryKinds[index]?.rawValue ?? "unknown" : "unknown"
                    DebugLog.ingest("chatOutlineEntries: seq=\(index) using cached summary (kind=\(kind))")
                    entries.append(
                        ChatOutlineEntry(
                            question: question,
                            response: cachedSummary.isEmpty ? nil : cachedSummary,
                            questionTimestamp: pendingQuestionTimestamp,
                            responseTimestamp: timestamp
                        )
                    )
                } else {
                    DebugLog.ingest("chatOutlineEntries: seq=\(index) no cache, using truncation fallback")
                    entries.append(
                        ChatOutlineEntry(
                            question: question,
                            response: summary.isEmpty ? nil : summary,
                            questionTimestamp: pendingQuestionTimestamp,
                            responseTimestamp: timestamp
                        )
                    )
                }
                pendingQuestion = nil
                pendingQuestionTimestamp = nil

            default:
                break
            }
        }

        if let pendingQuestion {
            entries.append(
                ChatOutlineEntry(
                    question: pendingQuestion,
                    response: nil,
                    questionTimestamp: pendingQuestionTimestamp,
                    responseTimestamp: nil
                )
            )
        }

        return entries
    }

    private static func visiblePersistedMessages(_ persistedMessages: [ChatMessage]) -> [ChatMessage] {
        let indices = persistedMessages.map(\.event).transcriptVisibleIndices
        return indices.compactMap { idx in
            idx < persistedMessages.count ? persistedMessages[idx] : nil
        }
    }

    private static func isComposerEnabled(
        chatID: ChatID?,
        isLiveChat: Bool,
        remoteSession: RemoteState,
        isChatOperationConfigured: Bool
    ) -> Bool {
        guard isChatOperationConfigured else { return false }
        guard chatID != nil else {
            return remoteSession.isInteractiveSession || !remoteSession.isRunning || remoteSession.isGenerating
        }
        if isLiveChat {
            return remoteSession.isInteractiveSession || !remoteSession.isRunning || remoteSession.isGenerating
        }
        return !remoteSession.isGenerating && !remoteSession.isAwaitingGenerationSlot
    }

    private static func canType(remoteSession: RemoteState) -> Bool {
        remoteSession.isInteractiveSession || !remoteSession.isRunning || remoteSession.isGenerating
    }

    static func composerCaptionText(
        isAwaitingGenerationSlot: Bool,
        hasChatID: Bool,
        isLiveChat: Bool,
        isGenerating: Bool,
        isChatOperationConfigured: Bool
    ) -> String? {
        _ = hasChatID
        if isChatOperationConfigured == false {
            return "Configure an enabled provider and model in Settings → Providers before sending."
        }
        if isAwaitingGenerationSlot {
            return "Waiting for the other session to finish before sending…"
        }
        if isGenerating {
            return isLiveChat
                ? "Agent is responding…"
                : "Another chat is responding — wait or stop it."
        }
        return nil
    }

    static func canSendPredicate(
        hasMount: Bool,
        canType: Bool,
        isGenerating: Bool,
        isAwaitingSlot: Bool,
        hasDraftText: Bool,
        isChatOperationConfigured: Bool
    ) -> Bool {
        _ = hasMount
        return isChatOperationConfigured && canType && !isGenerating && !isAwaitingSlot && hasDraftText
    }

    private static func showsStopButton(
        isGenerating: Bool,
        isAwaitingGenerationSlot: Bool,
        runningKind: WikiOperation.Kind?
    ) -> Bool {
        (isGenerating || isAwaitingGenerationSlot) && runningKind == .query
    }

    private static func showsQueueButton(
        isGenerating: Bool,
        runningKind: WikiOperation.Kind?,
        queuedMessages: [PendingQueuedMessage]
    ) -> Bool {
        isGenerating && runningKind == .query && queuedMessages.isEmpty
    }

    private static func sendButtonTitle(
        remoteSession: RemoteState,
        queuedMessages: [PendingQueuedMessage]
    ) -> String {
        if remoteSession.isAwaitingGenerationSlot {
            return "Waiting for the other session to finish before sending…"
        }
        if remoteSession.isGenerating {
            return queuedMessages.isEmpty
                ? "Queue for when the response finishes"
                : "Queued — will send when the response finishes"
        }
        return remoteSession.isInteractiveSession ? "Send" : "Start Query"
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
