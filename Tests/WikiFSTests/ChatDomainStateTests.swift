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
        sequence: Int64 = 0,
        queuedTurns: [ChatQueuedTurn] = [],
        terminalContinuationPolicy: ChatTerminalContinuationPolicy? = nil
    ) -> ChatRuntimeSnapshot {
        ChatRuntimeSnapshot(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            lifecycle: lifecycle,
            activeTurn: activeTurn,
            queuedTurns: queuedTurns,
            attention: attention,
            capabilities: ChatCapabilitySet.unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transientTranscriptOverlay: [],
            lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
            terminalContinuationPolicy: terminalContinuationPolicy
        )
    }

    private func makeTurn(_ state: ChatTurnState, turnID: String = "turn-1") -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: turnID),
            commandID: ChatCommandID(rawValue: "command-\(turnID)"),
            visibleText: turnID,
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10),
            state: state
        )
    }

    private func makeQueuedTurn(_ turnID: String) -> ChatQueuedTurn {
        ChatQueuedTurn(ordinal: 0, submission: makeSubmission(turnID: turnID, commandID: "command-\(turnID)"))
    }

    private func allTurnStates() -> [ChatTurnState] {
        [
            .queued,
            .submitting,
            .responding,
            .awaitingPermission(PermissionRequestID(rawValue: "permission-1")),
            .cancelling,
            .terminal(.completed),
            .terminal(.failed(category: .runtimeError, message: "failed")),
            .terminal(.cancelled),
            .terminal(.interrupted(message: "interrupted"))
        ]
    }

    @Test(arguments: ["turn-1", "turn-2"])
    func cancellationTransitionTableValidIdentity(turnID: String) {
        let snapshot = makeSnapshot(lifecycle: .ready, activeTurn: makeTurn(.responding, turnID: turnID))
        let update = ChatSessionUpdate(chatID: snapshot.chatID, generation: snapshot.generation, sequence: .init(rawValue: 1), payload: .cancellationRequested(turnID: .init(rawValue: turnID)))
        guard case .applied(let result) = ChatSessionMachine.apply(update, to: snapshot) else { Issue.record("valid cancellation should apply"); return }
        #expect(result.activeTurn?.state == .cancelling)
    }

    @Test(arguments: ["queued", "submitting", "responding", "awaitingPermission", "cancelling", "completed", "failed", "cancelled", "interrupted"])
    func cancellationTransitionTableIsExhaustive(stateName: String) {
        let names = ["queued", "submitting", "responding", "awaitingPermission", "cancelling", "completed", "failed", "cancelled", "interrupted"]
        guard let index = names.firstIndex(of: stateName) else { Issue.record("missing fixture"); return }
        let state = allTurnStates()[index]
        let snapshot = makeSnapshot(lifecycle: .ready, activeTurn: makeTurn(state))
        let update = ChatSessionUpdate(chatID: snapshot.chatID, generation: snapshot.generation, sequence: .init(rawValue: 1), payload: .cancellationRequested(turnID: .init(rawValue: "turn-1")))
        switch state {
        case .queued, .submitting, .responding, .awaitingPermission, .cancelling:
            guard case .applied(let result) = ChatSessionMachine.apply(update, to: snapshot) else { Issue.record("nonterminal cancellation should apply"); return }
            #expect(result.activeTurn?.state == (state == .cancelling ? .cancelling : .cancelling))
        case .terminal:
            #expect(ChatSessionMachine.apply(update, to: snapshot) == .rejected(.illegalTransition(payload: update.payload)))
        }
    }

    @Test func cancellationPromotesFIFOAndRetainPolicyKeepsFollowersQueued() {
        let first = makeTurn(.cancelling)
        let follower = makeQueuedTurn("turn-2")
        for policy in [ChatTerminalContinuationPolicy.fifo, .retainQueuedTurns] {
            let snapshot = makeSnapshot(lifecycle: .ready, activeTurn: first, queuedTurns: [follower], terminalContinuationPolicy: policy)
            let update = ChatSessionUpdate(chatID: snapshot.chatID, generation: snapshot.generation, sequence: .init(rawValue: 1), payload: .cancelled(turnID: first.turnID))
            guard case .applied(let result) = ChatSessionMachine.apply(update, to: snapshot) else { Issue.record("terminal cancellation should apply"); continue }
            if policy == .fifo { #expect(result.activeTurn?.turnID == follower.submission.turnID); #expect(result.queuedTurns.isEmpty) }
            else { #expect(result.activeTurn?.state == .terminal(.cancelled)); #expect(result.queuedTurns == [follower]) }
        }
    }

    @Test func cancellationRequestWrongTurnStaleGenerationAndDuplicateTerminalAreRejected() {
        let snapshot = makeSnapshot(lifecycle: .ready, activeTurn: makeTurn(.cancelling), sequence: 1)
        let wrong = ChatSessionUpdate(chatID: snapshot.chatID, generation: snapshot.generation, sequence: .init(rawValue: 2), payload: .cancellationRequested(turnID: .init(rawValue: "wrong")))
        #expect(ChatSessionMachine.apply(wrong, to: snapshot) == .rejected(.illegalTransition(payload: wrong.payload)))
        let stale = ChatSessionUpdate(chatID: snapshot.chatID, generation: .init(rawValue: "old"), sequence: .init(rawValue: 2), payload: .cancelled(turnID: snapshot.activeTurn!.turnID))
        #expect(ChatSessionMachine.apply(stale, to: snapshot) == .rejected(.staleGeneration(expected: snapshot.generation, received: stale.generation)))
        let duplicate = ChatSessionUpdate(chatID: snapshot.chatID, generation: snapshot.generation, sequence: .init(rawValue: 2), payload: .cancelled(turnID: snapshot.activeTurn!.turnID))
        let terminal = ChatSessionMachine.apply(duplicate, to: snapshot)
        guard case .applied(let cancelled) = terminal else { Issue.record("first terminal should apply"); return }
        let repeated = ChatSessionMachine.apply(ChatSessionUpdate(chatID: snapshot.chatID, generation: snapshot.generation, sequence: .init(rawValue: 3), payload: .cancelled(turnID: snapshot.activeTurn!.turnID)), to: cancelled)
        #expect(repeated == .rejected(.illegalTransition(payload: .cancelled(turnID: snapshot.activeTurn!.turnID))))
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

    @Test func replayBufferTreatsFreshInitialWatermarkAsInSync() {
        let buffer = ChatUpdateReplayBuffer(capacity: 2)
        #expect(buffer.replay(after: .initial) == .available([]))
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

        #expect(
            ChatSessionMachine.apply(staleGeneration, to: snapshot)
                == .rejected(.staleGeneration(
                    expected: ChatSessionGenerationID(rawValue: "generation-1"),
                    received: ChatSessionGenerationID(rawValue: "generation-OLD")
                ))
        )
        #expect(
            ChatSessionMachine.apply(duplicateSequence, to: snapshot)
                == .rejected(.duplicateSequence(
                    lastIncluded: ChatUpdateSequence(rawValue: 2),
                    received: ChatUpdateSequence(rawValue: 2)
                ))
        )
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
        #expect(ChatSessionMachine.apply(illegalStartedFirst, to: base) == .rejected(.illegalTransition(payload: .started(turnID: ChatTurnID(rawValue: "turn-1")))))

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
