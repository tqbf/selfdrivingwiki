#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

protocol LocalQueueRuntimeHandle: Sendable {
    var client: any QueueEngineClient { get }
    func dispose() async throws -> QueueEngineShutdownResult
}

extension QueueRuntimeHandle: LocalQueueRuntimeHandle {}

@MainActor
@Observable
final class LocalQueueRuntimeController {
    typealias LocalAssembly = @Sendable () async throws -> any LocalQueueRuntimeHandle

    struct DaemonEndpoint: Sendable {
        let client: any QueueEngineClient
        let epoch: QueueOwnershipEpoch

        init(client: any QueueEngineClient, epoch: QueueOwnershipEpoch) {
            self.client = client
            self.epoch = epoch
        }
    }

    enum State: Sendable {
        case unavailable(reason: String)
        case startingLocal
        case localReady
        case shuttingDownForDaemon
        case shutdownBlocked(activeItemIDs: Set<QueueItem.ID>)
        case daemonActive(epoch: QueueOwnershipEpoch)
        case daemonOwnershipUnresolved(expectedEpoch: QueueOwnershipEpoch, reason: String)
        case fallingBack(expectedEpoch: QueueOwnershipEpoch)
        case disposing

        var name: String {
            switch self {
            case .unavailable: "unavailable"
            case .startingLocal: "startingLocal"
            case .localReady: "localReady"
            case .shuttingDownForDaemon: "shuttingDownForDaemon"
            case .shutdownBlocked: "shutdownBlocked"
            case .daemonActive: "daemonActive"
            case .daemonOwnershipUnresolved: "daemonOwnershipUnresolved"
            case .fallingBack: "fallingBack"
            case .disposing: "disposing"
            }
        }
    }

    private enum Reason {
        static let startup = "The local queue is starting."
        static let daemonTakeover = "The local queue is shutting down for daemon takeover."
        static let localShutdownBlocked = "Local queue shutdown is blocked by active workers."
        static let daemonOwnershipUnresolved = "Daemon queue ownership is unresolved."
        static let disposal = "The queue runtime is shutting down."
    }

    let client: QueueEngineHotSwap
    private(set) var state: State
    private(set) var localHandle: (any LocalQueueRuntimeHandle)?
    private(set) var startupError: String?

    private let assembleLocal: LocalAssembly
    private var generation: UInt64 = 0
    private var activeTransition: UInt64?
    private var ownedTask: Task<Void, Never>?

    init(assembleLocal: @escaping LocalAssembly) {
        self.assembleLocal = assembleLocal
        let unavailable = UnavailableQueueEngine(reason: Reason.startup)
        self.client = QueueEngineHotSwap(unavailable)
        self.state = .unavailable(reason: Reason.startup)
    }

    func dismissStartupError() {
        startupError = nil
    }

    func start() {
        guard ownedTask == nil, activeTransition == nil,
              case .unavailable = state else { return }
        let transition = nextGeneration()
        state = .startingLocal
        ownedTask = Task { @MainActor [weak self] in
            await self?.runLocalStartup(transition: transition)
        }
    }

    func awaitSettled() async {
        let task = ownedTask
        await task?.value
    }

    func activateDaemon(_ endpoint: DaemonEndpoint) async -> Bool {
        guard case .shutdownBlocked = state else {
            guard let transition = beginTransition() else { return false }
            defer { endTransition(transition) }
            await cancelOwnedTask(advanceGeneration: false)
            guard case .shutdownBlocked = state else {
                return await runDaemonActivation(endpoint, transition: transition)
            }
            return false
        }
        return false
    }

    func daemonOwnershipBecameUnresolved(
        expectedEpoch: QueueOwnershipEpoch,
        reason: String
    ) async {
        guard case .daemonActive(let activeEpoch) = state,
              activeEpoch == expectedEpoch else { return }
        guard let transition = beginTransition() else { return }
        defer { endTransition(transition) }
        state = .daemonOwnershipUnresolved(expectedEpoch: expectedEpoch, reason: reason)
        await client.swap(to: UnavailableQueueEngine(reason: Reason.daemonOwnershipUnresolved))
    }

    func fallBackAfterRelinquishment(
        _ success: QueueRelinquishmentSuccess,
        expectedEpoch: QueueOwnershipEpoch
    ) async -> Bool {
        guard ownedTask == nil else { return false }
        guard case .daemonOwnershipUnresolved(let unresolvedEpoch, _) = state,
              unresolvedEpoch == expectedEpoch,
              success.completedEpoch == expectedEpoch,
              success.isComplete else {
            return false
        }
        guard let transition = beginTransition() else { return false }
        defer { endTransition(transition) }

        state = .fallingBack(expectedEpoch: expectedEpoch)
        do {
            let handle = try await assembleLocal()
            guard transition == generation else {
                await retireStaleHandle(handle)
                return false
            }
            localHandle = handle
            await client.swap(to: handle.client)
            guard transition == generation else { return false }
            state = .localReady
            startupError = nil
            return true
        } catch {
            guard transition == generation else { return false }
            let reason = String(describing: error)
            startupError = reason
            state = .unavailable(reason: reason)
            await client.swap(to: UnavailableQueueEngine(reason: reason))
            return false
        }
    }

