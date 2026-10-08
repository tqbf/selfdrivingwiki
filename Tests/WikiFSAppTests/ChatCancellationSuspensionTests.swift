#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// Cancellation during a dispatch suspension.
///
/// Each case holds the controller inside one dispatch step with a
/// noncooperative provider, cancels the active turn, then releases. The
/// assertions are that the cancelled prompt never becomes a provider submit
/// (except where submission had already begun), no prepared provider token
/// leaks, and the follower is never stranded.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatCancellationSuspensionTests {

    @Test(arguments: ControlledRuntime.HoldPoint.allCases)
    private func cancelAcrossDispatchSuspensions(phase: ControlledRuntime.HoldPoint) async throws {
        let harness = try Harness(holdPoint: phase)
        let controller = try harness.controller()
        let cancelled = harness.submission("cancelled-\(phase)")
        let follower = harness.submission("follower-\(phase)")

        let cancelledTask = Task { try await controller.submit(harness.request(cancelled)) }
        try await harness.waitUntil { await harness.runtime.reached(phase) }

        let followerTask = Task { try await controller.submit(harness.request(follower)) }
        await controller.cancel(turnID: cancelled.turnID)

        // Release the hold and let every in-flight task finish before asserting.
        // The runtime latches released, so a later hold cannot strand a
        // continuation and the test process cannot hang on an abandoned one.
        await harness.runtime.releaseAll()
        _ = try? await cancelledTask.value
        _ = try? await followerTask.value
        try await harness.waitUntil { await harness.runtime.submitIDs().contains(follower.turnID) }

        let state = await harness.runtime.snapshot()
        let cancelledSubmits = state.submitIDs.filter { $0 == cancelled.turnID }

        switch phase {
        case .prepare:
            // The dispatch was invalidated before it could claim or send, and
            // the late prepared token was released rather than leaked.
            #expect(cancelledSubmits.isEmpty)
            #expect(state.discardCount >= 1)
        case .start, .submit:
            // The turn is already claimed at this point, so cancellation settles
            // it through the claimed path: the prompt is not repeated, no token
            // is discarded, and the follower still runs.
            #expect(cancelledSubmits.count <= 1)
        }

        #expect(state.submitIDs.filter { $0 == follower.turnID }.count == 1)
    }

    /// A turn cancelled while it waits for an admission slot must not reach the
    /// provider, and its follower must run after the slot frees.
    ///
    /// The slot wait happens inside the runtime's start/submit step, which is
    /// also where the controller holds the single claim. Cancelling the active
    /// turn there must stop it before its prompt is sent, and the follower must
    /// then be dispatched on a fresh runtime.
    @Test func cancelSlotWaitThenRunFollower() async throws {
        let harness = try Harness(holdPoint: .start)
        let controller = try harness.controller()
        let waiting = harness.submission("slot-waiting")
        let follower = harness.submission("slot-follower")

        let waitingTask = Task { try await controller.submit(harness.request(waiting)) }
        try await harness.waitUntil { await harness.runtime.reached(.start) }

        // Queue the follower while the active turn waits for its slot.
        let followerTask = Task { try await controller.submit(harness.request(follower)) }
        try await harness.waitUntil { await controller.typedSnapshot().queuedTurns.count >= 1 }

        await controller.cancel(turnID: waiting.turnID)
        await harness.runtime.releaseAll()

        _ = try? await waitingTask.value
        _ = try? await followerTask.value
        try await harness.waitUntil { await harness.runtime.submitIDs().contains(follower.turnID) }

        let ids = await harness.runtime.submitIDs()
        #expect(ids.contains(waiting.turnID) == false)
        #expect(ids.contains(follower.turnID))
    }

    // MARK: - Harness

    private struct Harness {
        let root: URL
        let store: GRDBWikiStore
        let chat: ChatSummary
        let runtime: ControlledRuntime

        init(holdPoint: ControlledRuntime.HoldPoint) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cancel-suspension-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try GRDBWikiStore(databaseURL: root.appendingPathComponent("w.sqlite"))
            chat = try store.createChat(kind: .edit, title: "suspension")
            runtime = ControlledRuntime(holdPoint: holdPoint)
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
                wikiID: WikiID(rawValue: "suspension-wiki"),
                chatID: chat.id,
                submission: submission,
                providerId: ProviderID(rawValue: "provider"),
                modelId: ModelID(rawValue: "model"))
        }

        func controller() throws -> DaemonChatController {
            try DaemonChatController(
                chatID: chat.id,
                wikiID: WikiID(rawValue: "suspension-wiki"),
                store: store,
                runtime: runtime,
                pushEvent: { _ in })
        }

        func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
            for _ in 0..<200 {
                if await predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("bounded wait timed out")
        }
    }

    /// A runtime that can hold one dispatch step open and deliberately ignores
    /// task cancellation, so fencing must come from controller identity checks
    /// rather than from cooperative cancellation.
    private actor ControlledRuntime: ChatAgentRuntime {
        enum HoldPoint: String, CaseIterable, Sendable {
            case prepare
            case start
            case submit
        }

        struct State: Sendable {
            let submitIDs: [ChatTurnID]
            let discardCount: Int
        }

        private let holdPoint: HoldPoint
        private let handle = ChatRuntimeHandle(rawValue: "controlled-suspension")
        private var generation = ChatSessionGenerationID(rawValue: "suspension-generation")
        private var entered: Set<HoldPoint> = []
        private var waiters: [HoldPoint: [CheckedContinuation<Void, Never>]] = [:]
        private var submitCalls: [ChatTurnID] = []
        private var discardCount = 0
        private var released = false
        private var stream: AsyncStream<ChatAgentRuntimeEventEnvelope>?

        init(holdPoint: HoldPoint) {
            self.holdPoint = holdPoint
        }

        func reached(_ point: HoldPoint) -> Bool { entered.contains(point) }
        func submitIDs() -> [ChatTurnID] { submitCalls }
        func snapshot() -> State { State(submitIDs: submitCalls, discardCount: discardCount) }

        /// Resumes every held step and latches, so a later hold cannot strand a
        /// continuation after the test has stopped releasing.
        func releaseAll() {
            released = true
            for point in HoldPoint.allCases {
                for waiter in waiters.removeValue(forKey: point) ?? [] {
                    waiter.resume()
                }
            }
        }

        private func hold(_ point: HoldPoint) async {
            // One-shot: only the first arrival at the hold point blocks, so a
            // follower dispatched from inside the cancel path cannot re-enter
            // the same gate and deadlock the test.
            guard holdPoint == point, released == false, entered.contains(point) == false else { return }
            entered.insert(point)
            await withCheckedContinuation { waiters[point, default: []].append($0) }
        }

        func prepareStart(_ input: ChatRuntimeStartInput) async throws -> ChatRuntimePreparedStart {
            await hold(.prepare)
            return ChatRuntimePreparedStart(request: input.request)
        }

        func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
            generation = request.generation
            await hold(.start)
            return handle
        }

        func start(_ preparation: ChatRuntimePreparedStart) async throws -> ChatRuntimeHandle {
            generation = preparation.request.generation
            await hold(.start)
            return handle
        }

        func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
            if let stream { return stream }
            let created = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
            stream = created.stream
            return created.stream
        }

        func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws {
            // Record only after the hold, so a dispatch fenced during the hold
            // is honestly reported as never submitted.
            await hold(.submit)
            submitCalls.append(submission.turnID)
        }

        func discardPreparedStart(_ preparation: ChatRuntimePreparedStart) async {
            discardCount += 1
        }

        func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {}

        func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws {}

        func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws {}

        func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot {
            ChatRuntimeSnapshot(
                chatID: ChatID(rawValue: "suspension-snapshot"),
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
            stream = nil
        }

        func closeForSettlement(_ handle: ChatRuntimeHandle) async throws {
            await close(handle)
        }
    }
}
#endif
