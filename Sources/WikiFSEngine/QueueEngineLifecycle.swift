import Foundation
import Synchronization
import WikiFSCore

public enum QueueEngineLifecycle: Equatable, Sendable {
    case created
    case starting
    case running
    case shuttingDown
    case shutdownBlocked(activeItemIDs: Set<QueueItem.ID>)
    case shutDown
}

public enum QueueEngineLifecycleError: Error, Equatable, Sendable {
    case notStarted
    case shuttingDown
    case shutDown
    case shutdownBlocked(activeItemIDs: Set<QueueItem.ID>)
}

public struct QueueItemCompletionError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum QueueEngineShutdownResult: Equatable, Sendable {
    case shutDown
    case shutdownBlocked(activeItemIDs: Set<QueueItem.ID>)
}

public struct QueueEngineShutdownPolicy: Sendable {
    public var workerSettlementDeadline: Duration

    public init(workerSettlementDeadline: Duration = .seconds(10)) {
        self.workerSettlementDeadline = workerSettlementDeadline
    }
}

internal enum QueueShutdownRaceOutcome: Sendable {
    case drained
    case deadline
}

internal final class QueueShutdownSettlementSignal: Sendable {
    private struct State: Sendable {
        var completed = false
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = Mutex(State())

    func stream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            let completeNow = state.withLock { state -> Bool in
                if state.completed { return true }
                state.waiters[id] = continuation
                return false
            }
            continuation.onTermination = { [self] _ in
                state.withLock { _ = $0.waiters.removeValue(forKey: id) }
            }
            if completeNow { continuation.finish() }
        }
    }

    func complete() {
        let waiters = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            guard !state.completed else { return [] }
            state.completed = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.finish() }
    }
}

public protocol QueueEngineDeadlineSource: Sendable {
    func stream(after duration: Duration) -> AsyncStream<Void>
}

public struct ContinuousQueueEngineDeadlineSource: QueueEngineDeadlineSource {
    public init() {}

    public func stream(after duration: Duration) -> AsyncStream<Void> {
        let pair = AsyncStream<Void>.makeStream()
        let task = Task {
            do {
                try await ContinuousClock().sleep(for: duration)
                guard !Task.isCancelled else {
                    pair.continuation.finish()
                    return
                }
                pair.continuation.yield(())
                pair.continuation.finish()
            } catch is CancellationError {
                pair.continuation.finish()
            } catch {
                DebugLog.store("QueueEngine deadline source failed: \(error)")
                pair.continuation.finish()
            }
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
}
