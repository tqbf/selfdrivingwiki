#if os(macOS)
import Darwin
import Dispatch
import Foundation
import WikiFSCore

// `lock` protects `task` and `signalSources`. The remaining stored values are
// immutable Sendable closures or values.
// swiftlint:disable:next unchecked_sendable
final class DaemonProcessLifetimeCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let shutdown: @Sendable () async -> Void
    private let policy: GracefulShutdownPolicy
    private let didShutdown: @Sendable () -> Void
    private var task: Task<Void, Never>?
    private var signalSources: [DispatchSourceSignal] = []

    init(
        shutdown: @escaping @Sendable () async -> Void,
        policy: GracefulShutdownPolicy = .production(),
        didShutdown: @escaping @Sendable () -> Void
    ) {
        self.shutdown = shutdown
        self.policy = policy
        self.didShutdown = didShutdown
    }

    func installSignalHandlers() {
        lock.lock()
        defer { lock.unlock() }
        guard signalSources.isEmpty else { return }

        for signalNumber in [SIGTERM, SIGINT] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                self?.requestShutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func requestShutdown() {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            return
        }
        let shutdown = shutdown
        let policy = policy
        let didShutdown = didShutdown
        task = Task {
            let outcome = await policy.run(operation: shutdown)
            if outcome == .timedOut {
                DebugLog.extraction(
                    "Daemon shutdown exceeded the \(policy.timeoutDescription) timeout")
            }
            didShutdown()
        }
        lock.unlock()
    }

    func awaitShutdown() async {
        let shutdownTask: Task<Void, Never>? = lock.withLock { self.task }
        await shutdownTask?.value
    }
}
#endif
