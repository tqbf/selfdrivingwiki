#if os(macOS)
import ACPModel
import Foundation
import Testing
import WikiFSEngine
import WikiFSCore
@testable import WikiFS

@MainActor
struct ChatDetailPresentationTests {

    @Test func contentStateShowsInternalsOnlyForRunningQueryDebugSurface() {
        let presentation = ChatDetailPresentation.make(
            chatID: ChatID(rawValue: "01J" + String(repeating: "A", count: 22)),
            chatResolution: nil,
            showsInternals: true,
            remoteSession: .fixture(runState: .answering, runningKind: .query),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.contentState == .internals)
        #expect(presentation.controls.showsDebugControls)
    }

    @Test func unresolvedPersistedChatShowsLoadingUntilAuthoritativeLookupCompletes() {
        let presentation = ChatDetailPresentation.make(
            chatID: ChatID(rawValue: "01J" + String(repeating: "B", count: 22)),
            chatResolution: nil,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.contentState == .loadingChat)
    }

    @Test func contentStateShowsDeletedOnlyAfterAuthoritativeNotFound() {
        let presentation = ChatDetailPresentation.make(
            chatID: ChatID(rawValue: "01J" + String(repeating: "N", count: 22)),
            chatResolution: .notFound,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.contentState == .deletedChat)
    }

    @Test func contentStateKeepsReadFailureDistinctFromDeletion() {
        let presentation = ChatDetailPresentation.make(
            chatID: ChatID(rawValue: "01J" + String(repeating: "F", count: 22)),
            chatResolution: .failed("database is busy"),
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.contentState == .failedToLoadChat("database is busy"))
    }

    @Test func transcriptProjectionSelectsTheTypedLiveTranscriptInsteadOfPersistedRows() {
        let chatID = ChatID(rawValue: "01J" + String(repeating: "C", count: 22))
        let liveTranscript = ChatDisplayProjection.project(items: [
            .message(.init(
                messageID: ChatMessageID(rawValue: "live-message"),
                turnID: ChatTurnID(rawValue: "live-turn"),
                role: .assistant,
                text: "Live response",
                createdAt: .distantPast
            ))
        ], activeContentBlock: nil).transcript
        let persistedItems = persisted([
            .message(.init(
                messageID: ChatMessageID(rawValue: "persisted-message"),
                turnID: ChatTurnID(rawValue: "persisted-turn"),
                role: .assistant,
                text: "Persisted response",
                createdAt: .distantPast
            ))
        ])
        let live = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(
                sessionChatID: chatID,
                runState: .answering,
                transcript: liveTranscript
            ),
            persistedTranscriptItems: persistedItems,
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )
        let persisted = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(transcript: liveTranscript),
            persistedTranscriptItems: persistedItems,
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(live.transcript.displayTranscript.rows.first?.textForSearch == "Live response")
        #expect(live.transcript.isAnswering)
        #expect(persisted.transcript.displayTranscript.rows.first?.textForSearch == "Persisted response")
        #expect(persisted.transcript.isAnswering == false)
    }

    @Test func persistedOutlineUsesModelSummaryReturnedByTranscriptPage() throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Summary round-trip")
        let turnID = ChatTurnID(rawValue: "turn-summary")
        let assistantMessageID = ChatMessageID(rawValue: "transcript-assistant-id")
        let assistantText = "Raw response opening that must not become the outline summary."
        _ = try store.appendChatTranscriptItems(
            chatID: chat.id,
            items: [
                .message(.init(
                    messageID: ChatMessageID(rawValue: "transcript-user-id"),
                    turnID: turnID,
                    role: .user,
                    text: "What changed?",
                    createdAt: .distantPast
                )),
                .message(.init(
                    messageID: assistantMessageID,
                    turnID: turnID,
                    role: .assistant,
                    text: assistantText,
                    createdAt: .distantPast
                )),
            ]
        )
        let compatibilityAssistant = try #require(
            store.chatMessages(chatID: chat.id).first { message in
                message.event == .assistantText(assistantText)
            }
        )
        // The compatibility message id is independently generated. This makes
        // a PageID-to-ChatMessageID conversion unable to find the summary.
        #expect(compatibilityAssistant.id.rawValue != assistantMessageID.rawValue)
        #expect(compatibilityAssistant.seq == 1)
        try store.updateMessageSummary(
            chatID: chat.id,
            messageID: compatibilityAssistant.id,
            summary: "Distinctive model summary.",
            kind: .model
        )

        let page = try store.readChatTranscriptPage(chatID: chat.id, after: nil, limit: 10)
        let persistedAssistant = try #require(page.items.first { item in
            guard case .message(let message) = item.item else { return false }
            return message.messageID == assistantMessageID
        })
        #expect(persistedAssistant.cursor.rawValue - 1 == Int64(compatibilityAssistant.seq))
        #expect(persistedAssistant.cachedResponseSummary == "Distinctive model summary.")
        let presentation = ChatDetailPresentation.make(
            chatID: chat.id,
            chatResolution: .available(chat),
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: page.items,
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.outlineEntries.first?.response == "Distinctive model summary.")
        #expect(presentation.outlineEntries.first?.response != ChatSummary.summaryExtract(
            from: assistantText,
            maxLength: 200
        ))
    }

    @Test func pendingPermissionOnlySurfacesForLiveChat() {
        let liveChatID = ChatID(rawValue: "01J" + String(repeating: "D", count: 22))
        let request = PendingPermission(
            toolCallId: ToolCallID(rawValue: "tool-1"),
            title: "Write page",
            toolName: "Edit file",
            inputSummary: "page.md",
            options: [
                PermissionOption(
                    kind: "allow_once",
                    name: "Allow once",
                    optionId: "allow_once")
            ]
        )

        let live = ChatDetailPresentation.make(
            chatID: liveChatID,
            chatResolution: .available(ChatSummary.fixture(id: liveChatID)),
            showsInternals: false,
            remoteSession: .fixture(sessionChatID: liveChatID, runState: .warm, pendingPermissions: [request]),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )
        let persisted = ChatDetailPresentation.make(
            chatID: liveChatID,
            chatResolution: .available(ChatSummary.fixture(id: liveChatID)),
            showsInternals: false,
            remoteSession: .fixture(pendingPermissions: [request]),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(live.livePendingPermission?.toolCallId == request.toolCallId)
        #expect(persisted.livePendingPermission == nil)
    }

    @Test func composerProjectionShowsQueueActionOnlyForGeneratingLiveChatWithDraftAndEmptyQueue() {
        let liveChatID = ChatID(rawValue: "01J" + String(repeating: "E", count: 22))
        let presentation = ChatDetailPresentation.make(
            chatID: liveChatID,
            chatResolution: .available(ChatSummary.fixture(id: liveChatID)),
            showsInternals: false,
            remoteSession: .fixture(
                sessionChatID: liveChatID,
                runState: .answering,
                runningKind: .query
            ),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: true,
            isChatOperationConfigured: true
        )

        #expect(presentation.composer.showsStopButton)
        #expect(presentation.composer.showsQueueButton)
        #expect(presentation.composer.sendButtonTitle == "Queue for when the response finishes")
        #expect(presentation.composer.canSend == false)
    }

    @Test func composerProjectionSuppressesQueueActionWhenFollowUpAlreadyQueued() {
        let liveChatID = ChatID(rawValue: "01J" + String(repeating: "F", count: 22))
        let presentation = ChatDetailPresentation.make(
            chatID: liveChatID,
            chatResolution: .available(ChatSummary.fixture(id: liveChatID)),
            showsInternals: false,
            remoteSession: .fixture(
                sessionChatID: liveChatID,
                runState: .answering,
                runningKind: .query
            ),
            persistedTranscriptItems: [],
            queuedMessages: [.fixture(preview: "next up")],
            hasDraftText: true,
            isChatOperationConfigured: true
        )

        #expect(presentation.composer.showsStopButton)
        #expect(presentation.composer.showsQueueButton == false)
        #expect(presentation.composer.sendButtonTitle == "Queued — will send when the response finishes")
    }

    @Test func composerProjectionDisablesInputAndSendWhenChatOperationIsNotConfigured() {
        let presentation = ChatDetailPresentation.make(
            chatID: nil,
            chatResolution: nil,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: true,
            isChatOperationConfigured: false
        )

        #expect(presentation.composer.isEnabled == false)
        #expect(presentation.composer.canSend == false)
        #expect(presentation.composer.caption == "Configure an enabled provider and model in Settings → Providers before sending.")
    }

    @Test func pagedTranscriptWithoutPromptDoesNotCreateOutlineEntry() {
        let chatID = ChatID(rawValue: "01J" + String(repeating: "G", count: 22))
        let presentation = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.outlineEntries.isEmpty)
    }
}

