#if os(macOS)
import Foundation
import Testing
@testable import WikiFSEngine

@Suite("Cordis daemon transport runtime", .serialized, .timeLimit(.minutes(1)))
struct DaemonTransportRuntimeAssemblyTests {
    @Test("shuffled registration builds ready transport services")
    func shuffledRegistrationBuildsReadyTransportServices() async throws {
        let factory = FakeTransportFactory()
        let handle = try await assembly(factory).assemble(
            registrationOrder: DaemonTransportRuntimeAssembly.Component.allCases.shuffled())
        #expect(await handle.services.availability() == .idle)
        try await handle.dispose()
    }

    @Test("missing registration fails with typed component error")
    func missingRegistrationFailsWithTypedComponentError() async throws {
        let order = DaemonTransportRuntimeAssembly.Component.allCases.filter { $0 != .configuration }
        let factory = FakeTransportFactory()
        do {
            _ = try await assembly(factory).assemble(registrationOrder: order)
            Issue.record("Expected assembly failure")
        } catch {
            guard case .activationFailed(let component, _) = error as? DaemonTransportRuntimeAssemblyError else {
                Issue.record("Expected typed component failure, got \(error)")
                return
            }
            #expect(component == DaemonTransportRuntimeAssembly.Component.configuration.rawValue)
        }
    }

    @Test("reconnect publishes candidate only after successful health check")
    func reconnectPublishesCandidateOnlyAfterSuccessfulHealthCheck() async throws {
        let factory = FakeTransportFactory(healthResults: [false, true])
        let handle = try await assembly(factory).assemble()
        let events = await handle.services.events()
        let task = Task { () -> [DaemonTransportEvent] in
            var result: [DaemonTransportEvent] = []
            for await event in events {
                result.append(event)
                if case .awaitingAcceptance = event { break }
            }
            return result
        }
        await handle.services.startAdmission()
        let observed = await task.value
        #expect(observed.first == .reconnecting)
        #expect(observed.filter { if case .awaitingAcceptance = $0 { true } else { false } }.count == 1)
        #expect(!observed.contains { if case .connected = $0 { true } else { false } })
        #expect(await factory.invalidatedCount == 1)
        try await handle.dispose()
    }

    @Test("rejected candidate is invalidated and leaves transport disconnected")
    func rejectedCandidateIsInvalidatedAndLeavesTransportDisconnected() async throws {
        let factory = FakeTransportFactory()
        let handle = try await assembly(factory).assemble()
        let stream = await handle.services.events()
        let candidateTask = Task { await firstCandidate(from: stream) }
        await handle.services.startAdmission()
        let id = try #require(await candidateTask.value)
        await handle.services.acknowledge(.init(candidateID: id, outcome: .retry))
        #expect(await factory.wasInvalidated(id))
        #expect(await handle.services.availability() == .retrying)
        try await handle.dispose()
    }

    @Test("local fallback acknowledgement stops transport without republishing")
    func localFallbackAcknowledgementStopsTransportWithoutRepublishing() async throws {
        let factory = FakeTransportFactory()
        let handle = try await assembly(factory).assemble()
        let stream = await handle.services.events()
        let candidateTask = Task { await firstCandidate(from: stream) }
        await handle.services.startAdmission()
        let id = try #require(await candidateTask.value)
        await handle.services.acknowledge(.init(candidateID: id, outcome: .localFallbackReady))
        #expect(await handle.services.availability() == .stopped)
        #expect(await factory.wasInvalidated(id))
        try await handle.dispose()
    }

    @Test("stale or duplicate acknowledgement cannot affect current candidate")
    func staleOrDuplicateAcknowledgementCannotAffectCurrentCandidate() async throws {
        let factory = FakeTransportFactory()
        let handle = try await assembly(factory).assemble()
        let stream = await handle.services.events()
        let candidateTask = Task { await firstCandidate(from: stream) }
        await handle.services.startAdmission()
        let id = try #require(await candidateTask.value)
        await handle.services.acknowledge(.init(candidateID: DaemonTransportCandidateID(), outcome: .connected))
        #expect(await handle.services.availability() == .awaitingAcceptance(id))
        await handle.services.acknowledge(.init(candidateID: id, outcome: .connected))
        await handle.services.acknowledge(.init(candidateID: id, outcome: .retry))
        #expect(await handle.services.availability() == .connected(id))
        try await handle.dispose()
    }

