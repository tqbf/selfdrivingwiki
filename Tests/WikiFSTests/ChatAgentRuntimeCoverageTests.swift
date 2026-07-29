#if canImport(WikiFSEngine)
import Foundation
import Testing
@testable import WikiFSEngine
import WikiFSTypes

struct ChatAgentRuntimeCoverageTests {
    actor RuntimeCallRecorder {
        struct SubmitCall: Equatable, Sendable {
            let submission: ChatTurnSubmission
            let handle: ChatRuntimeHandle
        }

        struct CancelCall: Equatable, Sendable {
            let turnID: ChatTurnID?
            let handle: ChatRuntimeHandle
        }

        struct PermissionCall: Equatable, Sendable {
            let resolution: ChatPermissionResolution
            let handle: ChatRuntimeHandle
        }

        struct ConfigurationCall: Equatable, Sendable {
            let change: ChatRuntimeConfigurationChange
            let handle: ChatRuntimeHandle
        }

        private(set) var startedRequests: [ChatRuntimeStartRequest] = []
        private(set) var submittedCalls: [SubmitCall] = []
        private(set) var cancelledCalls: [CancelCall] = []
        private(set) var permissionCalls: [PermissionCall] = []
        private(set) var configurationCalls: [ConfigurationCall] = []
        private(set) var snapshotCalls: [ChatRuntimeHandle] = []
        private(set) var closedHandles: [ChatRuntimeHandle] = []

        func recordStart(_ request: ChatRuntimeStartRequest) {
            startedRequests.append(request)
        }

        func recordSubmit(_ submission: ChatTurnSubmission, handle: ChatRuntimeHandle) {
            submittedCalls.append(SubmitCall(submission: submission, handle: handle))
        }

        func recordCancel(_ turnID: ChatTurnID?, handle: ChatRuntimeHandle) {
            cancelledCalls.append(CancelCall(turnID: turnID, handle: handle))
        }

        func recordPermission(_ resolution: ChatPermissionResolution, handle: ChatRuntimeHandle) {
            permissionCalls.append(PermissionCall(resolution: resolution, handle: handle))
        }

        func recordConfiguration(_ change: ChatRuntimeConfigurationChange, handle: ChatRuntimeHandle) {
            configurationCalls.append(ConfigurationCall(change: change, handle: handle))
        }

        func recordSnapshot(_ handle: ChatRuntimeHandle) {
            snapshotCalls.append(handle)
        }

        func recordClose(_ handle: ChatRuntimeHandle) {
            closedHandles.append(handle)
        }
    }

    private func makeHandle(_ rawValue: String = "handle-1") -> ChatRuntimeHandle {
        ChatRuntimeHandle(rawValue: rawValue)
    }

    private func makeSubmission() -> ChatTurnSubmission {
        ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "command-1"),
            turnID: ChatTurnID(rawValue: "turn-1"),
            userText: "Hello",
            contextReferences: [.chat(ChatID(rawValue: "chat-1"))],
            submittedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makeSnapshot() -> ChatRuntimeSnapshot {
        ChatRuntimeSnapshot(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            lifecycle: .ready,
            activeTurn: nil,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            transientTranscriptOverlay: [],
            lastIncludedSequence: ChatUpdateSequence(rawValue: 0)
        )
    }

    @Test func closureBackedRuntimeForwardsEveryOperation() async throws {
        let handle = makeHandle()
        let submission = makeSubmission()
        let resolution = ChatPermissionResolution(
            requestID: PermissionRequestID(rawValue: "permission-1"),
            optionID: PermissionOptionID(rawValue: "option-1")
        )
        let configuration = ChatRuntimeConfigurationChange(
            optionID: ChatConfigurationOptionID(rawValue: "option-1"),
            valueID: ChatConfigurationValueID(rawValue: "value-1")
        )
        let snapshot = makeSnapshot()
        let envelope = ChatAgentRuntimeEventEnvelope(
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            event: .turnCompleted(ChatTurnID(rawValue: "turn-1"))
        )
        let (stream, continuation) = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)

        let recorder = RuntimeCallRecorder()

        let runtime = ClosureBackedChatAgentRuntime(
            start: { request in
                await recorder.recordStart(request)
                return handle
            },
            eventStream: { requestedHandle in
                #expect(requestedHandle == handle)
                continuation.yield(envelope)
                continuation.finish()
                return stream
            },
            submitTurn: { submission, requestedHandle in
                await recorder.recordSubmit(submission, handle: requestedHandle)
            },
            cancelTurn: { turnID, requestedHandle in
                await recorder.recordCancel(turnID, handle: requestedHandle)
            },
            resolvePermission: { resolution, requestedHandle in
                await recorder.recordPermission(resolution, handle: requestedHandle)
            },
            setConfiguration: { change, requestedHandle in
                await recorder.recordConfiguration(change, handle: requestedHandle)
            },
            snapshot: { requestedHandle in
                await recorder.recordSnapshot(requestedHandle)
                return snapshot
            },
            close: { requestedHandle in
                await recorder.recordClose(requestedHandle)
            }
        )

