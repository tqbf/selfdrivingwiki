#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSTypes

struct ChatDomainStateTests {
    private func makeSubmission(
        turnID: String = "turn-1",
        commandID: String = "command-1",
        text: String = "Hello"
    ) -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: commandID),
            turnID: ChatTurnID(rawValue: turnID),
            userText: text,
            contextReferences: [.page(PageID(rawValue: "page-1"))],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makeSnapshot(
        lifecycle: ChatSessionLifecycle = .starting,
        activeTurn: ChatTurnSnapshot? = nil,
        attention: ChatAttentionState = .none,
        sequence: Int64 = 0
    ) -> ChatRuntimeSnapshot {
        ChatRuntimeSnapshot(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            lifecycle: lifecycle,
            activeTurn: activeTurn,
            queuedTurns: [],
            attention: attention,
            capabilities: ChatCapabilitySet.unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            committedTranscriptCursor: nil,
            transientTranscriptOverlay: [],
            lastIncludedSequence: ChatUpdateSequence(rawValue: sequence)
        )
    }

    @Test func derivedCapabilitiesSeparateSubmitQueueCancelAndPermission() {
        let activeTurn = ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: "turn-1"),
            commandID: ChatCommandID(rawValue: "command-1"),
            visibleText: "Hello",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 0),
            state: .awaitingPermission(PermissionRequestID(rawValue: "permission-1"))
        )
        let snapshot = makeSnapshot(
            lifecycle: .ready,
            activeTurn: activeTurn,
            attention: .permissionRequired(PermissionRequestID(rawValue: "permission-1"))
        )

        #expect(snapshot.canSubmit == false)
        #expect(snapshot.canQueue == true)
        #expect(snapshot.canCancel == true)
        #expect(snapshot.canResolvePermission == true)
        #expect(snapshot.showsResponding == true)
    }

    @Test func replayBufferRejectsEvictedWatermark() {
        var buffer = ChatUpdateReplayBuffer(capacity: 2)
        buffer.append(ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 10),
            payload: .recovering
        ))
        buffer.append(ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 11),
            payload: .sessionClosed
        ))

        #expect(buffer.replay(after: ChatUpdateSequence(rawValue: 1)) == .unavailable)
    }

    @Test func replayBufferReturnsStrictlyNewerUpdates() {
        var buffer = ChatUpdateReplayBuffer(capacity: 3)
        let first = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 2),
            payload: .recovering
        )
        let second = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 3),
            payload: .sessionClosed
        )
        buffer.append(first)
        buffer.append(second)

        #expect(buffer.replay(after: ChatUpdateSequence(rawValue: 2)) == .available([second]))
    }

    @Test func sessionMachineRejectsStaleGenerationAndDuplicateSequence() {
        let snapshot = makeSnapshot(lifecycle: .starting, sequence: 2)
        let staleGeneration = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-OLD"),
            sequence: ChatUpdateSequence(rawValue: 3),
            payload: .recovering
        )
        let duplicateSequence = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 2),
            payload: .recovering
        )

        #expect(ChatSessionMachine.apply(staleGeneration, to: snapshot) == .ignored)
        #expect(ChatSessionMachine.apply(duplicateSequence, to: snapshot) == .ignored)
    }

    @Test func sessionMachineAllowsDocumentedTurnTransitionsOnly() throws {
        let queued = ChatQueuedTurn(ordinal: 0, submission: makeSubmission())
        let queuedUpdate = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 1),
            payload: .queued(queued)
        )
        let submittedUpdate = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 2),
            payload: .submitted(turnID: ChatTurnID(rawValue: "turn-1"))
        )
        let startedUpdate = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 3),
            payload: .started(turnID: ChatTurnID(rawValue: "turn-1"))
        )
        let illegalStartedFirst = ChatSessionUpdate(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            sequence: ChatUpdateSequence(rawValue: 1),
            payload: .started(turnID: ChatTurnID(rawValue: "turn-1"))
        )

        let base = makeSnapshot()
        #expect(ChatSessionMachine.apply(illegalStartedFirst, to: base) == .ignored)

        let queuedResult = ChatSessionMachine.apply(queuedUpdate, to: base)
        guard case .applied(let queuedSnapshot) = queuedResult else {
            Issue.record("queued update should apply")
            return
        }
        #expect(queuedSnapshot.activeTurn?.state == .queued)

        let submittedResult = ChatSessionMachine.apply(submittedUpdate, to: queuedSnapshot)
        guard case .applied(let submittedSnapshot) = submittedResult else {
            Issue.record("submitted update should apply")
            return
        }
        #expect(submittedSnapshot.activeTurn?.state == .submitting)

        let startedResult = ChatSessionMachine.apply(startedUpdate, to: submittedSnapshot)
        guard case .applied(let startedSnapshot) = startedResult else {
            Issue.record("started update should apply")
            return
        }
        #expect(startedSnapshot.activeTurn?.state == .responding)
    }
}
#endif