    func replaceUnresolvedDaemon(
        _ endpoint: DaemonEndpoint,
        expectedEpoch: QueueOwnershipEpoch
    ) async -> Bool {
        guard case .daemonOwnershipUnresolved(let unresolvedEpoch, _) = state,
              unresolvedEpoch == expectedEpoch,
              endpoint.epoch != expectedEpoch,
              localHandle == nil,
              ownedTask == nil else {
            return false
        }
        guard let transition = beginTransition() else { return false }
        defer { endTransition(transition) }
        return await runDaemonActivation(endpoint, transition: transition)
    }

    func retryBlockedShutdownForDaemon(_ endpoint: DaemonEndpoint) async -> Bool {
        guard case .shutdownBlocked = state, localHandle != nil, ownedTask == nil else {
            return false
        }
        guard let transition = beginTransition() else { return false }
        defer { endTransition(transition) }
        return await runDaemonActivation(endpoint, transition: transition)
    }

    func dispose() async -> QueueEngineShutdownResult? {
        guard let transition = beginTransition() else { return nil }
        defer { endTransition(transition) }
        await cancelOwnedTask(advanceGeneration: false)

        state = .disposing
        await client.swap(to: UnavailableQueueEngine(reason: Reason.disposal))
        guard transition == generation else { return nil }
        guard let handle = localHandle else { return .shutDown }

        do {
            let result = try await handle.dispose()
            guard transition == generation else { return result }
            switch result {
            case .shutDown:
                localHandle = nil
                state = .unavailable(reason: Reason.disposal)
            case .shutdownBlocked(let activeItemIDs):
                state = .shutdownBlocked(activeItemIDs: activeItemIDs)
            }
            return result
        } catch {
            guard transition == generation else { return nil }
            let reason = String(describing: error)
            startupError = reason
            state = .unavailable(reason: reason)
            return nil
        }
    }

    private func runLocalStartup(transition: UInt64) async {
        defer {
            if transition == generation { ownedTask = nil }
        }
        do {
            let handle = try await assembleLocal()
            guard transition == generation else {
                await retireStaleHandle(handle)
                return
            }
            localHandle = handle
            await client.swap(to: handle.client)
            guard transition == generation else { return }
            state = .localReady
            startupError = nil
        } catch {
            guard transition == generation else { return }
            let reason = String(describing: error)
            startupError = reason
            state = .unavailable(reason: reason)
            await client.swap(to: UnavailableQueueEngine(reason: reason))
        }
    }

    private func runDaemonActivation(
        _ endpoint: DaemonEndpoint,
        transition: UInt64
    ) async -> Bool {
        state = .shuttingDownForDaemon
        await client.swap(to: UnavailableQueueEngine(reason: Reason.daemonTakeover))
        guard transition == generation else { return false }

        if let handle = localHandle {
            do {
                let result = try await handle.dispose()
                guard transition == generation else { return false }
                switch result {
                case .shutDown:
                    localHandle = nil
                case .shutdownBlocked(let activeItemIDs):
                    state = .shutdownBlocked(activeItemIDs: activeItemIDs)
                    await client.swap(to: UnavailableQueueEngine(reason: Reason.localShutdownBlocked))
                    return false
                }
            } catch {
                guard transition == generation else { return false }
                let reason = String(describing: error)
                startupError = reason
                state = .unavailable(reason: reason)
                await client.swap(to: UnavailableQueueEngine(reason: reason))
                return false
            }
        }

        await client.swap(to: endpoint.client)
        guard transition == generation else { return false }
        state = .daemonActive(epoch: endpoint.epoch)
        return true
    }

    private func cancelOwnedTask(advanceGeneration: Bool = true) async {
        if advanceGeneration { _ = nextGeneration() }
        let task = ownedTask
        ownedTask = nil
        task?.cancel()
        await task?.value
    }

    private func retireStaleHandle(_ handle: any LocalQueueRuntimeHandle) async {
        do {
            let result = try await handle.dispose()
            if case .shutdownBlocked(let activeItemIDs) = result {
                localHandle = handle
                state = .shutdownBlocked(activeItemIDs: activeItemIDs)
            }
        } catch {
            localHandle = handle
            startupError = String(describing: error)
            DebugLog.store("LocalQueueRuntimeController: stale runtime cleanup failed: \(error)")
        }
    }

    private func beginTransition() -> UInt64? {
        guard activeTransition == nil else { return nil }
        let transition = nextGeneration()
        activeTransition = transition
        return transition
    }

    private func endTransition(_ transition: UInt64) {
        guard activeTransition == transition else { return }
        activeTransition = nil
    }

    @discardableResult
    private func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }
}
#endif
