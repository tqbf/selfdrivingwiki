#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

@MainActor
struct DaemonChatControllerTests {
    @Test func restartRecoveryMarksClaimedTurnInterruptedAndPreservesProviderSessionForResumeFallback() async throws {
        let harness = try ControllerHarness()
        let claimID = ChatTurnClaimID(rawValue: "claim-restart")
        let turn = try harness.store.enqueuePersistedChatTurn(
            chatID: harness.chat.id,
            submission: harness.makeSubmission(commandID: "command-restart", turnID: "turn-restart")
        )
        _ = try harness.store.claimNextPersistedChatTurn(
            chatID: harness.chat.id,
            claimID: claimID,
            claimedAt: Date(timeIntervalSince1970: 20)
        )
        _ = try harness.store.markPersistedChatTurnProviderSubmitted(
            chatID: harness.chat.id,
            turnID: turn.submission.turnID,
            claimID: claimID,
            providerSessionID: AcpSessionID(rawValue: "session-restart"),
            submittedAt: Date(timeIntervalSince1970: 21)
        )
        try harness.store.updateChatAcpSessionId(
            chatID: harness.chat.id,
            acpSessionId: AcpSessionID(rawValue: "session-restart")
        )

        let controller = try harness.makeController()
        let snapshot = await controller.typedSnapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let recoveredChat = try harness.store.getChat(id: harness.chat.id)

        if case .interruptedTurn(let interruptedTurnID) = snapshot.attention {
            #expect(interruptedTurnID == turn.submission.turnID)
        } else {
            Issue.record("expected interrupted-turn attention after daemon restart")
        }
        #expect(snapshot.providerState.providerSessionID == AcpSessionID(rawValue: "session-restart"))
        #expect(recoveredChat.acpSessionId == AcpSessionID(rawValue: "session-restart"))
        #expect(turns.count == 1)
        #expect(turns[0].state == .failed)
        #expect(turns[0].terminalMessage == "This turn was interrupted when the daemon restarted.")
    }

    @Test func duplicateSubmitCommandIsIgnored() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-duplicate", turnID: "turn-duplicate")
        let request = harness.makeSubmitRequest(submission: submission)

