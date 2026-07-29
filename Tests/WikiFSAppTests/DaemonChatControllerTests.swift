#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

@MainActor
struct DaemonChatControllerTests {
    @Test func restartRecoveryMarksClaimedTurnInterruptedAndClearsProviderSession() async throws {
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
        #expect(snapshot.providerState.providerSessionID == nil)
        #expect(recoveredChat.acpSessionId == nil)
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
}

private struct ControllerHarness {
    enum HarnessError: Error {
        case timedOut(String)
    }

    let rootDirectory: URL
    let store: GRDBWikiStore
    let chat: ChatSummary
    let runtime: StubControllerRuntime

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

    func makeController() throws -> DaemonChatController {
        try DaemonChatController(
            chatID: chat.id,
            wikiID: WikiID(rawValue: "wiki-controller"),
            store: store,
            runtime: runtime,
            pushEvent: { _ in }
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
}

private actor StubControllerRuntime: ChatAgentRuntime {
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