    @Test("invalidation publishes disconnect once per generation")
    func invalidationPublishesDisconnectOncePerGeneration() async throws {
        let factory = FakeTransportFactory()
        let handle = try await assembly(factory).assemble()
        let stream = await handle.services.events()
        let candidateTask = Task { await firstCandidate(from: stream) }
        await handle.services.startAdmission()
        let id = try #require(await candidateTask.value)
        let disconnectStream = await handle.services.events()
        let disconnectTask = Task { () -> Int in
            var disconnects = 0
            for await event in disconnectStream {
                if case .disconnected = event {
                    disconnects += 1
                    return disconnects
                }
            }
            return disconnects
        }
        await handle.services.acknowledge(.init(candidateID: id, outcome: .connected))
        await factory.invalidate(id)
        await factory.invalidate(id)
        #expect(await disconnectTask.value == 1)
        try await handle.dispose()
    }

    @Test("interruption retains connection and publishes re-registration event")
    func interruptionRetainsConnectionAndPublishesReRegistrationEvent() async throws {
        let factory = FakeTransportFactory()
        let handle = try await assembly(factory).assemble()
        let stream = await handle.services.events()
        let candidateTask = Task { await firstCandidate(from: stream) }
        await handle.services.startAdmission()
        let id = try #require(await candidateTask.value)
        await handle.services.acknowledge(.init(candidateID: id, outcome: .connected))
        let interruptStream = await handle.services.events()
        let interruptTask = Task { () -> DaemonTransportEvent? in
            for await event in interruptStream where event == .interrupted(id) { return event }
            return nil
        }
        await factory.interrupt(id)
        #expect(await interruptTask.value == .interrupted(id))
        #expect(await handle.services.availability() == .connected(id))
        #expect(!(await factory.wasInvalidated(id)))
        try await handle.dispose()
    }

    @Test("acceptance deadline expires candidate and retries")
    func acceptanceDeadlineExpiresCandidateAndRetries() async throws {
        let factory = FakeTransportFactory()
        let handle = try await DaemonTransportRuntimeAssembly(
            connectionFactory: factory.factory,
            configuration: .init(
                retryInterval: .seconds(3_600),
                healthCheckInterval: .seconds(3_600),
                healthCheckTimeout: 1,
                acceptanceDeadline: .milliseconds(10)))
            .assemble()
        let stream = await handle.services.events()
        let eventTask = Task { () -> DaemonTransportCandidateID? in
            var expiredID: DaemonTransportCandidateID?
            for await event in stream {
                if case .acceptanceExpired(let id) = event { expiredID = id }
                if event == .reconnecting, let expiredID { return expiredID }
            }
            return nil
        }
        await handle.services.startAdmission()
        let expiredID = try #require(await eventTask.value)
        #expect(await factory.wasInvalidated(expiredID))
        #expect(await handle.services.availability() != .awaitingAcceptance(expiredID))
        try await handle.dispose()
    }

