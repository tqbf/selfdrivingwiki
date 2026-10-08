#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// Controller-level cancellation regressions: FIFO continuation, a single
/// terminal winner under races, and recovery when cancellation cannot persist.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatCancellationControllerTests {

    @Test func cancelCurrentTurnContinuesFollowersFIFO() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.controller()
        let first = harness.submission("first")
        let second = harness.submission("second")
        let third = harness.submission("third")

        _ = try await controller.submit(harness.request(first))
        _ = try await controller.submit(harness.request(second))
        _ = try await controller.submit(harness.request(third))

        await controller.cancel(turnID: first.turnID)
        await harness.runtime.emit(.turnCompleted(second.turnID))
        await harness.runtime.emit(.turnCompleted(third.turnID))

        try await harness.waitForAllTurnsTerminal()

        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let calls = await harness.runtime.snapshot().submitCalls.map(\.turnID)

        // The cancelled turn is first, and both followers ran in original
        // order — the follower dispatch must not reorder the durable queue.
        #expect(calls == [first.turnID, second.turnID, third.turnID])
        #expect(turns.map(\.state) == [.cancelled, .completed, .completed])
        // A cancelled runtime is destructive, so the followers need a fresh one.
        #expect(await harness.runtime.snapshot().startCount >= 2)
    }

    @Test func cancelTerminalRaceHasSingleWinner() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.controller()
        let active = harness.submission("race-active")
        let follower = harness.submission("race-follower")

        _ = try await controller.submit(harness.request(active))
        _ = try await controller.submit(harness.request(follower))

        // Repeated Cancel racing both terminal events must still commit exactly
        // one outcome for the cancelled turn and dispatch exactly one follower.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await controller.cancel(turnID: active.turnID) }
            }
            group.addTask { await harness.runtime.emit(.turnCompleted(active.turnID)) }
            group.addTask { await harness.runtime.emit(.turnCancelled(active.turnID)) }
        }

        try await harness.waitForCancelledRow(turnID: active.turnID)
        // The promoted follower is live; complete it so the queue settles.
        await harness.runtime.emit(.turnCompleted(follower.turnID))
        try await harness.waitForAllTurnsTerminal()
        let turns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let activeRows = turns.filter { $0.submission.turnID == active.turnID }
        let followerCalls = await harness.runtime.snapshot().submitCalls
            .filter { $0.turnID == follower.turnID }

        #expect(activeRows.count == 1)
        #expect(activeRows.map(\.state) == [.cancelled])
        #expect(followerCalls.count == 1)
    }

    /// A failed runtime cleanup must retain close ownership and let a retry
    /// finish the close, after which the follower continues. Without the retry
    /// the controller would wedge and the advertised retry would do nothing.
    @Test func cancelCleanupFailureRetriesCloseThenContinuesQueue() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.controller()
        let active = harness.submission("cleanup-active")
        let follower = harness.submission("cleanup-follower")

        _ = try await controller.submit(harness.request(active))
        _ = try await controller.submit(harness.request(follower))

        await harness.runtime.failNextClose()
        await controller.cancel(turnID: active.turnID)

        // The terminal outcome is committed, but cleanup failed, so followers
        // stay blocked and the failure is a retryable attention.
        let blocked = await controller.typedSnapshot()
        let blockedTurns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        if case .runtimeCleanupFailed(let turnID, _) = blocked.attention {
            #expect(turnID == active.turnID)
        } else {
            Issue.record("expected a retryable cleanup attention, got \(blocked.attention)")
        }
        #expect(blockedTurns.first { $0.submission.turnID == active.turnID }?.state == .cancelled)
        #expect(await harness.runtime.snapshot().submitCalls.filter { $0.turnID == follower.turnID }.isEmpty)

        // The retry repeats only the close and then continues the queue.
        await controller.cancel(turnID: active.turnID)
        try await harness.waitForCancelledRow(turnID: active.turnID)
        try await harness.waitForFollowerSubmitted(turnID: follower.turnID)

        // The promoted follower is live; finish it so the queue settles.
        await harness.runtime.emit(.turnCompleted(follower.turnID))
        try await harness.waitForAllTurnsTerminal()
        #expect(await harness.runtime.snapshot().submitCalls.filter { $0.turnID == follower.turnID }.count == 1)
    }

    @Test func cancelPersistenceFailureRemainsRecoverable() async throws {
        let harness = try ControllerHarness()
        let controller = try harness.controller()
        let active = harness.submission("persist-active")
        let follower = harness.submission("persist-follower")

        _ = try await controller.submit(harness.request(active))
        _ = try await controller.submit(harness.request(follower))

        // A store that fails the terminal write must leave the row and claim in
        // place, block the follower, and surface a retryable attention.
        harness.store.failNextTerminalChatTurnWrite = true
        await controller.cancel(turnID: active.turnID)

        let blocked = await controller.typedSnapshot()
        let blockedTurns = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let activeRow = try #require(blockedTurns.first { $0.submission.turnID == active.turnID })

        if case .cancellationPersistenceFailed(let turnID, _) = blocked.attention {
            #expect(turnID == active.turnID)
        } else {
            Issue.record("expected a retryable cancellation persistence attention, got \(blocked.attention)")
        }
        #expect(activeRow.state == .providerSubmitted)
        #expect(activeRow.claimID != nil)
        #expect(await harness.runtime.snapshot().submitCalls.filter { $0.turnID == follower.turnID }.isEmpty)

        // The retry repeats only the durable settlement, then continues the
        // queue. It must not restart the cancelled prompt.
        await controller.cancel(turnID: active.turnID)
        try await harness.waitForCancelledRow(turnID: active.turnID)

        // The promoted follower is now live; finish it so both rows settle.
        await harness.runtime.emit(.turnCompleted(follower.turnID))
        try await harness.waitForAllTurnsTerminal()

        let settled = try harness.store.listPersistedChatTurns(chatID: harness.chat.id)
        let submits = await harness.runtime.snapshot().submitCalls
        #expect(settled.map(\.state) == [.cancelled, .completed])
        #expect(submits.filter { $0.turnID == active.turnID }.count == 1)
        #expect(submits.filter { $0.turnID == follower.turnID }.count == 1)
    }

    // MARK: - Harness

    private struct ControllerHarness {
        let root: URL
        let store: GRDBWikiStore
        let chat: ChatSummary
        let runtime = StubControllerRuntime()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cancel-controller-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try GRDBWikiStore(databaseURL: root.appendingPathComponent("w.sqlite"))
            chat = try store.createChat(kind: .edit, title: "cancellation")
        }

        func submission(_ id: String) -> ChatTurnSubmission {
            ChatTurnSubmission(
                commandID: ChatCommandID(rawValue: "command-\(id)"),
                turnID: ChatTurnID(rawValue: "turn-\(id)"),
                userText: id,
                contextReferences: [],
                submittedAt: Date(timeIntervalSince1970: 1))
        }

        func request(_ submission: ChatTurnSubmission) -> ChatSubmitRequest {
            ChatSubmitRequest(
                wikiID: WikiID(rawValue: "cancel-wiki"),
                chatID: chat.id,
                submission: submission)
        }

        func controller() throws -> DaemonChatController {
            try DaemonChatController(
                chatID: chat.id,
                wikiID: WikiID(rawValue: "cancel-wiki"),
                store: store,
                runtime: runtime,
                pushEvent: { _ in })
        }

        /// Polls until every durable turn is terminal, using bounded waits.
        func waitForAllTurnsTerminal() async throws {
            for _ in 0..<100 {
                let turns = try store.listPersistedChatTurns(chatID: chat.id)
                if turns.allSatisfy({ $0.state.isTerminal }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("timed out waiting for durable turns to become terminal")
        }

        /// Polls until one turn reaches the cancelled terminal state.
        func waitForCancelledRow(turnID: ChatTurnID) async throws {
            for _ in 0..<100 {
                let turns = try store.listPersistedChatTurns(chatID: chat.id)
                if turns.contains(where: { $0.submission.turnID == turnID && $0.state == .cancelled }) {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("timed out waiting for the cancelled durable row")
        }

        /// Polls until the promoted follower reaches the provider.
        func waitForFollowerSubmitted(turnID: ChatTurnID) async throws {
            for _ in 0..<100 {
                if await runtime.snapshot().submitCalls.contains(where: { $0.turnID == turnID }) {
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("timed out waiting for the follower to be submitted")
        }
    }

    private actor StubControllerRuntime: ChatAgentRuntime {
        struct State: Sendable {
            let submitCalls: [ChatTurnSubmission]
            let startCount: Int
        }

        private let handle = ChatRuntimeHandle(rawValue: "cancel-stub")
        private var generation = ChatSessionGenerationID(rawValue: "cancel-generation")
        private var stream: AsyncStream<ChatAgentRuntimeEventEnvelope>?
        private var continuation: AsyncStream<ChatAgentRuntimeEventEnvelope>.Continuation?
        private var submitCalls: [ChatTurnSubmission] = []
        private var startCount = 0
        private var failClose = false

        enum StubError: Error { case close }

        func prepareStart(_ input: ChatRuntimeStartInput) async throws -> ChatRuntimePreparedStart {
            ChatRuntimePreparedStart(request: input.request)
        }

        func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
            startCount += 1
            generation = request.generation
            if stream == nil {
                let created = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
                stream = created.stream
                continuation = created.continuation
            }
            return handle
        }

        func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
            if let stream { return stream }
            let created = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
            stream = created.stream
            continuation = created.continuation
            return created.stream
        }

        func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws {
            submitCalls.append(submission)
        }

        func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {}

        func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws {}

        func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws {}

        func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot {
            ChatRuntimeSnapshot(
                chatID: ChatID(rawValue: "cancel-snapshot"),
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
                lastIncludedSequence: .initial)
        }

        func close(_ handle: ChatRuntimeHandle) async {
            continuation?.finish()
            continuation = nil
            stream = nil
        }

        func closeForSettlement(_ handle: ChatRuntimeHandle) async throws {
            if failClose {
                failClose = false
                throw StubError.close
            }
            await close(handle)
        }

        func failNextClose() {
            failClose = true
        }

        func discardPreparedStart(_ preparation: ChatRuntimePreparedStart) async {}

        func emit(_ event: ChatAgentRuntimeEvent) {
            continuation?.yield(.init(generation: generation, event: event))
        }

        func snapshot() -> State {
            State(submitCalls: submitCalls, startCount: startCount)
        }
    }
}

private extension ChatTurnPersistenceState {
    /// A durable turn is finished once it reaches one of these states.
    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        case .queued, .claimed, .providerSubmitted: false
        }
    }
}
#endif
