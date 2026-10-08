#if os(macOS)
import Foundation
import Testing
import WikiDaemonContract
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

/// Host-level cancellation regressions. A controlled runtime is injected
/// through `DaemonChatHost`'s runtime factory, so these tests exercise live
/// turns, queued followers, suspended teardown, and shutdown without a real
/// provider or a preflight failure.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatCancellationHostTests {

    /// Full shutdown must close the runtime and retain queued followers
    /// without promoting or dispatching them.
    @Test func shutdownDoesNotDispatchQueuedTurns() async throws {
        let harness = try await makeHarness()
        let chatID = try await harness.host.startChat(wikiID: harness.wikiID, firstMessage: "first")
        let runtime = try #require(await harness.recorder.runtime(for: chatID))
        await runtime.pauseClose()

        // Queue a follower while the first turn is live.
        _ = try await harness.submit(chatID: chatID, text: "follower")

        let shutdown = Task { await harness.host.shutdown() }
        await runtime.waitForCloseToStart()
        await runtime.resumeClose()
        await shutdown.value

        let snapshot = await runtime.snapshot()
        let turns = try harness.store.listPersistedChatTurns(chatID: chatID)

        #expect(snapshot.closeForSettlementCount == 1)
        // The follower was never dispatched: no second prepare, start, or submit.
        #expect(snapshot.prepareInputs.count == 1)
        #expect(snapshot.startRequests.count == 1)
        #expect(snapshot.submitCalls.map(\.userText) == ["first"])
        #expect(turns.count == 2)
        // The claimed active turn is durably settled, so daemon recovery cannot
        // resurrect it as an interrupted turn. The store retains `claim_id` on
        // terminal rows as history; recovery keys off state, not the claim.
        #expect(turns[0].state == .cancelled)
        // The follower is retained, not promoted or dispatched.
        #expect(turns[1].state == .queued)
    }

    /// Each chat gets its own launcher; only the admission gate is shared.
    @Test func perChatLaunchersShareOnlyAdmissionGate() async throws {
        let harness = try await makeHarness()
        let first = try await harness.host.startChat(wikiID: harness.wikiID, firstMessage: "one")
        let second = try await harness.host.startChat(wikiID: harness.wikiID, firstMessage: "two")

        let records = await harness.recorder.records()
        let firstRecord = try #require(records[first])
        let secondRecord = try #require(records[second])

        #expect(firstRecord.launcher !== secondRecord.launcher)
        #expect(firstRecord.gate == secondRecord.gate)
    }

    /// Self-test for the injected-runtime harness itself: it must be able to
    /// drive a live turn, queue a follower, hold close, run shutdown, and
    /// report the recorded calls.
    @Test func hostHarnessDrivesLiveQueuedShutdown() async throws {
        let harness = try await makeHarness()
        let chatID = try await harness.host.startChat(wikiID: harness.wikiID, firstMessage: "live")
        let runtime = try #require(await harness.recorder.runtime(for: chatID))
        await runtime.pauseClose()
        _ = try await harness.submit(chatID: chatID, text: "queued")

        let shutdown = Task { await harness.host.shutdown() }
        await runtime.waitForCloseToStart()
        await runtime.resumeClose()
        await shutdown.value

        let snapshot = await runtime.snapshot()
        #expect(snapshot.closeForSettlementCount == 1)
        #expect(snapshot.submitCalls.count == 1)
        #expect(snapshot.startRequests.count == 1)
    }

    // MARK: - Harness

    private func makeHarness() async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wikiID = WikiID(rawValue: "host-test-wiki")
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("wiki.sqlite"))
        let recorder = RuntimeRecorder()

        let host = await MainActor.run { () -> DaemonChatHost in
            let gate = GenerationGate(laneLimits: [.interactive: 1, .ingest: 1])
            let extraction = ExtractionCoordinator(services: UnavailableExtractionServices())
            let pair = makeTestLauncherPair(extractionCoordinator: extraction, generationGate: gate)
            return DaemonChatHost(
                containerDirectory: dir,
                launcherPair: pair,
                storeResolver: { $0 == wikiID ? store : nil },
                pushEvent: { _ in },
                providerServices: UnavailableAgentProviderServices(),
                idleEvictionDelay: .seconds(3600),
                makeLauncher: {
                    AgentLauncher(generationGate: gate, extractionCoordinator: extraction)
                },
                runtimeFactory: { context in
                    let runtime = ControlledRuntime()
                    await recorder.record(
                        runtime: runtime,
                        chatID: context.chatID,
                        launcher: context.launcher,
                        gate: ObjectIdentifier(gate))
                    return runtime
                })
        }

        var registry = WikiRegistry()
        registry.add(WikiDescriptor(
            id: wikiID,
            displayName: "Host Test",
            createdAt: Date(),
            lastUsedAt: Date()))
        try registry.save(to: dir)

        return Harness(host: host, store: store, wikiID: wikiID, recorder: recorder)
    }

    private struct Harness {
        let host: DaemonChatHost
        let store: GRDBWikiStore
        let wikiID: WikiID
        let recorder: RuntimeRecorder

        func submit(chatID: ChatID, text: String) async throws -> ChatID {
            try await host.submitTurn(ChatSubmitRequest(
                wikiID: wikiID,
                chatID: chatID,
                submission: ChatTurnSubmission(
                    commandID: ChatCommandID(rawValue: ULID.generate()),
                    turnID: ChatTurnID(rawValue: ULID.generate()),
                    userText: text,
                    contextReferences: [],
                    submittedAt: Date())))
        }
    }
}

