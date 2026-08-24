#if os(macOS)
import Cordis
import CordisLoader
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Agent loop plugin boot", .serialized, .timeLimit(.minutes(1)))
struct AgentLoopPluginBootTests {
    @Test("minimal turn appends lifecycle events and pre-step can short-circuit")
    func minimalTurnAppendsEventsAndPreStepShortCircuits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-loop-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("could not remove agent loop plugin fixture: \(error)")
            }
        }
        let databaseURL = directory.appendingPathComponent("wiki.sqlite", isDirectory: false)
        let storeEntry = Entry(
            id: EntryID("store"),
            plugin: StorePlugin.id,
            config: [
                "databasePath": .string(databaseURL.path),
                "wikiID": .string("agent-loop-plugin-test"),
            ])
        let sessionsEntry = Entry(id: EntryID("sessions"), plugin: SessionsPlugin.id)
        let persistenceEntry = Entry(
            id: EntryID("chat-persistence"),
            plugin: ChatsPersistencePlugin.id)
        let agentLoopEntry = Entry(id: EntryID("agent-loop"), plugin: AgentLoopPlugin.id)
        let handlerID = PluginID("test.agent-loop-handler")
        let handler = PluginDefinition(
            id: handlerID,
            dependencies: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
        ) {
            try ComponentDefinition(
                label: "test.agent-loop-handler",
                dependencies: [ServiceDependency(AgentLoopServiceKeys.agentLoop)]
            ) { activation in
                _ = try await activation.require(AgentLoopServiceKeys.agentLoop)
                _ = try await activation.on(AgentLoopEventKeys.preStep) { request, next in
                    guard request.prompt == "blocked" else { return try await next() }
                    var request = request
                    request.events = [.assistantText("blocked by policy")]
                    return request
                }
                _ = try await activation.on(AgentLoopEventKeys.request) { request, _ in
                    var request = request
                    request.events = [.assistantText("stub response")]
                    return request
                }
            }
        }
        let handlerEntry = Entry(id: EntryID("handler"), plugin: handlerID)
        let booted = try await CordisBoot.boot(CordisBoot.Options(
            catalog: try PluginCatalog([
                StorePlugin.definition,
                SessionsPlugin.definition,
                ChatsPersistencePlugin.definition,
                AgentLoopPlugin.definition,
                handler,
            ]),
            layers: [PatchFile(entries: [
                storeEntry, sessionsEntry, persistenceEntry, agentLoopEntry, handlerEntry,
            ])]))

        let store = try #require(try await booted.context.find(StoreServiceKeys.store))
        let agentLoop = try #require(try await booted.context.find(AgentLoopServiceKeys.agentLoop))
        let chat = try store.createChat(kind: .edit, title: "Cordis agent loop")
        let turn = AgentTurnRequest(
            chatID: chat.id,
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "hello")

        let events = try await agentLoop.enqueue(turn)
        #expect(events == [.assistantText("stub response")])
        #expect(try store.chatMessages(chatID: chat.id).map(\.event) == [
            .userText("hello"),
            .assistantText("stub response"),
        ])

        let gated = try await agentLoop.preStep(AgentStepRequest(turn: turn, prompt: "blocked"))
        #expect(gated.events == [.assistantText("blocked by policy")])

        try await booted.shutdown()
    }

    @Test("real launcher send transforms, short-circuits, and emits lifecycle")
    @MainActor
    func realLauncherSendTraversesAgentLoop() async throws {
        let recorder = AgentLoopLifecycleRecorder()
        let service = AgentLoopService(
            emitTurnStarted: { _, event in await recorder.started(event) },
            emitStepCompleted: { _, event in await recorder.completed(event) },
            emitTurnCompleted: { _, event in await recorder.finished(event) },
            waterfall: { key, request in
                var request = request
                if key == AgentLoopEventKeys.request { request.prompt += " transformed" }
                return request
            })
        let backend = FakeAgentBackend(behaviors: [FakeSessionBehavior(events: [.assistantText("ok"), .messageStop])])
        let session = try await backend.start(profile: BackendProfile(), systemPrompt: "", onExit: { _ in })
        let launcher = AgentLauncher(agentLoopService: service)

        let stream = try await launcher.sendAgentTurn(prompt: "hello", backend: backend, session: session)
        var received: [AgentEvent] = []
        for await event in stream { received.append(event) }

        #expect(await backend.sentTexts == ["hello transformed"])
        #expect(received == [.assistantText("ok"), .messageStop])
        let snapshot = await recorder.snapshot()
        #expect(snapshot.starts.count == 1)
        #expect(snapshot.steps.map(\.events) == [received])
        #expect(snapshot.finishes.count == 1)
        #expect(snapshot.starts.first?.request.projectsToSessionLog == false)
    }

    @Test("real launcher path forwards events before backend stream finishes")
    @MainActor
    func realLauncherPathStreamsIncrementally() async throws {
        let recorder = AgentLoopLifecycleRecorder()
        let service = AgentLoopService(
            emitTurnStarted: { _, event in await recorder.started(event) },
            emitStepCompleted: { _, event in await recorder.completed(event) },
            emitTurnCompleted: { _, event in await recorder.finished(event) },
            waterfall: { _, request in request })
        let backend = ControlledAgentBackend()
        let launcher = AgentLauncher(agentLoopService: service)
        let stream = try await launcher.sendAgentTurn(
            prompt: "interactive", backend: backend, session: SessionHandle(id: "controlled"))
        var iterator = stream.makeAsyncIterator()

        await backend.yield(.assistantText("first"))
        #expect(await iterator.next() == .assistantText("first"))
        #expect(await recorder.snapshot().finishes.isEmpty)

        await backend.yield(.messageStop)
        await backend.finish()
        #expect(await iterator.next() == .messageStop)
        #expect(await iterator.next() == nil)
        #expect(await recorder.snapshot().finishes.count == 1)
    }

    @Test("pre-step short-circuit skips backend send")
    @MainActor
    func preStepShortCircuitSkipsSend() async throws {
        let service = AgentLoopService(
            emitTurnStarted: { _, _ in },
            emitStepCompleted: { _, _ in },
            emitTurnCompleted: { _, _ in },
            waterfall: { key, request in
                var request = request
                if key == AgentLoopEventKeys.preStep {
                    request.events = [.assistantText("blocked"), .messageStop]
                }
                return request
            })
        let backend = FakeAgentBackend()
        let launcher = AgentLauncher(agentLoopService: service)
        let stream = try await launcher.sendAgentTurn(
            prompt: "blocked", backend: backend, session: SessionHandle(id: "unused"))
        var received: [AgentEvent] = []
        for await event in stream { received.append(event) }

        #expect(await backend.sendCount == 0)
        #expect(received == [.assistantText("blocked"), .messageStop])
    }
}

