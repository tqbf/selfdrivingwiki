#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSTypes

struct ChatDomainAuditRegressionTests {
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

    private func makeQueuedTurn(
        ordinal: Int,
        turnID: String,
        commandID: String
    ) -> ChatQueuedTurn {
        ChatQueuedTurn(
            ordinal: ordinal,
            submission: makeSubmission(turnID: turnID, commandID: commandID)
        )
    }

    private func makeActiveTurn(
        turnID: String = "turn-1",
        commandID: String = "command-1",
        state: ChatTurnState
    ) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: ChatTurnID(rawValue: turnID),
            commandID: ChatCommandID(rawValue: commandID),
            visibleText: "Hello",
            contextReferences: [.page(PageID(rawValue: "page-1"))],
            submittedAt: Date(timeIntervalSince1970: 10),
            state: state
        )
    }

    private func makeUsage(totalTokens: Int = 30) -> SessionUsage {
        SessionUsage(
            inputTokens: 10,
            outputTokens: 20,
            totalTokens: totalTokens,
            cachedReadTokens: 1,
            thoughtTokens: 2,
            cost: 0.5,
            currency: "USD",
            contextUsed: 3,
            contextSize: 4,
            providerLabel: "Claude",
            modelId: "sonnet",
            modelName: "Claude Sonnet",
            thinkingLevel: "high"
        )
    }

    private func makeSnapshot(
        lifecycle: ChatSessionLifecycle = .ready,
        activeTurn: ChatTurnSnapshot? = nil,
        queuedTurns: [ChatQueuedTurn] = [],
        attention: ChatAttentionState = .none,
        overlay: [ChatTranscriptItem] = [],
        usage: SessionUsage? = nil,
        sequence: Int64 = 0
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
            usage: usage,
            diagnostics: ChatDiagnosticsState(),
            transientTranscriptOverlay: overlay,
            lastIncludedSequence: ChatUpdateSequence(rawValue: sequence)
        )
    }

    private func makeUpdate(
        sequence: Int64,
        payload: ChatSessionEventPayload,
        chatID: String = "chat-1",
        generation: String = "generation-1"
    ) -> ChatSessionUpdate {
        ChatSessionUpdate(
            chatID: ChatID(rawValue: chatID),
            generation: ChatSessionGenerationID(rawValue: generation),
            sequence: ChatUpdateSequence(rawValue: sequence),
            payload: payload
        )
    }

    @Test func failedTurnPreservesReadyLifecycleAndProducerTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 123)
        let snapshot = makeSnapshot(activeTurn: makeActiveTurn(state: .responding))

        let result = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 1,
                payload: .failed(
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    category: .runtimeError,
                    message: "boom",
                    createdAt: timestamp
                )
            ),
            to: snapshot
        )

        guard case .applied(let failedSnapshot) = result else {
            Issue.record("failed update should apply")
            return
        }

        #expect(failedSnapshot.lifecycle == .ready)
        #expect(failedSnapshot.attention == .turnFailed(ChatTurnID(rawValue: "turn-1")))
        #expect(failedSnapshot.activeTurn?.state == .terminal(.failed(category: .runtimeError, message: "boom")))

        let failureItem = failedSnapshot.transientTranscriptOverlay.last
        guard case .turnFailure(let item) = failureItem else {
            Issue.record("expected turn-failure transcript item")
            return
        }
        #expect(item.createdAt == timestamp)

        let recovering = ChatSessionMachine.apply(
            makeUpdate(sequence: 2, payload: .recovering),
            to: failedSnapshot
        )
        #expect(recovering == .applied(makeSnapshot(
            lifecycle: .recovering,
            activeTurn: makeActiveTurn(state: .terminal(.failed(category: .runtimeError, message: "boom"))),
            attention: .turnFailed(ChatTurnID(rawValue: "turn-1")),
            overlay: failedSnapshot.transientTranscriptOverlay,
            sequence: 2
        )))
    }

    @Test func replayBufferHandlesEmptyCoverageAndInt64Boundaries() throws {
        let empty = ChatUpdateReplayBuffer(capacity: 2)
        #expect(empty.replay(after: .initial) == .available([]))
        #expect(empty.replay(after: ChatUpdateSequence(rawValue: 1)) == .unavailable)

        let watermarkOnly = ChatUpdateReplayBuffer(
            capacity: 2,
            updates: [],
            highestSequence: ChatUpdateSequence(rawValue: 5)
        )
        #expect(watermarkOnly.replay(after: ChatUpdateSequence(rawValue: 5)) == .available([]))
        #expect(watermarkOnly.replay(after: ChatUpdateSequence(rawValue: 4)) == .unavailable)

        var edge = ChatUpdateReplayBuffer(capacity: 1)
        edge.append(makeUpdate(sequence: Int64.min, payload: .recovering))
        #expect(edge.replay(after: ChatUpdateSequence(rawValue: Int64.min)) == .available([]))

        #expect(throws: ChatUpdateSequence.Error.overflow(ChatUpdateSequence(rawValue: Int64.max))) {
            _ = try ChatUpdateSequence(rawValue: Int64.max).next()
        }
        #expect(try ChatUpdateSequence(rawValue: Int64.max - 1).next() == ChatUpdateSequence(rawValue: Int64.max))
    }

    @Test func queuedTurnsPromoteInArrivalOrderAfterTerminalOutcomes() {
        let base = makeSnapshot(activeTurn: makeActiveTurn(state: .responding))
        let second = makeQueuedTurn(ordinal: 1, turnID: "turn-2", commandID: "command-2")
        let third = makeQueuedTurn(ordinal: 2, turnID: "turn-3", commandID: "command-3")

        guard case .applied(let afterSecond) = ChatSessionMachine.apply(
            makeUpdate(sequence: 1, payload: .queued(second)),
            to: base
        ) else {
            Issue.record("second queued turn should apply")
            return
        }
        guard case .applied(let afterThird) = ChatSessionMachine.apply(
            makeUpdate(sequence: 2, payload: .queued(third)),
            to: afterSecond
        ) else {
            Issue.record("third queued turn should apply")
            return
        }
        #expect(afterThird.queuedTurns.map(\.submission.turnID.rawValue) == ["turn-2", "turn-3"])

        guard case .applied(let afterCompletion) = ChatSessionMachine.apply(
            makeUpdate(sequence: 3, payload: .completed(turnID: ChatTurnID(rawValue: "turn-1"))),
            to: afterThird
        ) else {
            Issue.record("completion should promote the next queued turn")
            return
        }
        #expect(afterCompletion.activeTurn?.turnID == ChatTurnID(rawValue: "turn-2"))
        #expect(afterCompletion.activeTurn?.state == .queued)
        #expect(afterCompletion.queuedTurns.map(\.submission.turnID.rawValue) == ["turn-3"])

        guard case .applied(let afterCancellation) = ChatSessionMachine.apply(
            makeUpdate(sequence: 4, payload: .cancelled(turnID: ChatTurnID(rawValue: "turn-2"))),
            to: afterCompletion
        ) else {
            Issue.record("cancellation should promote the final queued turn")
            return
        }
        #expect(afterCancellation.activeTurn?.turnID == ChatTurnID(rawValue: "turn-3"))
        #expect(afterCancellation.activeTurn?.state == .queued)
        #expect(afterCancellation.queuedTurns.isEmpty)
    }

    @Test func failedTurnWithQueuedFollowerDoesNotOrphanAttention() {
        let snapshot = makeSnapshot(
            activeTurn: makeActiveTurn(state: .responding),
            queuedTurns: [makeQueuedTurn(ordinal: 1, turnID: "turn-2", commandID: "command-2")]
        )

        let result = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 1,
                payload: .failed(
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    category: .runtimeError,
                    message: "boom",
                    createdAt: Date(timeIntervalSince1970: 20)
                )
            ),
            to: snapshot
        )

        guard case .applied(let failed) = result else {
            Issue.record("failed update should apply")
            return
        }

        #expect(failed.activeTurn?.turnID == ChatTurnID(rawValue: "turn-1"))
        #expect(failed.activeTurn?.state == .terminal(.failed(category: .runtimeError, message: "boom")))
        #expect(failed.attention == .turnFailed(ChatTurnID(rawValue: "turn-1")))
        #expect(failed.queuedTurns.map(\.submission.turnID.rawValue) == ["turn-2"])
    }

    @Test func queuedTurnAfterTerminalFailurePreservesExistingQueueArrivalOrder() {
        let snapshot = makeSnapshot(
            activeTurn: makeActiveTurn(state: .terminal(.failed(category: .runtimeError, message: "boom"))),
            queuedTurns: [makeQueuedTurn(ordinal: 1, turnID: "turn-2", commandID: "command-2")],
            attention: .turnFailed(ChatTurnID(rawValue: "turn-1"))
        )

        let result = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 1,
                payload: .queued(makeQueuedTurn(ordinal: 2, turnID: "turn-3", commandID: "command-3"))
            ),
            to: snapshot
        )

        guard case .applied(let queued) = result else {
            Issue.record("queued follower should apply")
            return
        }

        #expect(queued.activeTurn?.turnID == ChatTurnID(rawValue: "turn-1"))
        #expect(queued.queuedTurns.map(\.submission.turnID.rawValue) == ["turn-2", "turn-3"])
        #expect(queued.attention == .turnFailed(ChatTurnID(rawValue: "turn-1")))
    }

    @Test(arguments: [
        ChatSessionLifecycle.unavailable,
        .starting,
        .ready,
        .recovering,
        .closing,
        .failed,
    ])
    func sessionClosedAppliesFromEveryNonClosedLifecycle(lifecycle: ChatSessionLifecycle) {
        let snapshot = makeSnapshot(lifecycle: lifecycle, activeTurn: makeActiveTurn(state: .responding))
        let result = ChatSessionMachine.apply(
            makeUpdate(sequence: 1, payload: .sessionClosed),
            to: snapshot
        )

        guard case .applied(let closed) = result else {
            Issue.record("sessionClosed should apply from \(lifecycle)")
            return
        }
        #expect(closed.lifecycle == .closed)
        #expect(closed.activeTurn == nil)
        #expect(closed.attention == .none)
    }

    @Test func sessionReadyRecoversFromClosedLifecycle() {
        let result = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 1,
                payload: .sessionReady(
                    capabilities: .unavailable,
                    providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil)
                )
            ),
            to: makeSnapshot(lifecycle: .closed)
        )

        guard case .applied(let ready) = result else {
            Issue.record("sessionReady should recover from closed")
            return
        }

        #expect(ready.lifecycle == .ready)
    }

    @Test func sessionMachineRejectsStaleChatIDs() {
        let result = ChatSessionMachine.apply(
            makeUpdate(sequence: 1, payload: .recovering, chatID: "chat-2"),
            to: makeSnapshot()
        )

        #expect(result == .rejected(.staleChat(
            expected: ChatID(rawValue: "chat-1"),
            received: ChatID(rawValue: "chat-2")
        )))
    }

    @Test func sessionMachineAppliesPermissionAndTranscriptTransitions() {
        let requestID = PermissionRequestID(rawValue: "permission-1")
        let snapshot = makeSnapshot(
            activeTurn: makeActiveTurn(state: .responding),
            sequence: 2
        )

        guard case .applied(let afterTranscript) = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 3,
                payload: .transcriptChanged([
                    .messageReplacement(
                        messageID: ChatMessageID(rawValue: "message-1"),
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        role: .assistant,
                        text: "Hello",
                        createdAt: Date(timeIntervalSince1970: 1)
                    )
                ])
            ),
            to: snapshot
        ) else {
            Issue.record("transcript delta should apply")
            return
        }
        #expect(afterTranscript.transientTranscriptOverlay.count == 1)

        guard case .applied(let afterRequest) = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 4,
                payload: .permissionRequested(
                    ChatPendingPermissionRequest(
                        requestID: requestID,
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        toolCallID: ToolCallID(rawValue: "tool-1"),
                        title: "Edit file",
                        message: "Allow?",
                        options: []
                    )
                )
            ),
            to: afterTranscript
        ) else {
            Issue.record("permission request should apply")
            return
        }
        #expect(afterRequest.activeTurn?.state == .awaitingPermission(requestID))
        #expect(afterRequest.attention == .permissionRequired(requestID))

        guard case .applied(let afterResolution) = ChatSessionMachine.apply(
            makeUpdate(sequence: 5, payload: .permissionResolved(requestID)),
            to: afterRequest
        ) else {
            Issue.record("permission resolution should apply")
            return
        }
        #expect(afterResolution.activeTurn?.state == .responding)
        #expect(afterResolution.attention == .none)
    }

    @Test func transcriptChangedReplacementCoalescesExistingStreamingMessageAcrossSequences() {
        let snapshot = makeSnapshot(
            activeTurn: makeActiveTurn(state: .responding),
            sequence: 0
        )

        guard case .applied(let afterDelta) = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 1,
                payload: .transcriptChanged([
                    .messageDelta(
                        messageID: ChatMessageID(rawValue: "message-1"),
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        role: .assistant,
                        delta: "Hel",
                        createdAt: Date(timeIntervalSince1970: 1)
                    )
                ])
            ),
            to: snapshot
        ) else {
            Issue.record("streaming delta should apply")
            return
        }

        guard case .applied(let afterReplacement) = ChatSessionMachine.apply(
            makeUpdate(
                sequence: 2,
                payload: .transcriptChanged([
                    .messageReplacement(
                        messageID: ChatMessageID(rawValue: "message-1"),
                        turnID: ChatTurnID(rawValue: "turn-1"),
                        role: .assistant,
                        text: "Hello",
                        createdAt: Date(timeIntervalSince1970: 1)
                    )
                ])
            ),
            to: afterDelta
        ) else {
            Issue.record("replacement should apply")
            return
        }

        #expect(afterReplacement.transientTranscriptOverlay.count == 1)
        guard case .message(let item) = afterReplacement.transientTranscriptOverlay[0] else {
            Issue.record("expected a single coalesced message row")
            return
        }
        #expect(item.messageID == ChatMessageID(rawValue: "message-1"))
        #expect(item.text == "Hello")
    }

    @Test func sessionReadyTransitionsFromUnavailableAndPreservesState() {
        let queued = makeQueuedTurn(ordinal: 1, turnID: "turn-2", commandID: "command-2")
        let snapshot = makeSnapshot(
            lifecycle: .unavailable,
            activeTurn: makeActiveTurn(state: .queued),
            queuedTurns: [queued],
            attention: .turnFailed(ChatTurnID(rawValue: "turn-1")),
            overlay: [.systemNotice(ChatTranscriptSystemNoticeItem(
                turnID: nil,
                kind: .session,
                title: "Recovering",
                message: "wait",
                createdAt: Date(timeIntervalSince1970: 1)
            ))],
            sequence: 1
        )
        let capabilities = ChatCapabilitySet(
            supportsResume: true,
            supportsClose: true,
            availableModes: [ChatModeID(rawValue: "chat")],
            availableModels: [ModelID(rawValue: "model-1")],
            configurationOptions: [],
            supportsReasoning: true,
            supportsToolCalls: true,
            supportsPermissions: true
        )
        let providerState = ChatProviderState(
            providerID: ProviderID(rawValue: "provider-1"),
            modelID: ModelID(rawValue: "model-1"),
            providerSessionID: AcpSessionID(rawValue: "session-1")
        )

        let result = ChatSessionMachine.apply(
            makeUpdate(sequence: 2, payload: .sessionReady(capabilities: capabilities, providerState: providerState)),
            to: snapshot
        )

        guard case .applied(let ready) = result else {
            Issue.record("sessionReady should apply from unavailable")
            return
        }
        #expect(ready.lifecycle == .ready)
        #expect(ready.activeTurn == snapshot.activeTurn)
        #expect(ready.queuedTurns == [queued])
        #expect(ready.attention == snapshot.attention)
        #expect(ready.transientTranscriptOverlay == snapshot.transientTranscriptOverlay)
        #expect(ready.capabilities == capabilities)
        #expect(ready.providerState == providerState)
    }

    @Test func snapshotEqualityCoversUsageOverlayAndSequence() {
        let overlay = [
            ChatTranscriptItem.message(
                ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "message-1"),
                    turnID: ChatTurnID(rawValue: "turn-1"),
                    role: .assistant,
                    text: "Hello",
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            )
        ]
        let first = makeSnapshot(
            activeTurn: makeActiveTurn(state: .queued),
            overlay: overlay,
            usage: makeUsage(),
            sequence: 5
        )
        let second = makeSnapshot(
            activeTurn: makeActiveTurn(state: .queued),
            overlay: overlay,
            usage: makeUsage(),
            sequence: 5
        )
        let changedUsage = makeSnapshot(
            activeTurn: makeActiveTurn(state: .queued),
            overlay: overlay,
            usage: makeUsage(totalTokens: 31),
            sequence: 5
        )
        let changedSequence = makeSnapshot(
            activeTurn: makeActiveTurn(state: .queued),
            overlay: overlay,
            usage: makeUsage(),
            sequence: 6
        )

        #expect(first == second)
        #expect(first != changedUsage)
        #expect(first != changedSequence)
    }

    @Test func capabilityDerivationsCoverFalseBranches() {
        let noTurn = makeSnapshot(lifecycle: .ready, activeTurn: nil)
        #expect(noTurn.canSubmit == true)
        #expect(noTurn.canQueue == false)
        #expect(noTurn.canCancel == false)
        #expect(noTurn.canResolvePermission == false)
        #expect(noTurn.showsResponding == false)

        let closed = makeSnapshot(lifecycle: .closed, activeTurn: makeActiveTurn(state: .queued))
        #expect(closed.canSubmit == false)
        #expect(closed.canQueue == false)
    }

    @Test(arguments: [
        ChatTranscriptItem.message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: "message-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            role: .user,
            text: "Hello",
            createdAt: Date(timeIntervalSince1970: 1)
        )),
        ChatTranscriptItem.toolCall(ChatTranscriptToolCallItem(
            toolCallID: ToolCallID(rawValue: "tool-1"),
            turnID: ChatTurnID(rawValue: "turn-2"),
            toolName: "Edit file",
            status: .running,
            detail: nil,
            permissionRequestID: nil,
            updatedAt: Date(timeIntervalSince1970: 2)
        )),
        ChatTranscriptItem.systemNotice(ChatTranscriptSystemNoticeItem(
            turnID: ChatTurnID(rawValue: "turn-3"),
            kind: .diagnostics,
            title: "Notice",
            message: "Details",
            createdAt: Date(timeIntervalSince1970: 3)
        )),
        ChatTranscriptItem.turnFailure(ChatTranscriptTurnFailureItem(
            turnID: ChatTurnID(rawValue: "turn-4"),
            category: .transportError,
            message: "socket closed",
            createdAt: Date(timeIntervalSince1970: 4)
        )),
    ])
    func transcriptItemTurnIDProjectionMatchesStoredTurn(item: ChatTranscriptItem) {
        switch item {
        case .message(let message):
            #expect(item.turnID == message.turnID)
        case .toolCall(let toolCall):
            #expect(item.turnID == toolCall.turnID)
        case .systemNotice(let notice):
            #expect(item.turnID == notice.turnID)
        case .turnFailure(let failure):
            #expect(item.turnID == failure.turnID)
        }
    }

    @Test(arguments: [
        ChatPermissionVisualIntent.default,
        .accent,
        .destructive,
        .unknown("experimental-glow"),
    ])
    func permissionVisualIntentRoundTrips(intent: ChatPermissionVisualIntent) throws {
        let data = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(ChatPermissionVisualIntent.self, from: data)
        #expect(decoded == intent)
    }

    @Test func permissionVisualIntentUnknownValueDecodesLosslessly() throws {
        let decoded = try JSONDecoder().decode(
            ChatPermissionVisualIntent.self,
            from: Data(#""vendor-custom-warning""#.utf8)
        )
        #expect(decoded == .unknown("vendor-custom-warning"))
    }

    @Test func chatSessionCommandsRoundTripEveryCase() throws {
        let queuedTurn = makeQueuedTurn(ordinal: 1, turnID: "turn-2", commandID: "command-2")
        let commands: [ChatSessionCommand] = [
            .createChat(commandID: ChatCommandID(rawValue: "command-create")),
            .submitTurn(makeSubmission(turnID: "turn-submit", commandID: "command-submit")),
            .cancelTurn(commandID: ChatCommandID(rawValue: "command-cancel"), turnID: nil),
            .cancelTurn(commandID: ChatCommandID(rawValue: "command-cancel-2"), turnID: ChatTurnID(rawValue: "turn-cancel")),
            .editQueuedTurn(turn: queuedTurn),
            .removeQueuedTurn(commandID: ChatCommandID(rawValue: "command-remove"), turnID: ChatTurnID(rawValue: "turn-remove")),
            .retryInterruptedTurn(commandID: ChatCommandID(rawValue: "command-retry"), priorTurnID: ChatTurnID(rawValue: "turn-retry")),
            .resolvePermission(ChatPermissionResolution(
                requestID: PermissionRequestID(rawValue: "permission-1"),
                optionID: PermissionOptionID(rawValue: "option-1")
            )),
            .setConfiguration(
                commandID: ChatCommandID(rawValue: "command-config"),
                optionID: ChatConfigurationOptionID(rawValue: "option-theme"),
                valueID: ChatConfigurationValueID(rawValue: "value-dark")
            ),
            .requestSnapshot(commandID: ChatCommandID(rawValue: "command-snapshot")),
            .closeSession(commandID: ChatCommandID(rawValue: "command-close")),
        ]

        for command in commands {
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(ChatSessionCommand.self, from: data)
            #expect(decoded == command)
        }
    }
}
#endif
