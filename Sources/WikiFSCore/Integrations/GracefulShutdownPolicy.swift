import Foundation

public struct GracefulShutdownPolicy: Sendable {
    public static let environmentKey = "WIKIFS_GRACEFUL_SHUTDOWN_TIMEOUT_SECONDS"
    public static let defaultTimeoutSeconds: Int = 30

    public enum Outcome: Equatable, Sendable {
        case completed
        case timedOut
    }

    public let timeout: Duration
    public let timeoutDescription: String

    public init(timeout: Duration, timeoutDescription: String) {
        self.timeout = timeout
        self.timeoutDescription = timeoutDescription
    }

    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let seconds = environment[environmentKey]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? defaultTimeoutSeconds
        return Self(
            timeout: .seconds(seconds),
            timeoutDescription: "\(seconds)-second")
    }

    public func run(
        operation: @escaping @Sendable () async -> Void
    ) async -> Outcome {
        let pair = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let operationTask = Task {
            await operation()
            pair.continuation.yield(.completed)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                pair.continuation.yield(.timedOut)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }

        let outcome = await pair.stream.first(where: { _ in true }) ?? .timedOut
        operationTask.cancel()
        timeoutTask.cancel()
        pair.continuation.finish()
        return outcome
    }
}