        _ = try await controller.submit(request)
        _ = try await controller.submit(request)

        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let runtime = await harness.runtime.snapshot()
        #expect(turns.count == 1)
        #expect(runtime.submitCalls == [submission])
    }

    @Test func submitDoesNotEmitLegacyChatEventEnvelope() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-envelope", turnID: "turn-envelope")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))

        let kinds = harness.recordedEnvelopes().map(\.kind)
        #expect(kinds.contains(.chatEvent) == false)
        #expect(kinds.contains(.chatSyncUpdate))
    }

    @Test func queuedCancellationTargetIsRejectedAndFollowerIsPreserved() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-active", turnID: "turn-active")
        let second = harness.makeSubmission(commandID: "command-queued", turnID: "turn-queued")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))
        await controller.cancel(turnID: second.turnID)

        let snapshot = await controller.typedSnapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let runtime = await harness.runtime.snapshot()

        #expect(snapshot.activeTurn?.turnID == first.turnID)
        #expect(snapshot.queuedTurns.map(\.submission.turnID) == [second.turnID])
        #expect(turns.map(\.state) == [.providerSubmitted, .queued])
        #expect(runtime.cancelCalls.isEmpty)
    }

    @Test func cancelDoesNotRemoveBootstrapQueuedActiveTurn() async throws {
        let harness = try ControllerHarness()
        let queued = try harness.store.enqueuePersistedChatTurn(
            chatID: harness.chat.id,
            submission: harness.makeSubmission(commandID: "command-bootstrap-queued", turnID: "turn-bootstrap-queued")
        )
        let controller = try harness.makeController()

        await controller.cancel(turnID: queued.submission.turnID)

        let snapshot = await controller.typedSnapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let runtime = await harness.runtime.snapshot()

        #expect(snapshot.activeTurn?.turnID == queued.submission.turnID)
        #expect(snapshot.activeTurn?.state == .queued)
        #expect(snapshot.queuedTurns.isEmpty)
        #expect(turns.map(\.submission.turnID) == [queued.submission.turnID])
        #expect(turns.map(\.state) == [.queued])
        #expect(runtime.cancelCalls.isEmpty)
    }

    @Test func permissionResolutionUpdatesAttentionAndForwardsOption() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-permission", turnID: "turn-permission")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        let permissionRequest = ChatPendingPermissionRequest(
            requestID: PermissionRequestID(rawValue: "permission-1"),
            turnID: submission.turnID,
            toolCallID: ToolCallID(rawValue: "tool-1"),
            title: "Edit file",
            message: "Allow?",
            options: [
                ChatPermissionOption(
                    id: PermissionOptionID(rawValue: "allow"),
                    label: "Allow",
                    behavior: .allow,
                    isDefault: true
                )
            ]
        )

        await harness.runtime.emit(.permissionRequested(permissionRequest))
        try await harness.waitUntilAttention(
            controller,
            matches: { attention in
                if case .permissionRequired(let requestID) = attention {
                    return requestID == permissionRequest.requestID
                }
                return false
            },
            failureMessage: "expected permissionRequired attention after permission request"
        )
        var snapshot = await controller.typedSnapshot()
        if case .permissionRequired(let requestID) = snapshot.attention {
            #expect(requestID == permissionRequest.requestID)
        } else {
            Issue.record("expected permissionRequired attention after permission request")
        }

        await controller.resolvePermission(optionID: "allow")
        let runtimeAfterResolve = await harness.runtime.snapshot()
        #expect(runtimeAfterResolve.permissionResolutions == [
            ChatPermissionResolution(
                requestID: permissionRequest.requestID,
                optionID: PermissionOptionID(rawValue: "allow")
            )
        ])

        await harness.runtime.emit(.permissionResolved(ChatPermissionResolution(
            requestID: permissionRequest.requestID,
            optionID: PermissionOptionID(rawValue: "allow")
        )))
        try await harness.waitUntilAttention(
            controller,
            matches: { $0 == .none },
            failureMessage: "expected permission attention to clear after resolution"
        )
        snapshot = await controller.typedSnapshot()
        #expect(snapshot.attention == .none)
    }

    @Test func activeTurnCancellationRaceHasCancelledTerminalWinner() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-cancel", turnID: "turn-cancel")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        await controller.cancel(turnID: nil)
        await harness.runtime.emit(.turnCompleted(submission.turnID))

        try await harness.waitUntilPersistedTurnState(submission.turnID, equals: .cancelled)
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let runtime = await harness.runtime.snapshot()

        let persistedTurn = try #require(turns.first)
        #expect(turns.count == 1)
        #expect(persistedTurn.state == .cancelled)
        #expect(runtime.cancelCalls == [submission.turnID])
    }

    @Test func completedTurnWinsOverLaterTransportExitAndReplayTracksUpdates() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-complete", turnID: "turn-complete")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        await harness.runtime.emit(.turnCompleted(submission.turnID))
        await harness.runtime.emit(.transportClosed(status: 9))

        try await harness.waitUntilPersistedTurnState(submission.turnID, equals: .completed)
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let snapshot = await controller.typedSnapshot()
        let replay = await controller.replay(after: .initial)

        let persistedTurn = try #require(turns.first)
        #expect(turns.count == 1)
        #expect(persistedTurn.state == .completed)
        #expect(persistedTurn.terminalMessage == nil)
        #expect(snapshot.lifecycle == .closed)
        if case .available(let updates) = replay {
            #expect(updates.isEmpty == false)
            #expect(updates.last?.payload == .sessionClosed)
        } else {
            Issue.record("expected replay updates to remain available after completion and transport close")
        }
    }

    @Test func syncUpdatesUseConsecutiveSequencesAndIgnoreLastActivityOnlyCompatibilityRefresh() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-sequence", turnID: "turn-sequence")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        await controller.didUpdateCompatibilityState(ChatStateUpdate(
            isRunning: true,
            isGenerating: true,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: "query",
            runStartedAt: Date(timeIntervalSince1970: 100),
            stderr: "stderr",
            lastActivityAt: Date(timeIntervalSince1970: 200),
            currentProcessID: 123
        ))
        await controller.didUpdateCompatibilityState(ChatStateUpdate(
            isRunning: true,
            isGenerating: true,
            isAwaitingGenerationSlot: false,
            preflightError: nil,
            thinkingOption: nil,
            usageData: nil,
            logFileURL: nil,
            debugFolderURL: nil,
            runKindRaw: "query",
            runStartedAt: Date(timeIntervalSince1970: 100),
            stderr: "stderr",
            lastActivityAt: Date(timeIntervalSince1970: 201),
            currentProcessID: 123
        ))

        let updates = try harness.recordedEnvelopes()
            .filter { $0.kind == .chatSyncUpdate }
            .map { try $0.decodedChatSyncUpdate() }
        let sessionEventSequences = updates.compactMap { update -> Int64? in
            guard case .sessionEvent = update.reason else { return nil }
            return update.projection.lastIncludedSequence.rawValue
        }
        let compatibilitySequences = updates.compactMap { update -> Int64? in
            guard case .compatibilityRefreshed = update.reason else { return nil }
            return update.projection.lastIncludedSequence.rawValue
        }

        #expect(sessionEventSequences == Array(1...Int64(sessionEventSequences.count)))
        #expect(compatibilitySequences.count == 1)
        #expect(compatibilitySequences.first == sessionEventSequences.last)
    }

    @Test func restartRecoveryPreservesQueuedOrderWithoutAutoResubmit() async throws {
        let harness = try ControllerHarness()
        let claimID = ChatTurnClaimID(rawValue: "claim-order")
        let interrupted = try harness.store.enqueuePersistedChatTurn(
            chatID: harness.chat.id,
            submission: harness.makeSubmission(commandID: "command-interrupted", turnID: "turn-interrupted")
        )
        _ = try harness.store.claimNextPersistedChatTurn(
            chatID: harness.chat.id,
            claimID: claimID,
            claimedAt: Date(timeIntervalSince1970: 20)
        )
        _ = try harness.store.markPersistedChatTurnProviderSubmitted(
            chatID: harness.chat.id,
            turnID: interrupted.submission.turnID,
            claimID: claimID,
            providerSessionID: AcpSessionID(rawValue: "session-order"),
            submittedAt: Date(timeIntervalSince1970: 21)
        )
        _ = try harness.store.enqueuePersistedChatTurn(
            chatID: harness.chat.id,
            submission: harness.makeSubmission(commandID: "command-queued-1", turnID: "turn-queued-1", text: "first queued")
        )
        _ = try harness.store.enqueuePersistedChatTurn(
            chatID: harness.chat.id,
            submission: harness.makeSubmission(commandID: "command-queued-2", turnID: "turn-queued-2", text: "second queued")
        )

        let controller = try harness.makeController()
        let snapshot = await controller.typedSnapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let runtime = await harness.runtime.snapshot()

        if case .interruptedTurn(let turnID) = snapshot.attention {
            #expect(turnID == interrupted.submission.turnID)
        } else {
            Issue.record("expected interrupted-turn attention for the claimed turn")
        }
        #expect(snapshot.activeTurn?.turnID == interrupted.submission.turnID)
        #expect(snapshot.queuedTurns.map(\.submission.turnID) == [
            ChatTurnID(rawValue: "turn-queued-1"),
            ChatTurnID(rawValue: "turn-queued-2"),
        ])
        #expect(turns.map(\.submission.turnID) == [
            interrupted.submission.turnID,
            ChatTurnID(rawValue: "turn-queued-1"),
            ChatTurnID(rawValue: "turn-queued-2"),
        ])
        #expect(turns.map(\.state) == [.failed, .queued, .queued])
        #expect(runtime.startRequests.isEmpty)
        #expect(runtime.submitCalls.isEmpty)
    }

    @Test func staleGenerationRuntimeEventIsIgnored() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-stale", turnID: "turn-stale")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        await harness.runtime.emit(
            .turnCompleted(submission.turnID),
            generation: ChatSessionGenerationID(rawValue: "stale-generation")
        )

        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let persistedTurn = try #require(turns.first)
        #expect(persistedTurn.state == .providerSubmitted)
    }

    @Test func submitUsesStoredProviderSessionForResume() async throws {
        let harness = try ControllerHarness()
        try harness.store.updateChatAcpSessionId(
            chatID: harness.chat.id,
            acpSessionId: AcpSessionID(rawValue: "stored-session")
        )
        let controller = try harness.makeController()

        _ = try await controller.submit(
            harness.makeSubmitRequest(
                submission: harness.makeSubmission(commandID: "command-resume", turnID: "turn-resume")
            )
        )

        let runtime = await harness.runtime.snapshot()
        let start = try #require(runtime.startRequests.first)
        #expect(start.existingProviderSessionID == AcpSessionID(rawValue: "stored-session"))
    }

    @Test func replayBecomesUnavailablePastBoundedCapacity() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-replay", turnID: "turn-replay")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        for index in 0..<140 {
            await harness.runtime.emit(.transcript([
                .append(.message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "message-\(index)"),
                    turnID: submission.turnID,
                    role: .assistant,
                    text: "delta-\(index)",
                    createdAt: Date(timeIntervalSince1970: Double(index))
                )))
            ]))
        }

        try await harness.waitUntilSequence(
            controller,
            atLeast: ChatUpdateSequence(rawValue: 130),
            failureMessage: "expected replay buffer to consume transcript events"
        )

        let latest = await controller.typedSnapshot().lastIncludedSequence.rawValue
        let staleWatermark = ChatUpdateSequence(rawValue: max(0, latest - 130))
        #expect(await controller.replay(after: staleWatermark) == .unavailable)
    }

    @Test func transportCloseRotatesRuntimeAndRecoversOnNextTurn() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-first", turnID: "turn-first")
        let second = harness.makeSubmission(commandID: "command-second", turnID: "turn-second", text: "after restart")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.transportClosed(status: 9))
        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))

        let runtime = await harness.runtime.snapshot()
        #expect(runtime.startRequests.count == 2)
        #expect(runtime.submitCalls.map(\.turnID) == [first.turnID, second.turnID])
    }

    @Test func stopSessionClosesIdleRuntimeAndNextTurnStartsFreshRuntime() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-stop-first", turnID: "turn-stop-first")
        let second = harness.makeSubmission(commandID: "command-stop-second", turnID: "turn-stop-second", text: "after explicit close")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.turnCompleted(first.turnID))
        try await harness.waitUntil(
            controller,
            predicate: { activeTurn in activeTurn?.state.isTerminal == true },
            failureMessage: "expected the first turn to reach a terminal state before stopping the idle session"
        )
        await controller.stopSession()
        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))

        let runtime = await harness.runtime.snapshot()
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.startRequests.count == 2)
        #expect(runtime.submitCalls.map(\.turnID) == [first.turnID, second.turnID])
    }

    @Test func idleEvictionCloseDefersInterleavedSubmitAndKeepsControllerNonEvictable() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-idle-first", turnID: "turn-idle-first")
        let second = harness.makeSubmission(commandID: "command-idle-second", turnID: "turn-idle-second", text: "arrived during close")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.turnCompleted(first.turnID))
        try await harness.waitUntil(
            controller,
            predicate: { $0?.state.isTerminal == true },
            failureMessage: "expected an idle runtime before eviction"
        )

        await harness.runtime.pauseNextClose()
        let eviction = Task { await controller.closeIfIdle() }
        await harness.runtime.waitForCloseToStart()

        let submittedDuringClose = Task {
            try await controller.submit(harness.makeSubmitRequest(submission: second))
        }
        _ = try await submittedDuringClose.value
        await harness.runtime.resumeClose()

        #expect(await eviction.value == false)
        let runtime = await harness.runtime.snapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.startRequests.count == 2)
        #expect(runtime.submitCalls.map(\.turnID) == [first.turnID, second.turnID])
        #expect(turns.map(\.state) == [.completed, .providerSubmitted])
    }

    @Test func overlappingStopSessionLeavesTheOriginalCloseOwnerToRecoverQueuedTurn() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-overlap-first", turnID: "turn-overlap-first")
        let second = harness.makeSubmission(commandID: "command-overlap-second", turnID: "turn-overlap-second", text: "arrived during nested close")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.turnCompleted(first.turnID))
        try await harness.waitUntil(
            controller,
            predicate: { $0?.state.isTerminal == true },
            failureMessage: "expected an idle runtime before overlapping close"
        )

        await harness.runtime.pauseNextClose()
        let idleEviction = Task { await controller.closeIfIdle() }
        await harness.runtime.waitForCloseToStart()
        let nestedStop = Task { await controller.stopSession() }
        await nestedStop.value

        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))
        await harness.runtime.resumeClose()

        #expect(await idleEviction.value == false)
        let runtime = await harness.runtime.snapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.startRequests.count == 2)
        #expect(runtime.submitCalls.map(\.turnID) == [first.turnID, second.turnID])
        #expect(turns.map(\.state) == [.completed, .providerSubmitted])
    }

    @Test func nestedTransportCloseCannotReleaseAnotherCloseOwnersGuard() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-transport-owner-first", turnID: "turn-transport-owner-first")
        let second = harness.makeSubmission(commandID: "command-transport-owner-second", turnID: "turn-transport-owner-second", text: "arrived after nested transport close")
        let nestedProviderID = ProviderID(rawValue: "nested-transport-provider")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.turnCompleted(first.turnID))
        try await harness.waitUntil(
            controller,
            predicate: { $0?.state.isTerminal == true },
            failureMessage: "expected an idle runtime before overlapping transport close"
        )

        await harness.runtime.pauseNextClose()
        let idleEviction = Task { await controller.closeIfIdle() }
        await harness.runtime.waitForCloseToStart()

        // AsyncStream preserves element order. Observing this later marker
        // proves transportClosed returned while the original close still owns
        // the lifecycle guard.
        await harness.runtime.emit(.transportClosed(status: 9))
        await harness.runtime.emit(.sessionReady(
            capabilities: ChatCapabilitySet(
                supportsResume: true,
                supportsClose: true,
                supportsReasoning: true,
                supportsToolCalls: true,
                supportsPermissions: true
            ),
            providerState: ChatProviderState(
                providerID: nestedProviderID,
                modelID: ModelID(rawValue: "nested-transport-model"),
                providerSessionID: AcpSessionID(rawValue: "nested-transport-session")
            )
        ))
        try await harness.waitUntilRuntimeSnapshot(
            controller,
            predicate: { $0.providerState.providerID == nestedProviderID },
            failureMessage: "expected nested transport-close stream processing before resuming the owner"
        )

        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))
        await harness.runtime.resumeClose()

        #expect(await idleEviction.value == false)
        let runtime = await harness.runtime.snapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.startRequests.count == 2)
        #expect(runtime.submitCalls.map(\.turnID) == [first.turnID, second.turnID])
        #expect(turns.map(\.state) == [.completed, .providerSubmitted])
    }

    @Test func stopSessionRecoversTurnSubmittedWhileRuntimeCloseIsAwaiting() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-stop-recovery-first", turnID: "turn-stop-recovery-first")
        let second = harness.makeSubmission(commandID: "command-stop-recovery-second", turnID: "turn-stop-recovery-second", text: "recover after stop")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.turnCompleted(first.turnID))
        try await harness.waitUntil(
            controller,
            predicate: { $0?.state.isTerminal == true },
            failureMessage: "expected an idle runtime before stopping"
        )

        await harness.runtime.pauseNextClose()
        let stop = Task { await controller.stopSession() }
        await harness.runtime.waitForCloseToStart()
        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))
        await harness.runtime.resumeClose()
        await stop.value

        let runtime = await harness.runtime.snapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        #expect(runtime.closeCallCount == 1)
        #expect(runtime.startRequests.count == 2)
        #expect(runtime.submitCalls.map(\.turnID) == [first.turnID, second.turnID])
        #expect(turns.map(\.state) == [.completed, .providerSubmitted])
    }

    @Test func controllerRegistryAcquireRevokesAnIdleEvictionReservation() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let registry = ControllerRegistry()
        _ = await registry.insertIfAbsent(
            controller,
            chatID: harness.chat.id,
            wikiID: WikiID(rawValue: "wiki-controller")
        )

        guard case .reserved(let reserved) = await registry.reserveForIdleEviction(for: harness.chat.id) else {
            Issue.record("expected the inserted controller to accept an idle-eviction reservation")
            return
        }
        #expect(reserved === controller)
        #expect(await registry.isIdleEvictionReservedForTesting(for: harness.chat.id))

        guard let acquired = await registry.acquireController(for: harness.chat.id) else {
            Issue.record("expected acquireController to return the registered controller")
            return
        }
        #expect(acquired === controller)
        #expect(await registry.isIdleEvictionReservedForTesting(for: harness.chat.id) == false)
        #expect(await registry.removeIfIdleEvictionReserved(controller, for: harness.chat.id) == false)
    }

    @Test func controllerRegistryTimerClearsCompletedTaskBeforeEvictionCallback() async {
        let registry = ControllerRegistry()
        let chatID = ChatID(rawValue: "timer-chat")
        let probe = IdleEvictionProbe()

        await registry.scheduleIdleEviction(for: chatID, after: .seconds(60)) { id in
            await probe.record(id)
        }
        await registry.scheduleIdleEviction(for: chatID, after: .zero) { id in
            await probe.record(id)
        }

        #expect(await probe.waitForFirstRecord() == chatID)
        #expect(await registry.isIdleEvictionScheduled(for: chatID) == false)
    }

    @Test func idleEvictionRefusesActiveDurableClaimAndQueuedTurn() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let active = harness.makeSubmission(commandID: "command-claim", turnID: "turn-claim")
        let queued = harness.makeSubmission(commandID: "command-queued", turnID: "turn-queued", text: "wait for me")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: active))
        _ = try await controller.submit(harness.makeSubmitRequest(submission: queued))

        #expect(await controller.closeIfIdle() == false)
        let runtime = await harness.runtime.snapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        #expect(runtime.closeCallCount == 0)
        #expect(turns.map(\.state) == [.providerSubmitted, .queued])
    }

    @Test func failedTurnAttentionDoesNotBlockNextQueuedTurn() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let first = harness.makeSubmission(commandID: "command-failed", turnID: "turn-failed")
        let second = harness.makeSubmission(commandID: "command-recovery", turnID: "turn-recovery", text: "retry")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: first))
        await harness.runtime.emit(.turnFailed(
            turnID: first.turnID,
            category: .runtimeError,
            message: "boom"
        ))
        _ = try await controller.submit(harness.makeSubmitRequest(submission: second))

        let runtime = await harness.runtime.snapshot()
        #expect(runtime.submitCalls.map(\.turnID) == [first.turnID, second.turnID])
        #expect((await controller.typedSnapshot()).attention == .none)
    }

    @Test func productionTranslatedDeltasPersistAssistantReasoningAndToolRowsWithoutDuplicates() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-runtime-deltas", turnID: "turn-runtime-deltas")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        let deltas = LauncherChatAgentRuntime.transcriptDeltasForTesting(
            from: [
                .assistantTextDelta("Hello"),
                .assistantTextDelta(" world"),
                .thinkingDelta("Need"),
                .thinking("Need context"),
                .toolUse(name: "Edit", inputSummary: "/tmp/file.md"),
                .toolResult(isError: false, summary: "updated file"),
            ],
            turnID: submission.turnID
        )

        await harness.runtime.emit(.transcript(deltas))
        await harness.runtime.emit(.turnCompleted(submission.turnID))

        let messages = try harness.store.chatMessages(chatID: harness.chat.id)
        let assistantRows = messages.filter { $0.event == .assistantText("Hello world") }
        let reasoningRows = messages.filter { $0.event == .thinking("Need context") }
        #expect(assistantRows.count == 1)
        #expect(reasoningRows.count == 1)
        #expect(assistantRows.allSatisfy { $0.isDraft == false })
        let toolRows = messages.filter {
            if case .toolResult(isError: false, summary: "updated file") = $0.event { return true }
            return false
        }
        #expect(toolRows.count == 1)

        let transcriptPage = try harness.store.readChatTranscriptPage(chatID: harness.chat.id, after: nil, limit: 20)
        let transcriptItems = transcriptPage.items.map(\.item)
        let persistedAssistant = transcriptItems.compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item, message.role == .assistant else { return nil }
            return message
        }
        let persistedReasoning = transcriptItems.compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item, message.role == .reasoning else { return nil }
            return message
        }
        let persistedTools = transcriptItems.compactMap { item -> ChatTranscriptToolCallItem? in
            guard case .toolCall(let toolCall) = item else { return nil }
            return toolCall
        }
        #expect(persistedAssistant.contains {
            $0.messageID == ChatMessageID(rawValue: "assistant-\(submission.turnID.rawValue)-block-0")
                && $0.text == "Hello world"
        })
        #expect(persistedReasoning.contains {
            $0.messageID == ChatMessageID(rawValue: "reasoning-\(submission.turnID.rawValue)-block-1")
                && $0.text == "Need context"
        })
        #expect(persistedAssistant.count == 1)
        #expect(persistedReasoning.count == 1)
        #expect(persistedTools.count == 1)
        #expect(persistedTools.first?.toolName == "Edit")
        #expect(persistedTools.first?.status == .completed)
    }

    @Test func runtimeTranscriptBurstCoalescesDiagnosticsByRealDurableMessageID() async throws {
        let harness = try ControllerHarness()
        let trace = DaemonChatDiagnostics()
        let controller = try harness.makeController(diagnosticTrace: trace)
        let submission = harness.makeSubmission(commandID: "command-diagnostic-burst", turnID: "turn-diagnostic-burst")
        let messageID = ChatMessageID(rawValue: "assistant-diagnostic-burst")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        for text in ["A", "B", "C"] {
            await harness.runtime.emit(.transcript([.messageDelta(
                messageID: messageID,
                turnID: submission.turnID,
                role: .assistant,
                delta: text,
                createdAt: .distantPast
            )]))
        }
        try await harness.waitUntilOverlay(
            controller,
            matches: { items in
                items.contains {
                    guard case .message(let message) = $0 else { return false }
                    return message.messageID == messageID && message.text == "ABC"
                }
            },
            failureMessage: "expected the real runtime burst to reach the transcript overlay"
        )

        let chat = ChatDiagnosticCorrelation.Value(rawValue: harness.chat.id.rawValue)
        let item = ChatDiagnosticCorrelation.Value(rawValue: messageID.rawValue)
        let events = await trace.snapshot(chat: chat).events
        for stage in [ChatDiagnosticStage.providerReceipt, .reduction, .persistence] {
            let matching = events.filter {
                $0.stage == stage && $0.payload.correlation.durableItem == item
            }
            #expect(matching.count == 1)
            #expect(matching[0].outcome == .coalesced)
            #expect(matching[0].payload.correlation.content?.length == 1)
        }
    }

    @Test func completedTurnClearsTransientTranscriptOverlay() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.makeController()
        let submission = harness.makeSubmission(commandID: "command-overlay", turnID: "turn-overlay")

        _ = try await controller.submit(harness.makeSubmitRequest(submission: submission))
        await harness.runtime.emit(.transcript(
            LauncherChatAgentRuntime.transcriptDeltasForTesting(
                from: [
                    .assistantTextDelta("Hello"),
                    .assistantText("Hello"),
                ],
                turnID: submission.turnID
            )
        ))
        try await harness.waitUntilOverlay(
            controller,
            matches: { $0.isEmpty == false },
            failureMessage: "expected transcript overlay to appear after streamed assistant output"
        )

        await harness.runtime.emit(.turnCompleted(submission.turnID))

        try await harness.waitUntilOverlay(
            controller,
            matches: \.isEmpty,
            failureMessage: "expected transcript overlay to clear after turn completion"
        )
    }
}

