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

    @Test func terminalSequenceUpdateClearsAnsweringState() {
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
    }

    private func makeSnapshot(
        sequence: Int64,
        generation: String = "generation-1",
        lifecycle: ChatSessionLifecycle = .ready,
        activeTurn: ChatTurnSnapshot? = nil,
        overlay: [ChatTranscriptItem] = [],
        committedCursor: ChatTranscriptCursor = .zero,
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState()
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: makeProjection(
                sequence: sequence,
                generation: generation,
                lifecycle: lifecycle,
                activeTurn: activeTurn,
                overlay: overlay,
                committedCursor: committedCursor,
                diagnostics: diagnostics
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
        diagnostics: ChatDiagnosticsState = ChatDiagnosticsState()
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
        overlay: [ChatTranscriptItem] = []
    ) -> ChatSyncUpdate {
        ChatSyncUpdate(
            reason: reason,
            projection: makeProjection(
                sequence: sequence,
                generation: generation,
                overlay: overlay
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
        role: ChatTranscriptMessageRole,
        text: String
    ) -> ChatTranscriptItem {
        .message(
            ChatTranscriptMessageItem(
                messageID: ChatMessageID(rawValue: "\(role.rawValue)-\(text)"),
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