private func persisted(_ items: [ChatTranscriptItem]) -> [PersistedChatTranscriptItem] {
    items.enumerated().map { index, item in
        PersistedChatTranscriptItem(
            cursor: ChatTranscriptCursor(rawValue: Int64(index + 1)),
            item: item,
            projectedEventJSON: nil,
            projectedPlainText: "",
            createdAt: .distantPast
        )
    }
}

private extension ChatDetailPresentation.RemoteState {
    static func fixture(
        sessionChatID: ChatID? = nil,
        runState: ChatRunState = .idle,
        runningKind: WikiOperation.Kind? = nil,
        preflightError: String? = nil,
        pendingPermissions: [PendingPermission] = [],
        runStartedAt: Date? = nil,
        transcript: ChatDisplayTranscript = .empty,
        exitStatus: Int32? = nil
    ) -> Self {
        .init(
            runState: runState,
            sessionChatID: sessionChatID,
            runningKind: runningKind,
            preflightError: preflightError,
            pendingPermissions: pendingPermissions,
            runStartedAt: runStartedAt,
            transcript: transcript,
            exitStatus: exitStatus
        )
    }
}

private extension PendingQueuedMessage {
    static func fixture(preview: String) -> Self {
        .init(wireMessage: preview, preview: preview)
    }
}

private extension ChatSummary {
    static func fixture(id: ChatID) -> Self {
        .init(
            id: id,
            kind: .edit,
            title: "Test Chat",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            messageCount: 0,
            acpSessionId: nil,
            modelProviderId: nil,
            modelId: nil
        )
    }
}

private extension ChatMessage {
    static func fixture(
        chatID: ChatID = ChatID(rawValue: "01J" + String(repeating: "Z", count: 22)),
        seq: Int,
        event: AgentEvent,
        summary: String? = nil,
        summaryKind: ChatMessageSummaryKind? = nil
    ) -> Self {
        .init(
            id: PageID(rawValue: "01J" + String(format: "%022d", seq)),
            chatID: chatID,
            seq: seq,
            event: event,
            createdAt: Date(timeIntervalSince1970: TimeInterval(seq)),
            summary: summary,
            summaryKind: summaryKind
        )
    }
}
#endif
