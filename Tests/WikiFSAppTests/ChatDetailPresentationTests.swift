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
            chatSummary: nil,
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

    @Test func contentStateShowsMissingForDeletedPersistedChat() {
        let presentation = ChatDetailPresentation.make(
            chatID: ChatID(rawValue: "01J" + String(repeating: "B", count: 22)),
            chatSummary: nil,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.contentState == .missingChat)
    }

    @Test func transcriptProjectionUsesTheTypedLiveTranscript() {
        let presentation = ChatDetailPresentation.make(
            chatID: ChatID(rawValue: "01J" + String(repeating: "C", count: 22)),
            chatSummary: ChatSummary.fixture(id: ChatID(rawValue: "01J" + String(repeating: "C", count: 22))),
            showsInternals: false,
            remoteSession: .fixture(
                sessionChatID: ChatID(rawValue: "01J" + String(repeating: "C", count: 22)),
                runState: .answering,
                transcript: ChatDisplayProjection.project(items: [], activeContentBlock: nil).transcript
            ),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.transcript.displayTranscript.rows.isEmpty)
        #expect(presentation.transcript.isAnswering)
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
            chatSummary: ChatSummary.fixture(id: liveChatID),
            showsInternals: false,
            remoteSession: .fixture(sessionChatID: liveChatID, runState: .warm, pendingPermissions: [request]),
            persistedTranscriptItems: [],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )
        let persisted = ChatDetailPresentation.make(
            chatID: liveChatID,
            chatSummary: ChatSummary.fixture(id: liveChatID),
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
            chatSummary: ChatSummary.fixture(id: liveChatID),
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
            chatSummary: ChatSummary.fixture(id: liveChatID),
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
            chatSummary: nil,
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
            chatSummary: ChatSummary.fixture(id: chatID),
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
