#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSTypes

struct ScriptedChatRuntimeTests {
    private func makeStartRequest(generation: String = "generation-1") -> ChatRuntimeStartRequest {
        ChatRuntimeStartRequest(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: generation),
            systemPrompt: "system",
            providerID: ProviderID(rawValue: "provider"),
            modelID: ModelID(rawValue: "model"),
            existingProviderSessionID: AcpSessionID(rawValue: "session-1")
        )
    }

    private func makeSubmission(turnID: String = "turn-1") -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "command-1"),
            turnID: ChatTurnID(rawValue: turnID),
            userText: "Hello",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func collectEvents(
        from stream: AsyncStream<ChatAgentRuntimeEventEnvelope>,
        expectedCount: Int
    ) async -> [ChatAgentRuntimeEventEnvelope] {
        var iterator = stream.makeAsyncIterator()
        var events: [ChatAgentRuntimeEventEnvelope] = []
        for _ in 0..<expectedCount {
            if let next = await iterator.next() {
                events.append(next)
            }
        }
        return events
    }

    @Test func orderedEventsResumeFromPauseGates() async throws {
        let runtime = ScriptedChatRuntime()
        let handle = try await runtime.start(makeStartRequest())
        try await runtime.enqueueSteps([
            .pause("gate-1"),
            .event(.sessionReady(
                capabilities: ChatCapabilitySet(
                    supportsResume: true,
                    supportsClose: true,
                    supportsReasoning: true,
                    supportsToolCalls: true,
                    supportsPermissions: true
                ),
                providerState: ChatProviderState(
                    providerID: ProviderID(rawValue: "provider"),
                    modelID: ModelID(rawValue: "model"),
                    providerSessionID: AcpSessionID(rawValue: "session-1")
                )
            )),
            .event(.turnCompleted(ChatTurnID(rawValue: "turn-1"))),
        ], for: handle)

        let stream = try await runtime.eventStream(for: handle)
        async let collected = collectEvents(from: stream, expectedCount: 2)
        try await runtime.submitTurn(makeSubmission(), in: handle)
        await runtime.resumeGate("gate-1", for: handle)

        let events = await collected
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.generation == ChatSessionGenerationID(rawValue: "generation-1") })
        #expect(events[0].event == .sessionReady(
            capabilities: ChatCapabilitySet(
                supportsResume: true,
                supportsClose: true,
                supportsReasoning: true,
                supportsToolCalls: true,
                supportsPermissions: true
            ),
            providerState: ChatProviderState(
                providerID: ProviderID(rawValue: "provider"),
                modelID: ModelID(rawValue: "model"),
                providerSessionID: AcpSessionID(rawValue: "session-1")
            )
        ))
        #expect(events[1].event == .turnCompleted(ChatTurnID(rawValue: "turn-1")))
        await runtime.close(handle)
    }

    @Test func cancellationWhilePausedIsDeterministic() async throws {
        let runtime = ScriptedChatRuntime()
        let handle = try await runtime.start(makeStartRequest())
        try await runtime.enqueueSteps([.pause("gate-cancel")], for: handle)

        try await runtime.submitTurn(makeSubmission(), in: handle)
        try await runtime.cancelTurn(ChatTurnID(rawValue: "turn-1"), in: handle)

        let recorded = await runtime.cancelledTurns
        #expect(recorded.count == 1)
        #expect(recorded[0].turnID == ChatTurnID(rawValue: "turn-1"))
        await runtime.close(handle)
    }

    @Test func transportExitPreservesGenerationAndTurn() async throws {
        let runtime = ScriptedChatRuntime()
        let handle = try await runtime.start(makeStartRequest(generation: "generation-transport"))
        try await runtime.enqueueSteps([
            .event(.turnFailed(
                turnID: ChatTurnID(rawValue: "turn-transport"),
                category: .transportError,
                message: "socket closed"
            )),
            .finish(status: 9),
        ], for: handle)

        let stream = try await runtime.eventStream(for: handle)
        async let collected = collectEvents(from: stream, expectedCount: 2)
        try await runtime.submitTurn(makeSubmission(turnID: "turn-transport"), in: handle)
        let events = await collected

        #expect(events[0].generation == ChatSessionGenerationID(rawValue: "generation-transport"))
        #expect(events[0].event == .turnFailed(
            turnID: ChatTurnID(rawValue: "turn-transport"),
            category: .transportError,
            message: "socket closed"
        ))
        #expect(events[1].generation == ChatSessionGenerationID(rawValue: "generation-transport"))
        #expect(events[1].event == .transportClosed(status: 9))
        await runtime.close(handle)
    }

    @Test func terminalDeliveryRequiresNoSleep() async throws {
        let runtime = ScriptedChatRuntime()
        let handle = try await runtime.start(makeStartRequest())
        try await runtime.enqueueSteps([
            .event(.turnCancelled(ChatTurnID(rawValue: "turn-1"))),
            .finish(status: 0),
        ], for: handle)

        let stream = try await runtime.eventStream(for: handle)
        async let collected = collectEvents(from: stream, expectedCount: 2)
        try await runtime.submitTurn(makeSubmission(), in: handle)
        let events = await collected

        #expect(events.map(\.event) == [
            .turnCancelled(ChatTurnID(rawValue: "turn-1")),
            .transportClosed(status: 0),
        ])
        await runtime.close(handle)
    }

    @Test func storedGatePermitBeforeSubmitIsConsumedDeterministically() async throws {
        let runtime = ScriptedChatRuntime()
        let handle = try await runtime.start(makeStartRequest())
        try await runtime.enqueueSteps([
            .pause("gate-early"),
            .event(.turnCompleted(ChatTurnID(rawValue: "turn-1"))),
        ], for: handle)

        let stream = try await runtime.eventStream(for: handle)
        async let collected = collectEvents(from: stream, expectedCount: 1)

        await runtime.resumeGate("gate-early", for: handle)
        try await runtime.submitTurn(makeSubmission(), in: handle)

        let events = await collected
        #expect(events.map(\.event) == [.turnCompleted(ChatTurnID(rawValue: "turn-1"))])
        await runtime.close(handle)
    }

    @Test func identicalGateIDsDoNotCrossTalkAcrossRuntimeHandles() async throws {
        let runtime = ScriptedChatRuntime()
        let firstHandle = try await runtime.start(makeStartRequest(generation: "generation-1"))
        let secondHandle = try await runtime.start(makeStartRequest(generation: "generation-2"))
        try await runtime.enqueueSteps([
            .pause("shared-gate"),
            .event(.turnCompleted(ChatTurnID(rawValue: "turn-1"))),
        ], for: firstHandle)
        try await runtime.enqueueSteps([
            .pause("shared-gate"),
            .event(.turnCompleted(ChatTurnID(rawValue: "turn-2"))),
        ], for: secondHandle)

        let firstStream = try await runtime.eventStream(for: firstHandle)
        let secondStream = try await runtime.eventStream(for: secondHandle)
        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()

        try await runtime.submitTurn(makeSubmission(turnID: "turn-1"), in: firstHandle)
        try await runtime.submitTurn(makeSubmission(turnID: "turn-2"), in: secondHandle)

        await runtime.resumeGate("shared-gate", for: firstHandle)
        let firstEvent = await firstIterator.next()
        #expect(firstEvent?.generation == ChatSessionGenerationID(rawValue: "generation-1"))
        #expect(firstEvent?.event == .turnCompleted(ChatTurnID(rawValue: "turn-1")))

        await runtime.resumeGate("shared-gate", for: secondHandle)
        let secondEvent = await secondIterator.next()
        #expect(secondEvent?.generation == ChatSessionGenerationID(rawValue: "generation-2"))
        #expect(secondEvent?.event == .turnCompleted(ChatTurnID(rawValue: "turn-2")))

        await runtime.close(firstHandle)
        await runtime.close(secondHandle)
    }
}
#endif