private actor RuntimeRecorder {
    struct Record: Sendable {
        let runtime: ControlledRuntime
        /// Retained so its identity is stable: comparing `ObjectIdentifier` of a
        /// released object could compare two different launchers that reused
        /// one address.
        let launcher: AgentLauncher
        let gate: ObjectIdentifier
    }

    private var values: [ChatID: Record] = [:]

    func record(
        runtime: ControlledRuntime,
        chatID: ChatID,
        launcher: AgentLauncher,
        gate: ObjectIdentifier
    ) {
        values[chatID] = Record(runtime: runtime, launcher: launcher, gate: gate)
    }

    func runtime(for chatID: ChatID) -> ControlledRuntime? { values[chatID]?.runtime }
    func records() -> [ChatID: Record] { values }
}

/// A runtime with deterministic suspension controls. It records every call the
/// controller makes so tests can assert what did and did not reach a provider.
private actor ControlledRuntime: ChatAgentRuntime {
    struct Snapshot: Sendable {
        let prepareInputs: [ChatRuntimeStartInput]
        let startRequests: [ChatRuntimeStartRequest]
        let submitCalls: [ChatTurnSubmission]
        let closeForSettlementCount: Int
        let closeStarted: Bool
    }

    private let handle = ChatRuntimeHandle(rawValue: "controlled-runtime")
    private var generation = ChatSessionGenerationID(rawValue: "controlled-generation")
    private var stream: AsyncStream<ChatAgentRuntimeEventEnvelope>?
    private var continuation: AsyncStream<ChatAgentRuntimeEventEnvelope>.Continuation?
    private var prepareInputs: [ChatRuntimeStartInput] = []
    private var startRequests: [ChatRuntimeStartRequest] = []
    private var submitCalls: [ChatTurnSubmission] = []
    private var closeForSettlementCount = 0
    private var closeStarted = false
    private var pausesClose = false
    private var closeResumeWaiter: CheckedContinuation<Void, Never>?

    func prepareStart(_ input: ChatRuntimeStartInput) async throws -> ChatRuntimePreparedStart {
        prepareInputs.append(input)
        return ChatRuntimePreparedStart(request: input.request)
    }

    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
        startRequests.append(request)
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
        continuation?.yield(.init(
            generation: generation,
            event: .sessionReady(
                capabilities: ChatCapabilitySet(
                    supportsResume: true,
                    supportsClose: true,
                    supportsReasoning: true,
                    supportsToolCalls: true,
                    supportsPermissions: true),
                providerState: ChatProviderState(
                    providerID: ProviderID(rawValue: "controlled-provider"),
                    modelID: ModelID(rawValue: "controlled-model"),
                    providerSessionID: AcpSessionID(rawValue: "controlled-session")))))
    }

    func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {}

    func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws {}

    func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws {}

    func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot {
        ChatRuntimeSnapshot(
            chatID: ChatID(rawValue: "controlled-snapshot"),
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
        closeForSettlementCount += 1
        closeStarted = true
        if pausesClose {
            await withCheckedContinuation { closeResumeWaiter = $0 }
        }
        await close(handle)
    }

    func discardPreparedStart(_ preparation: ChatRuntimePreparedStart) async {}

    func pauseClose() { pausesClose = true }

    func resumeClose() {
        closeResumeWaiter?.resume()
        closeResumeWaiter = nil
        pausesClose = false
    }

    /// Bounded wait: polling avoids an abandoned continuation, which a task
    /// cancellation could not resume if the controller never closed.
    func waitForCloseToStart() async {
        for _ in 0..<100 {
            if closeStarted { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prepareInputs: prepareInputs,
            startRequests: startRequests,
            submitCalls: submitCalls,
            closeForSettlementCount: closeForSettlementCount,
            closeStarted: closeStarted)
    }
}
#endif
