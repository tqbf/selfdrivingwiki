#if canImport(WikiFSEngine)
import Foundation
@testable import WikiFSEngine
import WikiFSTypes

actor ScriptedChatRuntime: ChatAgentRuntime {
    enum Error: Swift.Error {
        case unknownHandle
    }

    enum Step: Sendable {
        case pause(String)
        case event(ChatAgentRuntimeEvent)
        case snapshot(ChatRuntimeSnapshot)
        case finish(status: Int32?)
    }

    private struct RuntimeState: Sendable {
        let generation: ChatSessionGenerationID
        let stream: AsyncStream<ChatAgentRuntimeEventEnvelope>
        let continuation: AsyncStream<ChatAgentRuntimeEventEnvelope>.Continuation
        var snapshot: ChatRuntimeSnapshot
        var steps: [Step]
        var drainTask: Task<Void, Never>?
    }

    private var nextHandle = 0
    private var runtimes: [ChatRuntimeHandle: RuntimeState] = [:]
    private var gateWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    private var gateWaiterHandles: [UUID: ChatRuntimeHandle] = [:]
    private var gatePermits: [String: Int] = [:]

    private(set) var startedRequests: [ChatRuntimeStartRequest] = []
    private(set) var submittedTurns: [(handle: ChatRuntimeHandle, submission: ChatTurnSubmission)] = []
    private(set) var cancelledTurns: [(handle: ChatRuntimeHandle, turnID: ChatTurnID?)] = []
    private(set) var resolvedPermissions: [(handle: ChatRuntimeHandle, resolution: ChatPermissionResolution)] = []
    private(set) var configurationChanges: [(handle: ChatRuntimeHandle, change: ChatRuntimeConfigurationChange)] = []
    private(set) var closedHandles: [ChatRuntimeHandle] = []

    func start(_ request: ChatRuntimeStartRequest) async throws -> ChatRuntimeHandle {
        startedRequests.append(request)
        nextHandle += 1
        let handle = ChatRuntimeHandle(rawValue: "scripted-\(nextHandle)")
        let (stream, continuation) = AsyncStream.makeStream(of: ChatAgentRuntimeEventEnvelope.self)
        let snapshot = ChatRuntimeSnapshot(
            chatID: request.chatID,
            generation: request.generation,
            lifecycle: .starting,
            activeTurn: nil,
            queuedTurns: [],
            attention: .none,
            capabilities: .unavailable,
            providerState: ChatProviderState(
                providerID: request.providerID,
                modelID: request.modelID,
                providerSessionID: request.existingProviderSessionID
            ),
            usage: nil,
            diagnostics: ChatDiagnosticsState(),
            committedTranscriptCursor: nil,
            transientTranscriptOverlay: [],
            lastIncludedSequence: ChatUpdateSequence(rawValue: 0)
        )
        runtimes[handle] = RuntimeState(
            generation: request.generation,
            stream: stream,
            continuation: continuation,
            snapshot: snapshot,
            steps: [],
            drainTask: nil
        )
        return handle
    }

    nonisolated func eventStream(for handle: ChatRuntimeHandle) -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
        AsyncStream { continuation in
            let task = Task {
                let stream = await self.runtimeStream(for: handle)
                for await value in stream {
                    guard Task.isCancelled == false else { break }
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runtimeStream(for handle: ChatRuntimeHandle) -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
        runtimes[handle]?.stream ?? AsyncStream { $0.finish() }
    }

    func submitTurn(_ submission: ChatTurnSubmission, in handle: ChatRuntimeHandle) async throws {
        guard runtimes[handle] != nil else { throw Error.unknownHandle }
        submittedTurns.append((handle, submission))
        try await startDrainIfNeeded(for: handle)
    }

    func cancelTurn(_ turnID: ChatTurnID?, in handle: ChatRuntimeHandle) async throws {
        guard runtimes[handle] != nil else { throw Error.unknownHandle }
        cancelledTurns.append((handle, turnID))
    }

    func resolvePermission(_ resolution: ChatPermissionResolution, in handle: ChatRuntimeHandle) async throws {
        guard runtimes[handle] != nil else { throw Error.unknownHandle }
        resolvedPermissions.append((handle, resolution))
    }

    func setConfiguration(_ change: ChatRuntimeConfigurationChange, in handle: ChatRuntimeHandle) async throws {
        guard runtimes[handle] != nil else { throw Error.unknownHandle }
        configurationChanges.append((handle, change))
    }

    func snapshot(for handle: ChatRuntimeHandle) async throws -> ChatRuntimeSnapshot {
        guard let runtime = runtimes[handle] else { throw Error.unknownHandle }
        return runtime.snapshot
    }

    func close(_ handle: ChatRuntimeHandle) async {
        closedHandles.append(handle)
        guard let runtime = runtimes.removeValue(forKey: handle) else { return }
        resumeWaiters(for: handle)
        runtime.drainTask?.cancel()
        runtime.continuation.finish()
    }

    func enqueueSteps(_ steps: [Step], for handle: ChatRuntimeHandle) async throws {
        guard var runtime = runtimes[handle] else { throw Error.unknownHandle }
        runtime.steps.append(contentsOf: steps)
        runtimes[handle] = runtime
    }

    func resumeGate(_ gateID: String) {
        guard var waiters = gateWaiters[gateID], waiters.isEmpty == false else {
            gatePermits[gateID, default: 0] += 1
            return
        }

        let waiterID = waiters.keys.sorted { $0.uuidString < $1.uuidString }.first!
        let waiter = waiters.removeValue(forKey: waiterID)!
        gateWaiterHandles.removeValue(forKey: waiterID)
        gateWaiters[gateID] = waiters.isEmpty ? nil : waiters
        waiter.resume()
    }

    private func claimGatePermit(_ gateID: String) -> Bool {
        guard let permits = gatePermits[gateID], permits > 0 else {
            return false
        }
        gatePermits[gateID] = permits == 1 ? nil : permits - 1
        return true
    }

    private func startDrainIfNeeded(for handle: ChatRuntimeHandle) async throws {
        guard var runtime = runtimes[handle] else { throw Error.unknownHandle }
        guard runtime.drainTask == nil else { return }
        runtime.drainTask = Task { [weak self] in
            await self?.drain(handle)
        }
        runtimes[handle] = runtime
    }

    private func drain(_ handle: ChatRuntimeHandle) async {
        while let step = nextStep(for: handle) {
            switch step {
            case .pause(let gateID):
                await waitForGate(gateID, handle: handle)
            case .event(let event):
                emit(event, for: handle)
            case .snapshot(let snapshot):
                updateSnapshot(snapshot, for: handle)
            case .finish(let status):
                emit(.transportClosed(status: status), for: handle)
                finishStream(for: handle)
                return
            }
        }
    }

    private func nextStep(for handle: ChatRuntimeHandle) -> Step? {
        guard var runtime = runtimes[handle], runtime.steps.isEmpty == false else { return nil }
        let step = runtime.steps.removeFirst()
        runtimes[handle] = runtime
        return step
    }

    private func waitForGate(_ gateID: String, handle: ChatRuntimeHandle) async {
        if claimGatePermit(gateID) {
            return
        }
        await withCheckedContinuation { continuation in
            let id = UUID()
            gateWaiters[gateID, default: [:]][id] = continuation
            gateWaiterHandles[id] = handle
        }
    }

    private func emit(_ event: ChatAgentRuntimeEvent, for handle: ChatRuntimeHandle) {
        guard let runtime = runtimes[handle] else { return }
        runtime.continuation.yield(ChatAgentRuntimeEventEnvelope(generation: runtime.generation, event: event))
    }

    private func updateSnapshot(_ snapshot: ChatRuntimeSnapshot, for handle: ChatRuntimeHandle) {
        guard var runtime = runtimes[handle] else { return }
        runtime.snapshot = snapshot
        runtimes[handle] = runtime
    }

    private func finishStream(for handle: ChatRuntimeHandle) {
        guard let runtime = runtimes[handle] else { return }
        runtime.continuation.finish()
    }

    private func resumeWaiters(for handle: ChatRuntimeHandle) {
        let waiterIDs = gateWaiterHandles
            .filter { $0.value == handle }
            .map(\.key)
        for waiterID in waiterIDs {
            resumeWaiter(waiterID)
        }
    }

    private func resumeWaiter(_ waiterID: UUID) {
        guard gateWaiterHandles.removeValue(forKey: waiterID) != nil else { return }
        let gateIDs = gateWaiters.keys.filter { gateWaiters[$0]?[waiterID] != nil }
        for gateID in gateIDs {
            guard var waiters = gateWaiters[gateID] else { continue }
            guard let waiter = waiters.removeValue(forKey: waiterID) else { continue }
            gateWaiters[gateID] = waiters.isEmpty ? nil : waiters
            waiter.resume()
        }
    }

    func recordedCancelledTurns() -> [(handle: ChatRuntimeHandle, turnID: ChatTurnID?)] {
        cancelledTurns
    }
}
#endif
