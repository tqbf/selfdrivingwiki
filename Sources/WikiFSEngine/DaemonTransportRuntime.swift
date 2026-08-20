#if os(macOS)
import Foundation
import WikiFSCore

public struct DaemonTransportCandidateID: Hashable, Sendable, CustomStringConvertible {
    private let rawValue: UUID

    public init() {
        rawValue = UUID()
    }

    public var description: String { rawValue.uuidString }
}

public protocol DaemonTransportConnection: Sendable {
    func healthCheck(timeout: TimeInterval) async -> Bool
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void)
    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void)
    func invalidate()
}

public struct DaemonTransportConnectionFactory: Sendable {
    private let make: @Sendable (DaemonTransportCandidateID) async throws -> any DaemonTransportConnection

    public init(
        makeCandidate: @escaping @Sendable (DaemonTransportCandidateID) async throws -> any DaemonTransportConnection
    ) {
        make = makeCandidate
    }

    public func makeCandidate(id: DaemonTransportCandidateID) async throws -> any DaemonTransportConnection {
        try await make(id)
    }
}

public enum DaemonTransportAvailability: Sendable, Equatable {
    case idle
    case retrying
    case awaitingAcceptance(DaemonTransportCandidateID)
    case connected(DaemonTransportCandidateID)
    case stopped
}

public enum DaemonTransportEvent: Sendable, Equatable {
    case reconnecting
    case awaitingAcceptance(DaemonTransportCandidateID)
    case connected(DaemonTransportCandidateID)
    case disconnected(DaemonTransportCandidateID?)
    case interrupted(DaemonTransportCandidateID)
    case candidateRejected(DaemonTransportCandidateID)
    case acceptanceExpired(DaemonTransportCandidateID)
    case stopped
}

public enum DaemonTransportAcceptanceOutcome: Sendable, Equatable {
    case connected
    case retry
    case localFallbackReady
}

public struct DaemonTransportAcceptance: Sendable, Equatable {
    public let candidateID: DaemonTransportCandidateID
    public let outcome: DaemonTransportAcceptanceOutcome

    public init(candidateID: DaemonTransportCandidateID, outcome: DaemonTransportAcceptanceOutcome) {
        self.candidateID = candidateID
        self.outcome = outcome
    }
}

public struct DaemonTransportConfiguration: Sendable, Equatable {
    public var retryInterval: Duration
    public var healthCheckInterval: Duration
    public var healthCheckTimeout: TimeInterval
    public var acceptanceDeadline: Duration

    public init(
        retryInterval: Duration = .seconds(30),
        healthCheckInterval: Duration = .seconds(30),
        healthCheckTimeout: TimeInterval = 5,
        acceptanceDeadline: Duration = .seconds(30)
    ) {
        self.retryInterval = retryInterval
        self.healthCheckInterval = healthCheckInterval
        self.healthCheckTimeout = healthCheckTimeout
        self.acceptanceDeadline = acceptanceDeadline
    }
}

public struct DaemonTransportServices: Sendable {
    private let start: @Sendable () async -> Void
    private let acknowledgeCandidate: @Sendable (DaemonTransportAcceptance) async -> Void
    private let reconnect: @Sendable () async -> Void
    private let subscribe: @Sendable () async -> AsyncStream<DaemonTransportEvent>
    private let readAvailability: @Sendable () async -> DaemonTransportAvailability
    private let stopRuntime: @Sendable () async -> Void

    public init(
        startAdmission: @escaping @Sendable () async -> Void,
        acknowledge: @escaping @Sendable (DaemonTransportAcceptance) async -> Void,
        requestManualReconnect: @escaping @Sendable () async -> Void,
        events: @escaping @Sendable () async -> AsyncStream<DaemonTransportEvent>,
        availability: @escaping @Sendable () async -> DaemonTransportAvailability,
        stop: @escaping @Sendable () async -> Void
    ) {
        start = startAdmission
        acknowledgeCandidate = acknowledge
        reconnect = requestManualReconnect
        subscribe = events
        readAvailability = availability
        stopRuntime = stop
    }

    internal init(runtime: DaemonTransportRuntime) {
        self.init(
            startAdmission: { await runtime.startAdmission() },
            acknowledge: { await runtime.acknowledge($0) },
            requestManualReconnect: { await runtime.requestManualReconnect() },
            events: { await runtime.events() },
            availability: { await runtime.availability },
            stop: { await runtime.stop() })
    }

