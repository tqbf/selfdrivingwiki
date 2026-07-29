#if canImport(WikiFSEngine)
import Foundation
@testable import WikiFSEngine
import WikiFSTypes

actor ScriptedChatRuntime: ChatAgentRuntime {
    enum Error: Swift.Error, Equatable {
        case unknownHandle
        case duplicateSubscriber
    }

    enum Step: Sendable {
        case pause(String)
        case event(ChatAgentRuntimeEvent)
        case snapshot(ChatRuntimeSnapshot)
        case finish(status: Int32?)
    }

    private struct GateKey: Hashable, Sendable {
        let handle: ChatRuntimeHandle
        let gateID: String
    }

    private struct GateWaiter {
        let order: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct RuntimeState: Sendable {
        let generation: ChatSessionGenerationID
        let stream: AsyncStream<ChatAgentRuntimeEventEnvelope>
        let continuation: AsyncStream<ChatAgentRuntimeEventEnvelope>.Continuation
        var snapshot: ChatRuntimeSnapshot
        var steps: [Step]
        var drainTask: Task<Void, Never>?
        var hasSubscriber = false
    }

    private var nextHandle = 0
    private var nextWaiterOrder = 0
    private var runtimes: [ChatRuntimeHandle: RuntimeState] = [:]
    private var gateWaiters: [GateKey: [GateWaiter]] = [:]
    private var gatePermits: [GateKey: Int] = [:]

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
            transientTranscriptOverlay: [],
            lastIncludedSequence: ChatUpdateSequence(rawValue: 0)
        )
        runtimes[handle] = RuntimeState(
            generation: request.generation,
            stream: stream,
            continuation: continuation,
            snapshot: snapshot,
            steps: [],
            drainTask: nil,
            hasSubscriber: false
        )
        return handle
    }

    func eventStream(for handle: ChatRuntimeHandle) async throws -> AsyncStream<ChatAgentRuntimeEventEnvelope> {
        guard var runtime = runtimes[handle] else { throw Error.unknownHandle }
        guard runtime.hasSubscriber == false else { throw Error.duplicateSubscriber }
        runtime.hasSubscriber = true
        runtimes[handle] = runtime
        return runtime.stream
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
        try await startDrainIfNeeded(for: handle)
    }

    func resumeGate(_ gateID: String, for handle: ChatRuntimeHandle) {
        let gateKey = GateKey(handle: handle, gateID: gateID)
        guard var waiters = gateWaiters[gateKey], waiters.isEmpty == false else {
            gatePermits[gateKey, default: 0] += 1
            return
        }

        let waiter = waiters.removeFirst()
        gateWaiters[gateKey] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume()
    }

    private func claimGatePermit(_ gateKey: GateKey) -> Bool {
        guard let permits = gatePermits[gateKey], permits > 0 else {
            return false
        }
        gatePermits[gateKey] = permits == 1 ? nil : permits - 1
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
        defer { clearDrainTask(for: handle) }

        while Task.isCancelled == false {
            guard let step = nextStep(for: handle) else {
                return
            }

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
        let gateKey = GateKey(handle: handle, gateID: gateID)
        if claimGatePermit(gateKey) {
            return
        }
        await withCheckedContinuation { continuation in
            nextWaiterOrder += 1
            gateWaiters[gateKey, default: []].append(
                GateWaiter(order: nextWaiterOrder, continuation: continuation)
            )
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

    private func clearDrainTask(for handle: ChatRuntimeHandle) {
        guard var runtime = runtimes[handle] else { return }
        runtime.drainTask = nil
        runtimes[handle] = runtime
    }

    private func resumeWaiters(for handle: ChatRuntimeHandle) {
        let keys = gateWaiters.keys.filter { $0.handle == handle }
        for key in keys {
            guard let waiters = gateWaiters.removeValue(forKey: key) else { continue }
            for waiter in waiters.sorted(by: { $0.order < $1.order }) {
                waiter.continuation.resume()
            }
        }
    }
}
#endif