private actor ControlledAgentBackend: AgentBackend {
    private let pair = AsyncStream<AgentEvent>.makeStream()

    func start(
        profile: BackendProfile,
        systemPrompt: String,
        onExit: @escaping @Sendable (Int) -> Void
    ) async throws -> SessionHandle {
        SessionHandle(id: "controlled")
    }

    func send(_ turn: TurnInput, into session: SessionHandle) async -> AsyncStream<AgentEvent> {
        pair.stream
    }

    func resume(sessionID: String, profile: BackendProfile) async throws -> SessionHandle? { nil }
    func cancel(_ session: SessionHandle) async { pair.continuation.finish() }
    func yield(_ event: AgentEvent) { pair.continuation.yield(event) }
    func finish() { pair.continuation.finish() }
}

private actor AgentLoopLifecycleRecorder {
    private var starts: [AgentTurnStarted] = []
    private var steps: [AgentStepCompleted] = []
    private var finishes: [AgentTurnCompleted] = []

    func started(_ event: AgentTurnStarted) { starts.append(event) }
    func completed(_ event: AgentStepCompleted) { steps.append(event) }
    func finished(_ event: AgentTurnCompleted) { finishes.append(event) }
    func snapshot() -> (starts: [AgentTurnStarted], steps: [AgentStepCompleted], finishes: [AgentTurnCompleted]) {
        (starts, steps, finishes)
    }
}
#endif