        let startRequest = ChatRuntimeStartRequest(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            systemPrompt: "system",
            providerID: ProviderID(rawValue: "provider-1"),
            modelID: ModelID(rawValue: "model-1"),
            existingProviderSessionID: AcpSessionID(rawValue: "session-1")
        )
        let startedHandle = try await runtime.start(startRequest)
        #expect(startedHandle == handle)
        #expect(await recorder.startedRequests == [startRequest])

        let returnedStream = try await runtime.eventStream(for: handle)
        var iterator = returnedStream.makeAsyncIterator()
        #expect(await iterator.next() == envelope)
        #expect(await iterator.next() == nil)

        try await runtime.submitTurn(submission, in: handle)
        try await runtime.cancelTurn(ChatTurnID(rawValue: "turn-1"), in: handle)
        try await runtime.resolvePermission(resolution, in: handle)
        try await runtime.setConfiguration(configuration, in: handle)
        let fetchedSnapshot = try await runtime.snapshot(for: handle)
        await runtime.close(handle)

        let submittedCalls = await recorder.submittedCalls
        #expect(submittedCalls.count == 1)
        #expect(submittedCalls[0] == RuntimeCallRecorder.SubmitCall(submission: submission, handle: handle))
        #expect(await recorder.cancelledCalls == [
            RuntimeCallRecorder.CancelCall(turnID: ChatTurnID(rawValue: "turn-1"), handle: handle)
        ])
        #expect(await recorder.permissionCalls == [
            RuntimeCallRecorder.PermissionCall(resolution: resolution, handle: handle)
        ])
        #expect(await recorder.configurationCalls == [
            RuntimeCallRecorder.ConfigurationCall(change: configuration, handle: handle)
        ])
        #expect(await recorder.snapshotCalls == [handle])
        #expect(fetchedSnapshot == snapshot)
        #expect(await recorder.closedHandles == [handle])
    }

    @Test func scriptedRuntimeRestartsDrainAfterLateEnqueueAndRejectsInvalidSubscribers() async throws {
        let runtime = ScriptedChatRuntime()
        let handle = try await runtime.start(ChatRuntimeStartRequest(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            systemPrompt: "system",
            providerID: ProviderID(rawValue: "provider-1"),
            modelID: ModelID(rawValue: "model-1"),
            existingProviderSessionID: nil
        ))

        let stream = try await runtime.eventStream(for: handle)
        var iterator = stream.makeAsyncIterator()

        do {
            _ = try await runtime.eventStream(for: handle)
            Issue.record("second subscriber should throw duplicateSubscriber")
        } catch let error as ScriptedChatRuntime.Error {
            #expect(error == .duplicateSubscriber)
        }

        do {
            _ = try await runtime.eventStream(for: ChatRuntimeHandle(rawValue: "missing"))
            Issue.record("unknown handle should throw unknownHandle")
        } catch let error as ScriptedChatRuntime.Error {
            #expect(error == .unknownHandle)
        }

        try await runtime.enqueueSteps([.event(.turnCompleted(ChatTurnID(rawValue: "turn-1")))], for: handle)
        try await runtime.submitTurn(makeSubmission(), in: handle)
        #expect(await iterator.next()?.event == .turnCompleted(ChatTurnID(rawValue: "turn-1")))

        try await runtime.enqueueSteps([.event(.turnCompleted(ChatTurnID(rawValue: "turn-2")))], for: handle)
        try await runtime.submitTurn(ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "command-2"),
            turnID: ChatTurnID(rawValue: "turn-2"),
            userText: "Again",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 20)
        ), in: handle)
        #expect(await iterator.next()?.event == .turnCompleted(ChatTurnID(rawValue: "turn-2")))

        await runtime.close(handle)
    }

    @Test func scriptedRuntimeStoresGatePermitsBeforeDrainParks() async throws {
        let runtime = ScriptedChatRuntime()
        let handle = try await runtime.start(ChatRuntimeStartRequest(
            chatID: ChatID(rawValue: "chat-1"),
            generation: ChatSessionGenerationID(rawValue: "generation-1"),
            systemPrompt: "system",
            providerID: ProviderID(rawValue: "provider-1"),
            modelID: ModelID(rawValue: "model-1"),
            existingProviderSessionID: nil
        ))
        try await runtime.enqueueSteps([
            .pause("gate-early"),
            .event(.turnCompleted(ChatTurnID(rawValue: "turn-1"))),
        ], for: handle)

        await runtime.resumeGate("gate-early")

        let stream = try await runtime.eventStream(for: handle)
        var iterator = stream.makeAsyncIterator()
        try await runtime.submitTurn(makeSubmission(), in: handle)

        #expect(await iterator.next()?.event == .turnCompleted(ChatTurnID(rawValue: "turn-1")))
        await runtime.close(handle)
    }
}
#endif
