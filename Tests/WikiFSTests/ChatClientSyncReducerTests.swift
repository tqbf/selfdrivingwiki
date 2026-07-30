#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

struct ChatClientSyncReducerTests {
    @Test func snapshotRequestsCommittedHistoryCatchUp() {
        let state = ChatClientSyncState(chatID: ChatID(rawValue: "chat-1"))
        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applySnapshot(makeSnapshot(sequence: 1, committedCursor: ChatTranscriptCursor(rawValue: 5)))
        )

        #expect(reduction.state.syncStatus == .synchronized)
        #expect(reduction.state.projection?.committedCursor == ChatTranscriptCursor(rawValue: 5))
        #expect(reduction.effects == [.loadCommittedHistory(to: ChatTranscriptCursor(rawValue: 5))])
    }

    @Test func updateWithoutBaselineRequestsAuthoritativeSnapshot() {
        let state = ChatClientSyncState(chatID: ChatID(rawValue: "chat-1"))
        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(sequence: 1))
        )

        #expect(reduction.state.syncStatus == .awaitingAuthoritativeSnapshot)
        #expect(reduction.effects == [.requestAuthoritativeSnapshot])
    }

    @Test func staleGenerationRequestsSnapshotAndPreservesCurrentProjection() {
        let current = makeProjection(sequence: 2, generation: "generation-1")
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: current,
            syncStatus: .synchronized
        )
        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(sequence: 3, generation: "generation-2"))
        )

        #expect(reduction.state.projection == current)
        #expect(reduction.state.syncStatus == .awaitingAuthoritativeSnapshot)
        #expect(reduction.effects == [.requestAuthoritativeSnapshot])
    }

    @Test func duplicateSequenceUpdateIsIgnored() {
        let current = makeProjection(sequence: 4, overlay: [makeMessage(role: .assistant, text: "current")])
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: current,
            syncStatus: .synchronized
        )
        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(
                sequence: 4,
                reason: .sessionEvent(.started(turnID: ChatTurnID(rawValue: "turn-1"))),
                overlay: [makeMessage(role: .assistant, text: "stale")]
            ))
        )

        #expect(reduction.state == state)
        #expect(reduction.effects.isEmpty)
    }

    @Test func gapRequestsAuthoritativeSnapshotAndPreservesKnownHistory() {
        let committed = makePersisted(cursor: 2, item: makeMessage(role: .user, text: "known"))
        let current = makeProjection(sequence: 2)
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: current,
            committedItems: [committed],
            loadedCommittedCursor: ChatTranscriptCursor(rawValue: 2),
            syncStatus: .synchronized
        )
        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(sequence: 5))
        )

        #expect(reduction.state.projection == current)
        #expect(reduction.state.committedItems == [committed])
        #expect(reduction.state.syncStatus == .gapDetected(
            expected: ChatUpdateSequence(rawValue: 3),
            received: ChatUpdateSequence(rawValue: 5)
        ))
        #expect(reduction.effects == [.requestAuthoritativeSnapshot])
    }

    @Test func compatibilityRefreshAtSameSequenceReplacesProjection() {
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 3),
            syncStatus: .synchronized
        )
        let refreshed = makeProjection(
            sequence: 3,
            diagnostics: ChatDiagnosticsState(stderr: "refreshed")
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(ChatSyncUpdate(reason: .compatibilityRefreshed, projection: refreshed))
        )

        #expect(reduction.state.projection == refreshed)
        #expect(reduction.state.syncStatus == .synchronized)
    }

    @Test func reconnectSnapshotPreservesLoadedCommittedHistory() {
        let committed = makePersisted(cursor: 7, item: makeMessage(role: .assistant, text: "history"))
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 2, committedCursor: ChatTranscriptCursor(rawValue: 7)),
            committedItems: [committed],
            loadedCommittedCursor: ChatTranscriptCursor(rawValue: 7),
            syncStatus: .gapDetected(
                expected: ChatUpdateSequence(rawValue: 3),
                received: ChatUpdateSequence(rawValue: 6)
            )
        )
        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applySnapshot(makeSnapshot(sequence: 8, committedCursor: ChatTranscriptCursor(rawValue: 2)))
        )

        #expect(reduction.state.syncStatus == .synchronized)
        #expect(reduction.state.loadedCommittedCursor == ChatTranscriptCursor(rawValue: 7))
        #expect(reduction.state.projection?.committedCursor == ChatTranscriptCursor(rawValue: 7))
        #expect(reduction.state.committedItems == [committed])
        #expect(reduction.effects.isEmpty)
    }

    @Test func reconnectSnapshotClearsInvalidActiveContentBlock() {
        let state = ChatClientSyncState(chatID: ChatID(rawValue: "chat-1"))
        let invalid = ChatActiveContentBlock(
            messageID: ChatMessageID(rawValue: "missing"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applySnapshot(makeSnapshot(sequence: 1, activeContentBlock: invalid))
        )

        #expect(reduction.state.projection?.activeContentBlock == nil)
    }

    @Test func snapshotKeepsMatchingActiveContentBlock() {
        let message = makeMessage(messageID: "assistant-stream", role: .assistant, text: "Hello")
        let block = ChatActiveContentBlock(
            messageID: ChatMessageID(rawValue: "assistant-stream"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .assistant
        )
        let reduction = ChatClientSyncReducer.reduce(
            ChatClientSyncState(chatID: ChatID(rawValue: "chat-1")),
            .applySnapshot(makeSnapshot(sequence: 1, overlay: [message], activeContentBlock: block))
        )

        #expect(reduction.state.projection?.activeContentBlock == block)
    }

    @Test func canonicalHistoryReplacesOverlappingLegacyOverlay() {
        let timestamp = Date(timeIntervalSince1970: 1)
        let canonical = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "chat-transcript-v47:systemNotice:chat-1:1"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: timestamp
        ))
        let legacy = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "chat-wire-v1:systemNotice:chat-1:generation-1:1:0"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: timestamp
        ))
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 1, overlay: [legacy]),
            committedItems: [makePersisted(cursor: 1, item: canonical)],
            loadedCommittedCursor: ChatTranscriptCursor(rawValue: 1),
            syncStatus: .synchronized
        )

        #expect(state.displayTranscriptItems == [canonical])
    }

    @Test func legacyOverlayWithoutProvenanceIsAnomalousAndCanonicalWins() {
        let timestamp = Date(timeIntervalSince1970: 1)
        let canonical = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "chat-transcript-v47:systemNotice:chat-1:1"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: timestamp
        ))
        let unprovenancedLegacy = ChatTranscriptItem.systemNotice(.init(
            noticeID: ChatTranscriptNoticeID(rawValue: "chat-wire-v1:systemNotice:chat-1:generation-1:1:0"),
            turnID: nil,
            kind: .session,
            title: "Started",
            message: "Ready",
            createdAt: timestamp
        ))
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 2, overlay: [unprovenancedLegacy]),
            syncStatus: .synchronized
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .appendCommittedHistory(
                items: [makePersisted(cursor: 1, item: canonical)],
                loadedCursor: ChatTranscriptCursor(rawValue: 1)
            )
        )

        #expect(reduction.anomalies == [
            .legacyOverlayWithoutProvenance(itemKind: .systemNotice, sourceOrdinal: 0),
        ])
        #expect(reduction.state.projection?.transcriptOverlay.isEmpty == true)
        #expect(reduction.state.displayTranscriptItems == [canonical])
    }

    @Test func appendCommittedHistoryPrunesMatchingOverlay() {
        let overlayItem = makeMessage(role: .user, text: "hello")
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(
                sequence: 2,
                overlay: [overlayItem],
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ),
            syncStatus: .synchronized
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .appendCommittedHistory(
                items: [makePersisted(cursor: 1, item: overlayItem)],
                loadedCursor: ChatTranscriptCursor(rawValue: 1)
            )
        )

        #expect(reduction.state.committedItems.count == 1)
        #expect(reduction.state.projection?.transcriptOverlay.isEmpty == true)
        #expect(reduction.state.displayTranscriptItems == [overlayItem])
    }

    @Test func completedTerminalUpdatePreservesLongerOverlayUntilCommittedHistoryReloads() {
        let partialCommitted = makePersisted(
            cursor: 1,
            item: makeMessage(
                messageID: "assistant-stream",
                role: .assistant,
                text: "Hel"
            )
        )
        let longerOverlay = makeMessage(
            messageID: "assistant-stream",
            role: .assistant,
            text: "Hello world"
        )
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(
                sequence: 4,
                lifecycle: .ready,
                activeTurn: makeActiveTurn(state: .responding),
                overlay: [longerOverlay],
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ),
            committedItems: [partialCommitted],
            loadedCommittedCursor: ChatTranscriptCursor(rawValue: 1),
            syncStatus: .synchronized
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(
                sequence: 5,
                reason: .sessionEvent(.completed(turnID: ChatTurnID(rawValue: "turn-1"))),
                lifecycle: .closed,
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ))
        )

        #expect(reduction.state.displayTranscriptItems == [longerOverlay])
    }

    @Test func failedTerminalUpdatePreservesLongerOverlayAndFailureUntilCommittedHistoryReloads() {
        let partialCommitted = makePersisted(
            cursor: 1,
            item: makeMessage(
                messageID: "assistant-stream",
                role: .assistant,
                text: "Par"
            )
        )
        let longerOverlay = makeMessage(
            messageID: "assistant-stream",
            role: .assistant,
            text: "Partial answer"
        )
        let failure = ChatTranscriptItem.turnFailure(
            ChatTranscriptTurnFailureItem(
                failureID: ChatTranscriptFailureID(rawValue: "failure-1"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                category: .runtimeError,
                message: "boom",
                createdAt: Date(timeIntervalSince1970: 40)
            )
        )
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(
                sequence: 4,
                lifecycle: .ready,
                activeTurn: makeActiveTurn(state: .responding),
                overlay: [longerOverlay],
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ),
            committedItems: [partialCommitted],
            loadedCommittedCursor: ChatTranscriptCursor(rawValue: 1),
            syncStatus: .synchronized
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(
                sequence: 5,
                reason: .sessionEvent(.failed(
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    failureID: ChatTranscriptFailureID(rawValue: "failure-1"),
                    category: .runtimeError,
                    message: "boom",
                    createdAt: Date(timeIntervalSince1970: 40)
                )),
                lifecycle: .ready,
                activeTurn: makeActiveTurn(state: .terminal(.failed(
                    category: .runtimeError,
                    message: "boom"
                ))),
                overlay: [failure],
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ))
        )

        #expect(reduction.state.displayTranscriptItems == [longerOverlay, failure])
    }

    @Test func cancelledTerminalUpdatePreservesLongerOverlayUntilCommittedHistoryReloads() {
        let partialCommitted = makePersisted(
            cursor: 1,
            item: makeMessage(
                messageID: "assistant-stream",
                role: .assistant,
                text: "Can"
            )
        )
        let longerOverlay = makeMessage(
            messageID: "assistant-stream",
            role: .assistant,
            text: "Cancelled answer"
        )
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(
                sequence: 4,
                lifecycle: .ready,
                activeTurn: makeActiveTurn(state: .responding),
                overlay: [longerOverlay],
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ),
            committedItems: [partialCommitted],
            loadedCommittedCursor: ChatTranscriptCursor(rawValue: 1),
            syncStatus: .synchronized
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(
                sequence: 5,
                reason: .sessionEvent(.cancelled(turnID: ChatTurnID(rawValue: "turn-1"))),
                lifecycle: .closed,
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ))
        )

        #expect(reduction.state.displayTranscriptItems == [longerOverlay])
    }

    @Test func optimisticSubmitDeduplicatesRepeatedSubmission() {
        let submission = makeSubmission()
        let base = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 2),
            syncStatus: .synchronized
        )

        let first = ChatClientSyncReducer.reduce(base, .optimisticSubmit(submission)).state
        let second = ChatClientSyncReducer.reduce(first, .optimisticSubmit(submission)).state

        #expect(first.displayTranscriptItems == [.message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: "optimistic-\(submission.turnID.rawValue)"),
                turnID: submission.turnID,
                role: .user,
                text: submission.userText,
                createdAt: submission.submittedAt
            )
        )])
        #expect(second == first)
    }

    @Test func optimisticSubmitFailurePreservesAuthoritativeReadyLifecycle() {
        let submission = makeSubmission()
        let base = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 2, lifecycle: .ready),
            syncStatus: .synchronized
        )

        let optimistic = ChatClientSyncReducer.reduce(base, .optimisticSubmit(submission)).state
        let reduction = ChatClientSyncReducer.reduce(optimistic, .optimisticSubmitFailed(submission.turnID))

        #expect(reduction.state.projection?.lifecycle == .ready)
        #expect(reduction.state.projection?.activeTurn == nil)
        #expect(reduction.state.projection?.queuedTurns.isEmpty == true)
        #expect(reduction.state.projection?.transcriptOverlay.isEmpty == true)
    }

    @Test func authoritativeQueuedTurnPreventsOptimisticRollbackFromRemovingDurableTurn() {
        let submission = makeSubmission()
        let base = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 2, lifecycle: .ready),
            syncStatus: .synchronized
        )

        let optimistic = ChatClientSyncReducer.reduce(base, .optimisticSubmit(submission)).state
        let authoritative = ChatClientSyncReducer.reduce(
            optimistic,
            .applyUpdate(makeUpdate(
                sequence: 3,
                reason: .sessionEvent(.submitted(turnID: submission.turnID)),
                lifecycle: .ready,
                activeTurn: makeActiveTurn(state: .queued),
                overlay: [
                    makeMessage(
                        messageID: "authoritative-user",
                        role: .user,
                        text: submission.userText
                    )
                ]
            ))
        ).state
        let rolledBack = ChatClientSyncReducer.reduce(
            authoritative,
            .optimisticSubmitFailed(submission.turnID)
        ).state

        #expect(rolledBack.projection?.lifecycle == .ready)
        #expect(rolledBack.projection?.activeTurn?.turnID == submission.turnID)
        #expect(rolledBack.projection?.activeTurn?.state == .queued)
        #expect(rolledBack.displayTranscriptItems == [
            makeMessage(
                messageID: "authoritative-user",
                role: .user,
                text: submission.userText
            )
        ])
    }

    @Test func compactTranscriptUpdateRebuildsProjectionOverlayFromTranscriptDelta() {
        let currentOverlay = makeMessage(
            messageID: "assistant-stream",
            role: .assistant,
            text: "Hel"
        )
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(
                sequence: 4,
                lifecycle: .ready,
                activeTurn: makeActiveTurn(state: .responding),
                overlay: [currentOverlay],
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ),
            committedItems: [makePersisted(cursor: 1, item: currentOverlay)],
            loadedCommittedCursor: ChatTranscriptCursor(rawValue: 1),
            syncStatus: .synchronized
        )

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(makeUpdate(
                sequence: 5,
                reason: .sessionEvent(.transcriptChanged([
                    .messageReplacement(
                        messageID: ChatMessageID(rawValue: "assistant-stream"),
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        role: .assistant,
                        text: "Hello world",
                        createdAt: Date(timeIntervalSince1970: 20)
                    )
                ])),
                lifecycle: .ready,
                activeTurn: makeActiveTurn(state: .responding),
                committedCursor: ChatTranscriptCursor(rawValue: 1)
            ))
        )

        #expect(reduction.state.displayTranscriptItems == [
            makeMessage(
                messageID: "assistant-stream",
                role: .assistant,
                text: "Hello world"
            )
        ])
    }

    @Test func persistedOnlyBaselineAcceptsFirstLiveGenerationUpdate() {
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(
                sequence: 0,
                generation: "persisted-chat-1",
                lifecycle: .closed
            ),
            syncStatus: .synchronized
        )

        let update = makeUpdate(
            sequence: 1,
            generation: "generation-live",
            reason: .sessionEvent(.started(turnID: ChatTurnID(rawValue: "turn-1")))
        )
        let reduction = ChatClientSyncReducer.reduce(state, .applyUpdate(update))

        #expect(reduction.state.projection == update.projection)
        #expect(reduction.state.syncStatus == .synchronized)
        #expect(reduction.effects.isEmpty)
    }

    @Test func duplicateCommittedUserRowsDoNotCollapseOrTrap() {
        let first = makePersisted(
            cursor: 1,
            item: makeMessage(role: .user, text: "first")
        )
        let second = PersistedChatTranscriptItem(
            cursor: ChatTranscriptCursor(rawValue: 2),
            item: .message(
                ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "user-duplicate"),
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    role: .user,
                    text: "first retry",
                    createdAt: Date(timeIntervalSince1970: 31)
                )
            ),
            projectedEventJSON: nil,
            projectedPlainText: "first retry",
            createdAt: Date(timeIntervalSince1970: 31)
        )

        let reduction = ChatClientSyncReducer.reduce(
            ChatClientSyncState(
                chatID: ChatID(rawValue: "chat-1"),
                projection: makeProjection(sequence: 2),
                syncStatus: .synchronized
            ),
            .appendCommittedHistory(
                items: [first, second],
                loadedCursor: ChatTranscriptCursor(rawValue: 2)
            )
        )

        #expect(reduction.state.committedItems.map(\.cursor.rawValue) == [1, 2])
        #expect(reduction.state.displayTranscriptItems.count == 2)
    }

    @Test func terminalSequenceUpdateReplacesRespondingProjectionWithClosedProjection() {
        let state = ChatClientSyncState(
            chatID: ChatID(rawValue: "chat-1"),
            projection: makeProjection(sequence: 4, activeTurn: makeActiveTurn(state: .responding)),
            syncStatus: .synchronized
        )
        let terminal = makeProjection(sequence: 5, lifecycle: .closed, activeTurn: nil)

        let reduction = ChatClientSyncReducer.reduce(
            state,
            .applyUpdate(ChatSyncUpdate(reason: .sessionEvent(.completed(turnID: ChatTurnID(rawValue: "turn-1"))), projection: terminal))
        )

        #expect(reduction.state.projection == terminal)
        #expect(reduction.state.syncStatus == .synchronized)
        #expect(reduction.state.projection?.activeTurn == nil)
    }

    private func makeSnapshot(
        sequence: Int64,
        generation: String = "generation-1",
        lifecycle: ChatSessionLifecycle = .ready,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        committedCursor: ChatTranscriptCursor = .zero,
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState(),
        activeContentBlock: ChatActiveContentBlock? = nil
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: makeProjection(
                sequence: sequence,
                generation: generation,
                lifecycle: lifecycle,
                activeTurn: activeTurn,
                overlay: overlay,
                committedCursor: committedCursor,
                diagnostics: diagnostics,
                activeContentBlock: activeContentBlock
            )
        )
    }

    private func makeProjection(
        sequence: Int64,
        generation: String = "generation-1",
        lifecycle: ChatSessionLifecycle = .ready,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        committedCursor: ChatTranscriptCursor = .zero,
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState(),
        activeContentBlock: ChatActiveContentBlock? = nil
    ) -> ChatSyncProjection {
        ChatSyncProjection(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: generation),
            lifecycle: lifecycle,
            activeTurn: activeTurn,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(
                providerID: ProviderID(rawValue: "provider-1"),
                modelID: ModelID(rawValue: "model-1"),
                providerSessionID: nil
            ),
            usage: nil,
            diagnostics: diagnostics,
            activeContentBlock: activeContentBlock,
            transcriptOverlay: overlay,
            committedCursor: committedCursor,
            lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
            pendingPermission: nil,
            runMetadata: .empty
        )
    }

    private func makeUpdate(
        sequence: Int64,
        generation: String = "generation-1",
        reason: ChatSyncUpdateReason = .sessionEvent(.started(turnID: ChatTurnID(rawValue: "turn-1"))),
        lifecycle: ChatSessionLifecycle = .ready,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        committedCursor: ChatTranscriptCursor = .zero
    ) -> ChatSyncUpdate {
        ChatSyncUpdate(
            reason: reason,
            projection: makeProjection(
                sequence: sequence,
                generation: generation,
                lifecycle: lifecycle,
                activeTurn: activeTurn,
                overlay: overlay,
                committedCursor: committedCursor
            )
        )
    }

    private func makeSubmission() -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "command-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "hello",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makeActiveTurn(state: ChatTurnState) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: "turn-1"),
            commandID: ChatCommandID(rawValue: "command-1"),
            visibleText: "visible",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10),
            state: state
        )
    }

    private func makeMessage(
        messageID: String? = nil,
        role: ChatTranscriptMessageRole,
        text: String
    ) -> ChatTranscriptItem {
        .message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: messageID ?? "\(role.rawValue)-\(text)"),
                turnID: ChatTurnID(rawValue: "turn-1"),
                role: role,
                text: text,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
    }

    private func makePersisted(
        cursor: Int64,
        item: ChatTranscriptItem
    ) -> PersistedChatTranscriptItem {
        let plainText: String = switch item {
        case .message(let message):
            message.text
        case .toolCall(let toolCall):
            toolCall.toolName
        case .systemNotice(let notice):
            notice.message
        case .turnFailure(let failure):
            failure.message
        }
        return PersistedChatTranscriptItem(
            cursor: ChatTranscriptCursor(rawValue: cursor),
            item: item,
            projectedEventJSON: nil,
            projectedPlainText: plainText,
            createdAt: Date(timeIntervalSince1970: 30)
        )
    }
}
#endif