    public func startAdmission() async { await start() }
    public func acknowledge(_ acceptance: DaemonTransportAcceptance) async {
        await acknowledgeCandidate(acceptance)
    }
    public func requestManualReconnect() async { await reconnect() }
    public func events() async -> AsyncStream<DaemonTransportEvent> { await subscribe() }
    public func availability() async -> DaemonTransportAvailability { await readAvailability() }
    public func stop() async { await stopRuntime() }
}

public actor DaemonTransportRuntime {
    private enum State: Equatable {
        case idle
        case retrying
        case awaitingAcceptance(DaemonTransportCandidateID)
        case connected(DaemonTransportCandidateID)
        case stopped
    }

    private let factory: DaemonTransportConnectionFactory
    private let configuration: DaemonTransportConfiguration
    private var state: State = .idle
    private var candidate: (id: DaemonTransportCandidateID, connection: any DaemonTransportConnection)?
    private var invalidatedCandidateIDs: Set<DaemonTransportCandidateID> = []
    private var admissionTask: Task<Void, Never>?
    private var acceptanceTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<DaemonTransportEvent>.Continuation] = [:]

    public init(
        factory: DaemonTransportConnectionFactory,
        configuration: DaemonTransportConfiguration
    ) {
        self.factory = factory
        self.configuration = configuration
    }

    public var availability: DaemonTransportAvailability {
        switch state {
        case .idle: .idle
        case .retrying: .retrying
        case .awaitingAcceptance(let id): .awaitingAcceptance(id)
        case .connected(let id): .connected(id)
        case .stopped: .stopped
        }
    }

    public func events() -> AsyncStream<DaemonTransportEvent> {
        let subscriptionID = UUID()
        let pair = AsyncStream<DaemonTransportEvent>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriptionID) }
        }
        subscribers[subscriptionID] = pair.continuation
        return pair.stream
    }

    public func startAdmission() {
        guard state == .idle else { return }
        beginRetrying(invalidateCurrent: false, publishDisconnect: false)
    }

    public func acknowledge(_ acceptance: DaemonTransportAcceptance) {
        guard case .awaitingAcceptance(let expectedID) = state,
              expectedID == acceptance.candidateID,
              candidate?.id == expectedID else {
            DebugLog.store("Daemon transport ignored stale or duplicate acknowledgement for \(acceptance.candidateID)")
            return
        }

        acceptanceTask?.cancel()
        acceptanceTask = nil
        switch acceptance.outcome {
        case .connected:
            state = .connected(expectedID)
            publish(.connected(expectedID))
            installConnectedHealthTask(id: expectedID)
        case .retry:
            invalidateCurrentCandidate()
            publish(.candidateRejected(expectedID))
            beginRetrying(invalidateCurrent: false, publishDisconnect: true)
        case .localFallbackReady:
            invalidateCurrentCandidate()
            stopInternal(publishStopped: true)
        }
    }

    public func requestManualReconnect() {
        guard state != .stopped else { return }
        let wasConnected: Bool
        if case .connected = state { wasConnected = true } else { wasConnected = false }
        beginRetrying(invalidateCurrent: true, publishDisconnect: wasConnected)
    }

    public func stop() {
        stopInternal(publishStopped: true)
    }

    private func beginRetrying(invalidateCurrent: Bool, publishDisconnect: Bool) {
        guard state != .stopped else { return }
        admissionTask?.cancel()
        acceptanceTask?.cancel()
        healthTask?.cancel()
        admissionTask = nil
        acceptanceTask = nil
        healthTask = nil
        let disconnectedID = candidate?.id
        if invalidateCurrent { invalidateCurrentCandidate() }
        state = .retrying
        if publishDisconnect { publish(.disconnected(disconnectedID)) }
        publish(.reconnecting)
        admissionTask = Task { [weak self] in
            await self?.runAdmissionLoop()
        }
    }

    private func runAdmissionLoop() async {
        while !Task.isCancelled, state == .retrying {
            let id = DaemonTransportCandidateID()
            do {
                let connection = try await factory.makeCandidate(id: id)
                guard !Task.isCancelled, state == .retrying else {
                    connection.invalidate()
                    return
                }
                candidate = (id, connection)
                installLifecycleHandlers(connection: connection, id: id)
                let healthy = await connection.healthCheck(timeout: configuration.healthCheckTimeout)
                guard !Task.isCancelled, state == .retrying, candidate?.id == id else {
                    invalidate(connection: connection, id: id)
                    return
                }
                guard healthy else {
                    invalidateCurrentCandidate()
                    try await sleepBeforeRetry()
                    continue
                }
                admissionTask = nil
                state = .awaitingAcceptance(id)
                publish(.awaitingAcceptance(id))
                installAcceptanceDeadline(id: id)
                return
            } catch is CancellationError {
                return
            } catch {
                DebugLog.store("Daemon transport candidate creation failed: \(error)")
                do {
                    try await sleepBeforeRetry()
                } catch {
                    return
                }
            }
        }
    }

    private func sleepBeforeRetry() async throws {
        try await Task.sleep(for: configuration.retryInterval)
    }

    private func installAcceptanceDeadline(id: DaemonTransportCandidateID) {
        acceptanceTask?.cancel()
        let deadline = configuration.acceptanceDeadline
        acceptanceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: deadline)
                await self?.acceptanceExpired(id: id)
            } catch is CancellationError {
                return
            } catch {
                DebugLog.store("Daemon transport acceptance deadline failed unexpectedly: \(error)")
            }
        }
    }

    private func acceptanceExpired(id: DaemonTransportCandidateID) {
        guard case .awaitingAcceptance(id) = state, candidate?.id == id else { return }
        acceptanceTask = nil
        invalidateCurrentCandidate()
        publish(.acceptanceExpired(id))
        beginRetrying(invalidateCurrent: false, publishDisconnect: true)
    }

    private func installLifecycleHandlers(
        connection: any DaemonTransportConnection,
        id: DaemonTransportCandidateID
    ) {
        connection.setInvalidationHandler { [weak self] in
            Task { await self?.connectionInvalidated(id: id) }
        }
        connection.setInterruptionHandler { [weak self] in
            Task { await self?.connectionInterrupted(id: id) }
        }
    }

    private func connectionInvalidated(id: DaemonTransportCandidateID) {
        guard candidate?.id == id else { return }
        switch state {
        case .awaitingAcceptance(id), .connected(id):
            invalidatedCandidateIDs.insert(id)
            candidate = nil
            beginRetrying(invalidateCurrent: false, publishDisconnect: true)
        default:
            break
        }
    }

    private func connectionInterrupted(id: DaemonTransportCandidateID) {
        guard case .connected(id) = state, candidate?.id == id else { return }
        publish(.interrupted(id))
    }

    private func installConnectedHealthTask(id: DaemonTransportCandidateID) {
        healthTask?.cancel()
        let interval = configuration.healthCheckInterval
        let timeout = configuration.healthCheckTimeout
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                let shouldContinue = await self.probeConnectedCandidate(id: id, timeout: timeout)
                if !shouldContinue { return }
            }
        }
    }

    private func probeConnectedCandidate(id: DaemonTransportCandidateID, timeout: TimeInterval) async -> Bool {
        guard case .connected(id) = state,
              let current = candidate,
              current.id == id else { return false }
        let healthy = await current.connection.healthCheck(timeout: timeout)
        guard case .connected(id) = state, candidate?.id == id else { return false }
        if !healthy {
            beginRetrying(invalidateCurrent: true, publishDisconnect: true)
            return false
        }
        return true
    }

    private func invalidateCurrentCandidate() {
        guard let current = candidate else { return }
        candidate = nil
        invalidate(connection: current.connection, id: current.id)
    }

    private func invalidate(
        connection: any DaemonTransportConnection,
        id: DaemonTransportCandidateID
    ) {
        guard invalidatedCandidateIDs.insert(id).inserted else { return }
        connection.invalidate()
    }

    private func stopInternal(publishStopped: Bool) {
        guard state != .stopped else { return }
        state = .stopped
        admissionTask?.cancel()
        acceptanceTask?.cancel()
        healthTask?.cancel()
        admissionTask = nil
        acceptanceTask = nil
        healthTask = nil
        invalidateCurrentCandidate()
        if publishStopped { publish(.stopped) }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func publish(_ event: DaemonTransportEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
#endif
