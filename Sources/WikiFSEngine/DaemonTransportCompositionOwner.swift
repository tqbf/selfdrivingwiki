#if os(macOS)
// pattern: Imperative Shell

import Foundation
import WikiFSCore

public protocol DaemonTransportRuntimeOwning: Sendable {
    var services: DaemonTransportServices { get }
    func dispose() async throws
}

extension DaemonTransportRuntimeHandle: DaemonTransportRuntimeOwning {}

private actor MutableDaemonTransportServices {
    nonisolated let facade: DaemonTransportServices

    private let relay: DaemonTransportServiceRelay
    private var installed: DaemonTransportServices?
    private var startRequested = false
    private var stopped = false
    private var subscribers: [UUID: AsyncStream<DaemonTransportEvent>.Continuation] = [:]
    private var forwardingTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        let relay = DaemonTransportServiceRelay()
        self.relay = relay
        facade = relay.facade
        relay.bind(self)
    }

    func install(_ services: DaemonTransportServices) async {
        guard !stopped else {
            await services.stop()
            return
        }
        installed = services
        for id in subscribers.keys { startForwarding(id: id, services: services) }
        if startRequested { await services.startAdmission() }
    }

    func startAdmission() async {
        guard !stopped else { return }
        startRequested = true
        if let installed { await installed.startAdmission() }
    }

    func acknowledge(_ acceptance: DaemonTransportAcceptance) async {
        guard !stopped, let installed else {
            DebugLog.store("Daemon transport acknowledgement arrived while services were unavailable")
            return
        }
        await installed.acknowledge(acceptance)
    }

    func requestManualReconnect() async {
        guard !stopped, let installed else { return }
        await installed.requestManualReconnect()
    }

    func events() -> AsyncStream<DaemonTransportEvent> {
        let id = UUID()
        let pair = AsyncStream<DaemonTransportEvent>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = pair.continuation
        if let installed { startForwarding(id: id, services: installed) }
        return pair.stream
    }

    func availability() async -> DaemonTransportAvailability {
        guard !stopped else { return .stopped }
        guard let installed else { return .idle }
        return await installed.availability()
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        startRequested = false
        if let installed { await installed.stop() }
        self.installed = nil
        finishSubscribers()
    }

    private func startForwarding(id: UUID, services: DaemonTransportServices) {
        guard forwardingTasks[id] == nil, subscribers[id] != nil else { return }
        forwardingTasks[id] = Task { [weak self] in
            let stream = await services.events()
            for await event in stream {
                guard let self else { return }
                await self.forward(event, to: id)
            }
        }
    }

    private func forward(_ event: DaemonTransportEvent, to id: UUID) {
        subscribers[id]?.yield(event)
        if event == .stopped { removeSubscriber(id) }
    }

    private func removeSubscriber(_ id: UUID) {
        forwardingTasks.removeValue(forKey: id)?.cancel()
        subscribers.removeValue(forKey: id)?.finish()
    }

    private func finishSubscribers() {
        for task in forwardingTasks.values { task.cancel() }
        forwardingTasks.removeAll()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
}

// `lock` protects the relay's only mutable field (`target`) on every read and write.
// swiftlint:disable:next unchecked_sendable
private final class DaemonTransportServiceRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: MutableDaemonTransportServices?

    lazy var facade = DaemonTransportServices(
        startAdmission: { [weak self] in await self?.readTarget()?.startAdmission() },
        acknowledge: { [weak self] in await self?.readTarget()?.acknowledge($0) },
        requestManualReconnect: { [weak self] in await self?.readTarget()?.requestManualReconnect() },
        events: { [weak self] in
            guard let target = self?.readTarget() else { return AsyncStream { $0.finish() } }
            return await target.events()
        },
        availability: { [weak self] in
            guard let target = self?.readTarget() else { return .stopped }
            return await target.availability()
        },
        stop: { [weak self] in await self?.readTarget()?.stop() })

    func bind(_ target: MutableDaemonTransportServices) {
        lock.lock()
        self.target = target
        lock.unlock()
    }

    private func readTarget() -> MutableDaemonTransportServices? {
        lock.lock()
        let value = target
        lock.unlock()
        return value
    }
}

public actor DaemonTransportCompositionOwner {
    public typealias AssemblyFactory = @Sendable () async throws -> any DaemonTransportRuntimeOwning

    public nonisolated let services: DaemonTransportServices

    private enum State {
        case idle
        case starting(Task<Void, Never>)
        case installed(any DaemonTransportRuntimeOwning)
        case stopped
    }

    private let mutableServices: MutableDaemonTransportServices
    private let assemble: AssemblyFactory
    private let retryInterval: Duration
    private var state: State = .idle

    public init(
        retryInterval: Duration = .seconds(1),
        assemble: @escaping AssemblyFactory
    ) {
        let mutableServices = MutableDaemonTransportServices()
        self.mutableServices = mutableServices
        services = mutableServices.facade
        self.assemble = assemble
        self.retryInterval = retryInterval
    }

    public func start() {
        guard case .idle = state else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStartup()
        }
        state = .starting(task)
    }

    public func awaitSettled() async {
        guard case .starting(let task) = state else { return }
        await task.value
    }

    public func shutdown() async {
        await mutableServices.stop()
        switch state {
        case .idle:
            state = .stopped
        case .starting(let task):
            state = .stopped
            task.cancel()
            await task.value
        case .installed(let handle):
            state = .stopped
            do { try await handle.dispose() }
            catch { DebugLog.store("Daemon transport shutdown failed: \(error)") }
        case .stopped:
            return
        }
    }

    private func runStartup() async {
        while !Task.isCancelled {
            do {
                let handle = try await assemble()
                guard case .starting = state, !Task.isCancelled else {
                    try await handle.dispose()
                    return
                }
                await mutableServices.install(handle.services)
                guard case .starting = state, !Task.isCancelled else {
                    try await handle.dispose()
                    return
                }
                state = .installed(handle)
                return
            } catch is CancellationError {
                return
            } catch {
                guard case .starting = state else { return }
                DebugLog.store(
                    "Daemon transport assembly failed; retrying in \(retryInterval): \(error)")
                do {
                    try await Task.sleep(for: retryInterval)
                } catch is CancellationError {
                    return
                } catch {
                    DebugLog.store("Daemon transport assembly retry delay failed: \(error)")
                    return
                }
            }
        }
    }
}
#endif
