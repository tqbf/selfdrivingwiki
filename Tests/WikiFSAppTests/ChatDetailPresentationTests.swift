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
        let liveItems: [ChatTranscriptItem] = [
            .message(.init(
                messageID: ChatMessageID(rawValue: "live-message"),
                turnID: ChatTurnID(rawValue: "live-turn"),
                role: .assistant,
                text: "Live response",
                createdAt: .distantPast
            ))
        ]
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
                projectionInput: TranscriptProjectionInput(items: liveItems, activeContentBlock: nil)
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
            remoteSession: .fixture(
                projectionInput: TranscriptProjectionInput(items: liveItems, activeContentBlock: nil)
            ),
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

    // MARK: - Optimistic outgoing echo

    private func outgoingEchoFixture(
        status: PendingOutgoingMessage.Status = .submitting,
        turnID: ChatTurnID = ChatTurnID(rawValue: "echo-turn-1"),
        wireMessage: String = "Please update the wiki"
    ) -> PendingOutgoingMessage {
        PendingOutgoingMessage(
            id: turnID,
            status: status,
            draftText: wireMessage,
            wireMessage: wireMessage,
            attachments: [],
            submittedAt: Date(timeIntervalSince1970: 100)
        )
    }

    @Test func draftPendingOutgoingEchoRendersAsUserRow() {
        let presentation = ChatDetailPresentation.make(
            chatID: nil,
            chatResolution: nil,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            pendingOutgoing: [outgoingEchoFixture()],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        let rows = presentation.transcript.displayTranscript.rows
        guard case .userMessage(let id, let turnID, let text, _)? = rows.first else {
            Issue.record("Expected a user message row, got: \(rows)")
            return
        }
        #expect(id == ChatMessageID(rawValue: "optimistic-echo-turn-1"))
        #expect(turnID == ChatTurnID(rawValue: "echo-turn-1"))
        #expect(text == "Please update the wiki")
    }

    @Test func coldExistingChatPendingOutgoingEchoRendersAsUserRow() {
        let chatID = ChatID(rawValue: "01J" + String(repeating: "H", count: 22))
        let presentation = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            pendingOutgoing: [outgoingEchoFixture()],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(presentation.contentState == .chatSurface)
        let rows = presentation.transcript.displayTranscript.rows
        guard case .userMessage(_, _, let text, _)? = rows.first else {
            Issue.record("Expected an echoed user message row, got: \(rows)")
            return
        }
        #expect(text == "Please update the wiki")
    }

    @Test func liveChatPendingOutgoingEchoRendersAlongsideSessionItems() {
        let chatID = ChatID(rawValue: "01J" + String(repeating: "I", count: 22))
        let turnID = ChatTurnID(rawValue: "session-turn")
        let sessionItems: [ChatTranscriptItem] = [
            .message(.init(
                messageID: ChatMessageID(rawValue: "session-user"),
                turnID: turnID,
                role: .user,
                text: "Earlier question",
                createdAt: .distantPast
            )),
            .message(.init(
                messageID: ChatMessageID(rawValue: "session-assistant"),
                turnID: turnID,
                role: .assistant,
                text: "Earlier answer",
                createdAt: .distantPast
            )),
        ]
        let presentation = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(
                sessionChatID: chatID,
                runState: .answering,
                projectionInput: TranscriptProjectionInput(items: sessionItems, activeContentBlock: nil)
            ),
            persistedTranscriptItems: [],
            pendingOutgoing: [outgoingEchoFixture()],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        let texts = presentation.transcript.displayTranscript.rows.map(\.textForSearch)
        #expect(texts == ["Earlier question", "Earlier answer", "Please update the wiki"])
    }

    @Test func liveOutgoingEchoPreservesActiveStreamingContentBlock() throws {
        let chatID = ChatID(rawValue: "01J" + String(repeating: "J", count: 22))
        let turnID = ChatTurnID(rawValue: "streaming-turn")
        let assistantItem = ChatTranscriptItem.message(.init(
            messageID: ChatMessageID(rawValue: "streaming-assistant"),
            turnID: turnID,
            role: .assistant,
            text: "Streaming answer",
            createdAt: .distantPast
        ))
        let activeBlock = try #require(ChatDisplayActiveContentBlock(
            validating: ChatActiveContentBlock(
                messageID: ChatMessageID(rawValue: "streaming-assistant"),
                turnID: turnID,
                role: .assistant
            ),
            among: [assistantItem]
        ))
        let presentation = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(
                sessionChatID: chatID,
                runState: .answering,
                projectionInput: TranscriptProjectionInput(
                    items: [assistantItem],
                    activeContentBlock: activeBlock
                )
            ),
            persistedTranscriptItems: [],
            pendingOutgoing: [outgoingEchoFixture()],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        let rows = presentation.transcript.displayTranscript.rows
        let assistantRow = rows.first { row in
            row.textForSearch == "Streaming answer"
        }
        #expect(assistantRow?.contentState == .streaming)
        #expect(rows.last?.textForSearch == "Please update the wiki")
    }

    @Test func failedOutgoingEchoRendersUserRowAndFailureRow() {
        let presentation = ChatDetailPresentation.make(
            chatID: nil,
            chatResolution: nil,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            pendingOutgoing: [outgoingEchoFixture(status: .failed(message: "daemon unreachable"))],
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        let rows = presentation.transcript.displayTranscript.rows
        guard rows.count == 2 else {
            Issue.record("Expected one user row and one failure row, got: \(rows)")
            return
        }
        guard case .userMessage(let messageID, let turnID, let text, _)? = rows.first else {
            Issue.record("Expected echoed user row first, got: \(rows)")
            return
        }
        #expect(messageID == ChatMessageID(rawValue: "optimistic-echo-turn-1"))
        #expect(turnID == ChatTurnID(rawValue: "echo-turn-1"))
        #expect(text == "Please update the wiki")
        guard case .failure(let failureID, let failureTurnID, let category, let message, _)? = rows.last else {
            Issue.record("Expected typed failure row last, got: \(rows)")
            return
        }
        #expect(failureID == ChatTranscriptFailureID(rawValue: "send-failed-echo-turn-1"))
        #expect(failureTurnID == turnID)
        #expect(category == .transportError)
        #expect(message == "daemon unreachable")
    }

    @Test func outgoingEchoFilteredWhenAuthoritativeTurnArrives() {
        let echo = outgoingEchoFixture()
        let chatID = ChatID(rawValue: "01J" + String(repeating: "K", count: 22))
        let authoritative: Set<ChatTurnID> = [echo.id]
        let draft = ChatDetailPresentation.make(
            chatID: nil,
            chatResolution: nil,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            pendingOutgoing: [echo],
            authoritativeTurnIDs: authoritative,
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )
        let live = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(
                sessionChatID: chatID,
                runState: .answering,
                projectionInput: TranscriptProjectionInput(items: [
                    .message(.init(
                        messageID: ChatMessageID(rawValue: "authoritative-user"),
                        turnID: echo.id,
                        role: .user,
                        text: "Authoritative copy",
                        createdAt: .distantPast
                    )),
                ], activeContentBlock: nil)
            ),
            persistedTranscriptItems: [],
            pendingOutgoing: [echo],
            authoritativeTurnIDs: authoritative,
            queuedMessages: [],
            hasDraftText: false,
            isChatOperationConfigured: true
        )

        #expect(draft.transcript.displayTranscript.rows.isEmpty)
        let liveTexts = live.transcript.displayTranscript.rows.map(\.textForSearch)
        #expect(liveTexts == ["Authoritative copy"])
    }

    @Test func draftSubmitPendingBlocksSendAndShowsCaption() {
        let chatID = ChatID(rawValue: "01J" + String(repeating: "L", count: 22))
        let draftPending = ChatDetailPresentation.make(
            chatID: nil,
            chatResolution: nil,
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            pendingOutgoing: [outgoingEchoFixture()],
            queuedMessages: [],
            hasDraftText: true,
            isChatOperationConfigured: true
        )
        let existingWithInFlightSend = ChatDetailPresentation.make(
            chatID: chatID,
            chatResolution: .available(ChatSummary.fixture(id: chatID)),
            showsInternals: false,
            remoteSession: .fixture(),
            persistedTranscriptItems: [],
            pendingOutgoing: [outgoingEchoFixture()],
            queuedMessages: [],
            hasDraftText: true,
            isChatOperationConfigured: true
        )

        #expect(draftPending.composer.canSend == false)
        #expect(draftPending.composer.caption == "Starting chat…")
        #expect(existingWithInFlightSend.composer.canSend == true)
        #expect(existingWithInFlightSend.composer.caption != "Starting chat…")
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

    /// Summary mode collapses earlier assistant blocks into interim notes,
    /// so the outline must excerpt the turn's LAST assistant block — the
    /// answer — not a progress note.
    @Test func outlineExcerptsTheFinalAnswerNotInterimNotes() {
        let turnID = ChatTurnID(rawValue: "turn-outline")
        let prompt = ChatDisplayRow.userMessage(
            id: ChatMessageID(rawValue: "q"),
            turnID: turnID,
            text: "Question",
            createdAt: .distantPast
        )
        let transcript = ChatDisplayTranscript(sections: [
            .turn(ChatDisplayTurn(
                id: .turn(turnID: turnID, firstRow: .message(ChatMessageID(rawValue: "q"))),
                turnID: turnID,
                prompt: prompt,
                rows: [
                    prompt,
                    .assistantMessage(
                        id: ChatMessageID(rawValue: "interim"),
                        turnID: turnID,
                        text: "Checking the tide tables now, one moment.",
                        createdAt: .distantPast,
                        contentState: .final
                    ),
                    .assistantMessage(
                        id: ChatMessageID(rawValue: "final"),
                        turnID: turnID,
                        text: "Tidal pools form where the tide recedes twice daily.",
                        createdAt: .distantPast,
                        contentState: .final
                    ),
                ]
            )),
        ])

        let entries = ChatDetailPresentation.buildOutlineEntries(displayTranscript: transcript)
        #expect(entries.count == 1)
        #expect(entries[0].response == "Tidal pools form where the tide recedes twice daily.")
    }

    // MARK: - Stale cached summaries vs. the known warning

    /// A cached response summary predates the presentation projection. When
    /// it contains the complete known skill warning it must not re-enter the
    /// outline: a warning-only cache falls back to the cleaned row text, a
    /// warning-plus-text cache uses its cleaned remainder, and an incomplete
    /// final prefix stays (completeOnly semantics).
    @Test func staleCachedWarningCannotReappearInOutline() {
        let warning = "Warning: Skill descriptions were shortened to fit the 2% skills context budget."
        let turnID = ChatTurnID(rawValue: "turn-cache")
        let promptRow = ChatDisplayRow.userMessage(
            id: ChatMessageID(rawValue: "q"),
            turnID: turnID,
            text: "Question",
            createdAt: .distantPast
        )

        func transcriptWithResponse(_ responseID: String, _ text: String) -> ChatDisplayTranscript {
            ChatDisplayTranscript(sections: [
                .turn(ChatDisplayTurn(
                    id: .turn(
                        turnID: turnID,
                        firstRow: .message(ChatMessageID(rawValue: "q"))
                    ),
                    turnID: turnID,
                    prompt: promptRow,
                    rows: [
                        promptRow,
                        .assistantMessage(
                            id: ChatMessageID(rawValue: responseID),
                            turnID: turnID,
                            text: text,
                            createdAt: .distantPast,
                            contentState: .final
                        ),
                    ]
                )),
            ])
        }

        // 1. Complete cached warning only → cleaned cache is empty → fall
        //    back to the (already cleaned) assistant row summary.
        let rowID = ChatMessageID(rawValue: "row-1")
        let fallbackTranscript = transcriptWithResponse("row-1", "Tidal pools form twice daily.")
        let fallback = ChatDetailPresentation.buildOutlineEntries(
            displayTranscript: fallbackTranscript,
            cachedResponseSummaries: [rowID: warning]
        )
        #expect(fallback.count == 1)
        #expect(fallback[0].response == "Tidal pools form twice daily.")

        // 2. Cached warning plus substantive text → cleaned cache wins
        //    (precedence over the row extract).
        let precedence = ChatDetailPresentation.buildOutlineEntries(
            displayTranscript: transcriptWithResponse("row-2", "A different row body."),
            cachedResponseSummaries: [ChatMessageID(rawValue: "row-2"): warning + "\n\nCached answer."]
        )
        #expect(precedence.count == 1)
        #expect(precedence[0].response == "Cached answer.")

        // 3. Incomplete prefix cached → preserved (never treated as the
        //    complete warning).
        let partial = "Warning: Skill descriptions were shortened"
        let preserved = ChatDetailPresentation.buildOutlineEntries(
            displayTranscript: transcriptWithResponse("row-3", partial),
            cachedResponseSummaries: [ChatMessageID(rawValue: "row-3"): partial]
        )
        #expect(preserved.count == 1)
        #expect(preserved[0].response == partial)

        // 4. Warning-only row in the transcript: the projection drops the
        //    row entirely, so the outline entry has no response even when a
        //    stale cached summary exists for the dropped ID.
        let canonical = ChatDisplayProjection.project(items: [], activeContentBlock: nil).transcript
        let droppedTranscript = ChatTranscriptPresentationProjection.project(
            transcript: canonical, toolCallDisplayMode: .summary)
        #expect(droppedTranscript.sections.isEmpty)
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
        projectionInput: TranscriptProjectionInput = .empty,
        exitStatus: Int32? = nil
    ) -> Self {
        .init(
            runState: runState,
            sessionChatID: sessionChatID,
            runningKind: runningKind,
            preflightError: preflightError,
            pendingPermissions: pendingPermissions,
            runStartedAt: runStartedAt,
            projectionInput: projectionInput,
            exitStatus: exitStatus
        )
    }
}

private extension PendingQueuedMessage {
    static func fixture(preview: String) -> Self {
        .init(wireMessage: preview, preview: preview, draftText: preview, attachments: [])
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
