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
            remoteSession: .fixture(isGenerating: true, runningKind: .query),
            persistedMessages: [],
            queuedMessages: [],
            hasDraftText: false
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
            persistedMessages: [],
            queuedMessages: [],
            hasDraftText: false
        )

        #expect(presentation.contentState == .missingChat)
    }

    @Test func transcriptProjectionUsesLiveEventsAndKeepsTimestampsAlignedAfterFiltering() {
        let liveTimestamps = [
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 20),
            Date(timeIntervalSince1970: 30),
        ]
        let presentation = ChatDetailPresentation.make(
            chatID: ChatID(rawValue: "01J" + String(repeating: "C", count: 22)),
            chatSummary: ChatSummary.fixture(id: ChatID(rawValue: "01J" + String(repeating: "C", count: 22))),
            showsInternals: false,
            remoteSession: .fixture(
                activeChatID: ChatID(rawValue: "01J" + String(repeating: "C", count: 22)),
                isGenerating: true,
                events: [
                    .userText("hello"),
                    .toolResult(isError: false, summary: "ok"),
                    .assistantText("world"),
                ],
                eventTimestamps: liveTimestamps
            ),
            persistedMessages: [
                ChatMessage.fixture(seq: 0, event: .userText("persisted")),
            ],
            queuedMessages: [],
            hasDraftText: false
        )

        #expect(presentation.transcript.events == [.userText("hello"), .assistantText("world")])
        #expect(presentation.transcript.timestamps == [liveTimestamps[0], liveTimestamps[2]])
        #expect(presentation.transcript.isRunning)
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
            remoteSession: .fixture(activeChatID: liveChatID, pendingPermissions: [request]),
            persistedMessages: [],
            queuedMessages: [],
            hasDraftText: false
        )
        let persisted = ChatDetailPresentation.make(
            chatID: liveChatID,
            chatSummary: ChatSummary.fixture(id: liveChatID),
            showsInternals: false,
            remoteSession: .fixture(pendingPermissions: [request]),
            persistedMessages: [],
            queuedMessages: [],
            hasDraftText: false
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
                activeChatID: liveChatID,
                isGenerating: true,
                runningKind: .query
            ),
            persistedMessages: [],
            queuedMessages: [],
            hasDraftText: true
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
                activeChatID: liveChatID,
                isGenerating: true,
                runningKind: .query
            ),
            persistedMessages: [],
            queuedMessages: [.fixture(preview: "next up")],
            hasDraftText: true
        )

        #expect(presentation.composer.showsStopButton)
        #expect(presentation.composer.showsQueueButton == false)
        #expect(presentation.composer.sendButtonTitle == "Queued — will send when the response finishes")
    }

    @Test func outlineProjectionUsesCachedPersistedSummaryWhenAvailable() throws {
        let chatID = ChatID(rawValue: "01J" + String(repeating: "G", count: 22))
        let presentation = ChatDetailPresentation.make(
            chatID: chatID,
            chatSummary: ChatSummary.fixture(id: chatID),
            showsInternals: false,
            remoteSession: .fixture(),
            persistedMessages: [
                .fixture(chatID: chatID, seq: 0, event: .userText("[[page:Project Plan]]\n\nWhat changed?")),
                .fixture(
                    chatID: chatID,
                    seq: 1,
                    event: .assistantText("Fallback summary should not win."),
                    summary: "Cached persisted summary",
                    summaryKind: .model
                ),
            ],
            queuedMessages: [],
            hasDraftText: false
        )

        let entry = try #require(presentation.outlineEntries.first)
        #expect(entry.question == "Project Plan\n\nWhat changed?")
        #expect(entry.response == "Cached persisted summary")
    }
}

private extension ChatDetailPresentation.RemoteState {
    static func fixture(
        activeChatID: ChatID? = nil,
        runState: ChatRunState? = nil,
        isGenerating: Bool = false,
        isAwaitingGenerationSlot: Bool = false,
        runningKind: WikiOperation.Kind? = nil,
        preflightError: String? = nil,
        pendingPermissions: [PendingPermission] = [],
        runStartedAt: Date? = nil,
        events: [AgentEvent] = [],
        eventTimestamps: [Date?] = [],
        exitStatus: Int32? = nil
    ) -> Self {
        .init(
            runState: runState ?? {
                if isGenerating { return .answering }
                if isAwaitingGenerationSlot { return .queued }
                if activeChatID != nil { return .warm }
                return .idle
            }(),
            activeChatID: activeChatID,
            runningKind: runningKind,
            preflightError: preflightError,
            pendingPermissions: pendingPermissions,
            runStartedAt: runStartedAt,
            events: events,
            eventTimestamps: eventTimestamps,
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
