#if os(macOS) && canImport(WikiFSEngine)
import Foundation
import Synchronization
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

final class DaemonQueueHostBox: Sendable {
    private let storage = Mutex<DaemonQueueHost?>(nil)

    func getOrCreate(
        _ make: () -> DaemonQueueHost
    ) -> DaemonQueueHost {
        storage.withLock { host in
            if let host { return host }
            let created = make()
            host = created
            return created
        }
    }
}

struct DaemonQueueResources: Sendable {
    let engine: QueueEngine
    let store: QueueStore
    let forwardingTask: Task<Void, Never>
}

struct DaemonQueueOperationResult<Value: Sendable>: Sendable {
    let value: Value
    let epoch: QueueOwnershipEpoch
    let hostState: QueueDaemonHostState

    func map<Mapped: Sendable>(
        _ transform: (Value) throws -> Mapped
    ) rethrows -> DaemonQueueOperationResult<Mapped> {
        DaemonQueueOperationResult<Mapped>(
            value: try transform(value),
            epoch: epoch,
            hostState: hostState)
    }
}

actor DaemonQueueHost {
    private enum State: Sendable {
        case serving(QueueOwnershipEpoch)
        case relinquishing(QueueOwnershipEpoch)
        case relinquished(QueueOwnershipEpoch)
        case shutdownBlocked(QueueOwnershipEpoch, Set<QueueItem.ID>)

        var epoch: QueueOwnershipEpoch {
            switch self {
            case .serving(let epoch),
                 .relinquishing(let epoch),
                 .relinquished(let epoch),
                 .shutdownBlocked(let epoch, _):
                return epoch
            }
        }

        var wireState: QueueDaemonHostState {
            switch self {
            case .serving: .serving
            case .relinquishing: .relinquishing
            case .relinquished: .relinquished
            case .shutdownBlocked: .shutdownBlocked
            }
        }

        var activeItemIDs: [String] {
            guard case .shutdownBlocked(_, let itemIDs) = self else { return [] }
            return itemIDs.map(\.rawValue).sorted()
        }
    }

    private let build: @Sendable () async throws -> DaemonQueueResources
    private let onAdmission: (@Sendable () -> Void)?
    private let onStateChange: (@Sendable (QueueDaemonHostState) -> Void)?
    private var state: State
    private var resources: DaemonQueueResources?
    private var buildTask: Task<DaemonQueueResources, Error>?
    private var relinquishmentTask: Task<QueueRelinquishmentSuccess, Error>?
    private var admissionCount = 0
    private var admissionWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        initialEpoch: QueueOwnershipEpoch = QueueOwnershipEpoch(rawValue: 1),
        onAdmission: (@Sendable () -> Void)? = nil,
        onStateChange: (@Sendable (QueueDaemonHostState) -> Void)? = nil,
        build: @escaping @Sendable () async throws -> DaemonQueueResources
    ) {
        self.state = .serving(initialEpoch)
        self.onAdmission = onAdmission
        self.onStateChange = onStateChange
        self.build = build
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (QueueEngine) async throws -> Value
    ) async throws -> DaemonQueueOperationResult<Value> {
        guard case .serving(let admittedEpoch) = state else {
            throw ownershipError(for: state)
        }
        admissionCount += 1
        onAdmission?()

        do {
            let resources = try await ensureResourcesForAdmittedOperation()
            let value = try await operation(resources.engine)
            finishAdmission()
            return DaemonQueueOperationResult(
                value: value,
                epoch: admittedEpoch,
                hostState: .serving)
        } catch {
            finishAdmission()
            throw error
        }
    }

    func status() -> (epoch: QueueOwnershipEpoch, hostState: QueueDaemonHostState) {
        (state.epoch, state.wireState)
    }

    func relinquish(
        expectedEpoch: QueueOwnershipEpoch
    ) async throws -> QueueRelinquishmentSuccess {
        if case .relinquished(let completedEpoch) = state {
            guard completedEpoch == expectedEpoch else {
                throw staleEpochError(expected: expectedEpoch, actual: completedEpoch)
            }
            return completedSuccess(epoch: completedEpoch)
        }
        let currentEpoch = state.epoch
        guard currentEpoch == expectedEpoch else {
            throw staleEpochError(expected: expectedEpoch, actual: currentEpoch)
        }
        if let relinquishmentTask {
            return try await relinquishmentTask.value
        }
        switch state {
        case .serving, .shutdownBlocked:
            state = .relinquishing(currentEpoch)
            onStateChange?(.relinquishing)
        case .relinquishing:
            break
        case .relinquished:
            return completedSuccess(epoch: currentEpoch)
        }

        let task = Task<QueueRelinquishmentSuccess, Error> { [self] in
            try await performRelinquishment(epoch: currentEpoch)
        }
        relinquishmentTask = task
        return try await task.value
    }

    private func ensureResourcesForAdmittedOperation() async throws -> DaemonQueueResources {
        if let resources { return resources }
        if let buildTask {
            return try await buildTask.value
        }

        let task = Task<DaemonQueueResources, Error> { [build] in
            try await build()
        }
        buildTask = task
        do {
            let built = try await task.value
            resources = built
            buildTask = nil
            return built
        } catch {
            buildTask = nil
            throw error
        }
    }

    private func performRelinquishment(
        epoch: QueueOwnershipEpoch
    ) async throws -> QueueRelinquishmentSuccess {
        await waitForAdmissionsToDrain()

        guard let resources else {
            state = .relinquished(epoch)
            onStateChange?(.relinquished)
            relinquishmentTask = nil
            return completedSuccess(epoch: epoch)
        }

        switch await resources.engine.shutdownForHandoff() {
        case .shutDown:
            await resources.forwardingTask.value
            resources.store.close()
            self.resources = nil
            state = .relinquished(epoch)
            onStateChange?(.relinquished)
            relinquishmentTask = nil
            return completedSuccess(epoch: epoch)

        case .shutdownBlocked(let activeItemIDs):
            state = .shutdownBlocked(epoch, activeItemIDs)
            onStateChange?(.shutdownBlocked)
            relinquishmentTask = nil
            throw ownershipError(for: state)
        }
    }

    private func waitForAdmissionsToDrain() async {
        guard admissionCount > 0 else { return }
        let pair = AsyncStream<Void>.makeStream()
        let id = UUID()
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAdmissionWaiter(id) }
        }
        admissionWaiters[id] = pair.continuation
        for await _ in pair.stream { break }
    }

    private func finishAdmission() {
        precondition(admissionCount > 0)
        admissionCount -= 1
        guard admissionCount == 0 else { return }
        let waiters = Array(admissionWaiters.values)
        admissionWaiters.removeAll()
        for waiter in waiters {
            waiter.yield(())
            waiter.finish()
        }
    }

    private func removeAdmissionWaiter(_ id: UUID) {
        admissionWaiters.removeValue(forKey: id)
    }

    private func ownershipError(for state: State) -> QueueRPCError {
        let ownership = QueueOwnershipTransitionError(
            epoch: state.epoch,
            hostState: state.wireState,
            activeItemIDs: state.activeItemIDs)
        return QueueRPCError(
            code: .ownershipTransition,
            message: "Daemon queue ownership is \(state.wireState.rawValue)",
            ownership: ownership)
    }

    private func staleEpochError(
        expected: QueueOwnershipEpoch,
        actual: QueueOwnershipEpoch
    ) -> QueueRPCError {
        QueueRPCError(
            code: .ownershipTransition,
            message: "Queue ownership epoch mismatch: expected \(expected.rawValue), current \(actual.rawValue)",
            ownership: QueueOwnershipTransitionError(
                epoch: actual,
                hostState: state.wireState,
                activeItemIDs: state.activeItemIDs))
    }

    private func completedSuccess(
        epoch: QueueOwnershipEpoch
    ) -> QueueRelinquishmentSuccess {
        QueueRelinquishmentSuccess(
            completedEpoch: epoch,
            dispatchStopped: true,
            workersSettledOrRequeued: true,
            forwardingStopped: true,
            storeClosed: true)
    }
}
#endif