final class ControllerHarness {
    enum HarnessError: Error {
        case timedOut(String)
    }

    let rootDirectory: URL
    let store: GRDBWikiStore
    let chat: ChatSummary
    let runtime: StubControllerRuntime
    private let eventRecorder = EventRecorder()

    init() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        rootDirectory = repositoryRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("daemon-chat-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        store = try GRDBWikiStore(databaseURL: rootDirectory.appendingPathComponent("wiki.sqlite"))
        chat = try store.createChat(kind: .edit, title: "Controller Test Chat")
        runtime = StubControllerRuntime()
    }

    deinit {
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    func makeController(
        diagnosticTrace: DaemonChatDiagnostics = DaemonChatDiagnostics(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> DaemonChatController {
        try DaemonChatController(
            chatID: chat.id,
            wikiID: WikiID(rawValue: "wiki-controller"),
            store: store,
            runtime: runtime,
            pushEvent: { [eventRecorder] envelope in
                eventRecorder.record(envelope)
            },
            diagnosticTrace: diagnosticTrace,
            clock: clock
        )
    }

    func makeSubmission(commandID: String, turnID: String, text: String = "hello") -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: commandID),
            turnID: ChatTurnID(rawValue: turnID),
            userText: text,
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
    }

    func makeSubmitRequest(submission: ChatTurnSubmission) -> ChatSubmitRequest {
        ChatSubmitRequest(
            wikiID: WikiID(rawValue: "wiki-controller"),
            chatID: chat.id,
            submission: submission,
            providerId: ProviderID(rawValue: "provider-test"),
            modelId: ModelID(rawValue: "model-test")
        )
    }

    func waitUntilPersistedTurnState(_ turnID: ChatTurnID, equals expectedState: ChatTurnPersistenceState) async throws {
        for _ in 0..<50 {
            let turns = try store.listPersistedChatTurns(chatID: chat.id)
            if turns.first(where: { $0.submission.turnID == turnID })?.state == expectedState {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(turnID.rawValue) to reach persisted state \(expectedState.rawValue)")
    }

    func waitUntilAttention(
        _ controller: DaemonChatController,
        matches predicate: @escaping @Sendable (ChatAttentionState) -> Bool,
        failureMessage: String
    ) async throws {
        for _ in 0..<50 {
            if predicate(await controller.typedSnapshot().attention) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessError.timedOut(failureMessage)
    }

    func waitUntilSequence(
        _ controller: DaemonChatController,
        atLeast minimum: ChatUpdateSequence,
        failureMessage: String
    ) async throws {
        for _ in 0..<50 {
            if await controller.typedSnapshot().lastIncludedSequence >= minimum {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessError.timedOut(failureMessage)
    }

    func waitUntil(
        _ controller: DaemonChatController,
        predicate: @Sendable @escaping (ChatTurnSnapshot?) -> Bool,
        failureMessage: String
    ) async throws {
        for _ in 0..<50 {
            if predicate(await controller.typedSnapshot().activeTurn) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessError.timedOut(failureMessage)
    }

    func waitUntilRuntimeSnapshot(
        _ controller: DaemonChatController,
        predicate: @Sendable @escaping (ChatRuntimeSnapshot) -> Bool,
        failureMessage: String
    ) async throws {
        for _ in 0..<50 {
            if predicate(await controller.typedSnapshot()) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessError.timedOut(failureMessage)
    }

    func waitUntilOverlay(
        _ controller: DaemonChatController,
        matches predicate: @Sendable @escaping ([ChatTranscriptItem]) -> Bool,
        failureMessage: String
    ) async throws {
        for _ in 0..<50 {
            if predicate(await controller.typedSnapshot().transientTranscriptOverlay) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessError.timedOut(failureMessage)
    }

    func recordedEnvelopes() -> [QueueEventEnvelope] {
        eventRecorder.snapshot()
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [QueueEventEnvelope] = []

    func record(_ envelope: QueueEventEnvelope) {
        lock.lock()
        envelopes.append(envelope)
        lock.unlock()
    }

    func snapshot() -> [QueueEventEnvelope] {
        lock.lock()
        let snapshot = envelopes
        lock.unlock()
        return snapshot
    }
}

private actor IdleEvictionProbe {
    private var firstRecord: ChatID?
    private var firstRecordWaiter: CheckedContinuation<ChatID, Never>?

    func record(_ chatID: ChatID) {
        guard firstRecord == nil else { return }
        firstRecord = chatID
        firstRecordWaiter?.resume(returning: chatID)
        firstRecordWaiter = nil
    }

    func waitForFirstRecord() async -> ChatID {
        if let firstRecord {
            return firstRecord
        }
        return await withCheckedContinuation { continuation in
            firstRecordWaiter = continuation
        }
    }
}

actor StubControllerRuntime: ChatAgentRuntime {
    struct Snapshot: Sendable {
        let startRequests: [ChatRuntimeStartRequest]
        let submitCalls: [ChatTurnSubmission]
        let cancelCalls: [ChatTurnID?]
        let permissionResolutions: [ChatPermissionResolution]
        let closeCallCount: Int
    }

    private let handle = ChatRuntimeHandle(rawValue: "stub-runtime")
    private var generation = ChatSessionGenerationID(rawValue: "generation-stub")
    private var startRequests: [ChatRuntimeStartRequest] = []
    private var submitCalls: [ChatTurnSubmission] = []
    private var cancelCalls: [ChatTurnID?] = []
    private var permissionResolutions: [ChatPermissionResolution] = []
    private var closeCallCount = 0
    private var pausesNextClose = false
    private var closeHasStarted = false
    private var closeStartedWaiter: CheckedContinuation<Void, Never>?
    private var closeResumeWaiter: CheckedContinuation<Void, Never>?
    private var streamContinuation: AsyncStream<ChatAgentRuntimeEventEnvelope>.Continuation?
    private var stream: AsyncStream<ChatAgentRuntimeEventEnvelope>?

    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
        startRequests.append(request)
        generation = request.generation
        if stream == nil {
            let (createdStream, continuation) = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
            stream = createdStream
            streamContinuation = continuation
        }
        return handle
    }

    func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
        if let stream {
            return stream
        }
        let (createdStream, continuation) = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
        stream = createdStream
        streamContinuation = continuation
        return createdStream
    }

    func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws {
        submitCalls.append(submission)
        streamContinuation?.yield(.init(
            generation: generation,
            event: .sessionReady(
                capabilities: ChatCapabilitySet(
                    supportsResume: true,
                    supportsClose: true,
                    supportsReasoning: true,
                    supportsToolCalls: true,
                    supportsPermissions: true
                ),
                providerState: ChatProviderState(
                    providerID: ProviderID(rawValue: "provider-test"),
                    modelID: ModelID(rawValue: "model-test"),
                    providerSessionID: AcpSessionID(rawValue: "session-live")
                )
            )
        ))
    }

    func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {
        cancelCalls.append(turnID)
    }

    func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws {
        permissionResolutions.append(resolution)
    }

    func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws {}

    func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot {
        ChatRuntimeSnapshot(
            chatID: ChatID(rawValue: "snapshot-chat"),
            generation: generation,
            lifecycle: .ready,
            activeTurn: nil,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transientTranscriptOverlay: [],
            lastIncludedSequence: .initial
        )
    }

    func close(_ handle: ChatRuntimeHandle) async {
        closeCallCount += 1
        if pausesNextClose {
            pausesNextClose = false
            closeHasStarted = true
            closeStartedWaiter?.resume()
            closeStartedWaiter = nil
            await withCheckedContinuation { continuation in
                closeResumeWaiter = continuation
            }
        }
        streamContinuation?.finish()
        streamContinuation = nil
        stream = nil
    }

    func emit(_ event: ChatAgentRuntimeEvent) {
        emit(event, generation: generation)
    }

    func emit(_ event: ChatAgentRuntimeEvent, generation: ChatSessionGenerationID) {
        streamContinuation?.yield(.init(generation: generation, event: event))
    }

    func pauseNextClose() {
        pausesNextClose = true
        closeHasStarted = false
    }

    func waitForCloseToStart() async {
        guard closeHasStarted == false else { return }
        await withCheckedContinuation { continuation in
            closeStartedWaiter = continuation
        }
    }

    func resumeClose() {
        closeResumeWaiter?.resume()
        closeResumeWaiter = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            startRequests: startRequests,
            submitCalls: submitCalls,
            cancelCalls: cancelCalls,
            permissionResolutions: permissionResolutions,
            closeCallCount: closeCallCount
        )
    }
}
#endif