    @Test("shutdown rejects late probe or candidate result")
    func shutdownRejectsLateProbeOrCandidateResult() async throws {
        let gate = ProbeGate()
        let factory = GatedTransportFactory(gate: gate)
        let handle = try await DaemonTransportRuntimeAssembly(
            connectionFactory: factory.factory,
            configuration: .init(
                retryInterval: .seconds(3_600),
                healthCheckInterval: .seconds(3_600),
                healthCheckTimeout: 1,
                acceptanceDeadline: .seconds(3_600)))
            .assemble()
        let stream = await handle.services.events()
        let eventTask = Task { () -> [DaemonTransportEvent] in
            var events: [DaemonTransportEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        await handle.services.startAdmission()
        await gate.waitUntilProbeStarted()
        let disposeTask = Task { try await handle.dispose() }
        await gate.release(healthy: true)
        try await disposeTask.value
        let events = await eventTask.value
        #expect(!events.contains { if case .awaitingAcceptance = $0 { true } else { false } })
        #expect(await handle.services.availability() == .stopped)
    }

    @Test("dispose is idempotent and stops retry loop")
    func disposeIsIdempotentAndStopsRetryLoop() async throws {
        let factory = FakeTransportFactory()
        let handle = try await assembly(factory).assemble()
        let stream = await handle.services.events()
        let candidateTask = Task { await firstCandidate(from: stream) }
        await handle.services.startAdmission()
        _ = try #require(await candidateTask.value)
        try await handle.dispose()
        try await handle.dispose()
        #expect(await handle.services.availability() == .stopped)
    }

    @Test("transport assembly stays outside UI queue persistence and wire boundaries")
    func transportAssemblyStaysOutsideUIQueuePersistenceAndWireBoundaries() throws {
        let root = repositoryRoot()
        let assemblySource = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSEngine/DaemonTransportRuntimeAssembly.swift"),
            encoding: .utf8)
        for label in [
            "daemon-transport.connection-factory",
            "daemon-transport.configuration",
            "daemon-transport.runtime",
            "daemon-transport.services",
        ] { #expect(assemblySource.contains(label)) }
        for forbidden in [
            "SwiftUI", "DaemonHealthMonitor", "QueueEngineHotSwap", "LocalQueueRuntimeController",
            "QueueStore", "WikiStore", "WikiStoreModel", "WikiSession", "SessionManager",
            "ChatDaemonCoordinator", "WikiDaemonProtocol", "WikiDaemonEventSink",
            "WikiDaemonConnection", "NSXPCConnection",
        ] { #expect(!assemblySource.contains(forbidden)) }
    }

    private func assembly(_ factory: FakeTransportFactory) -> DaemonTransportRuntimeAssembly {
        DaemonTransportRuntimeAssembly(
            connectionFactory: factory.factory,
            configuration: .init(
                retryInterval: .zero,
                healthCheckInterval: .seconds(3_600),
                healthCheckTimeout: 1,
                acceptanceDeadline: .seconds(3_600)))
    }
}

private actor FakeTransportFactory {
    private var remainingHealthResults: [Bool]
    private var connections: [DaemonTransportCandidateID: FakeTransportConnection] = [:]
    private var latestID: DaemonTransportCandidateID?

    init(healthResults: [Bool] = [true]) {
        remainingHealthResults = healthResults
    }

    nonisolated var factory: DaemonTransportConnectionFactory {
        DaemonTransportConnectionFactory { [weak self] id in
            guard let self else { throw CancellationError() }
            return await self.make(id)
        }
    }

    var latestCandidateID: DaemonTransportCandidateID? { latestID }
    var invalidatedCount: Int { connections.values.filter(\.invalidated).count }

    func wasInvalidated(_ id: DaemonTransportCandidateID) -> Bool {
        connections[id]?.invalidated ?? false
    }

    func invalidate(_ id: DaemonTransportCandidateID) {
        connections[id]?.fireInvalidation()
    }

    func interrupt(_ id: DaemonTransportCandidateID) {
        connections[id]?.fireInterruption()
    }

    private func make(_ id: DaemonTransportCandidateID) -> FakeTransportConnection {
        let result = remainingHealthResults.isEmpty ? true : remainingHealthResults.removeFirst()
        let connection = FakeTransportConnection(healthy: result)
        connections[id] = connection
        latestID = id
        return connection
    }
}

private final class FakeTransportConnection: DaemonTransportConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let healthy: Bool
    private var invalidationHandler: (@Sendable () -> Void)?
    private var interruptionHandler: (@Sendable () -> Void)?
    private(set) var invalidated = false

    init(healthy: Bool) { self.healthy = healthy }
    func healthCheck(timeout: TimeInterval) async -> Bool { healthy }
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidationHandler = handler }
    }
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { interruptionHandler = handler }
    }
    func invalidate() { lock.withLock { invalidated = true } }
    func fireInvalidation() { lock.withLock { invalidationHandler }?() }
    func fireInterruption() { lock.withLock { interruptionHandler }?() }
}

private actor ProbeGate {
    private var probeStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var result: Bool?
    private var resultWaiters: [CheckedContinuation<Bool, Never>] = []

    func waitUntilProbeStarted() async {
        if probeStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForResult() async -> Bool {
        probeStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if let result { return result }
        return await withCheckedContinuation { resultWaiters.append($0) }
    }

    func release(healthy: Bool) {
        guard result == nil else { return }
        result = healthy
        let waiters = resultWaiters
        resultWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: healthy) }
    }
}

private actor GatedTransportFactory {
    private let gate: ProbeGate

    init(gate: ProbeGate) { self.gate = gate }

    nonisolated var factory: DaemonTransportConnectionFactory {
        DaemonTransportConnectionFactory { [gate] _ in
            GatedTransportConnection(gate: gate)
        }
    }
}

private final class GatedTransportConnection: DaemonTransportConnection, @unchecked Sendable {
    private let gate: ProbeGate
    init(gate: ProbeGate) { self.gate = gate }
    func healthCheck(timeout: TimeInterval) async -> Bool { await gate.waitForResult() }
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}
    func invalidate() {}
}

private func firstCandidate(
    from stream: AsyncStream<DaemonTransportEvent>
) async -> DaemonTransportCandidateID? {
    for await event in stream {
        if case .awaitingAcceptance(let id) = event { return id }
    }
    return nil
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
#endif
