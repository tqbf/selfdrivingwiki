import Synchronization
import Testing
@testable import WikiFSCore

@Suite("Graceful shutdown policy", .serialized, .timeLimit(.minutes(1)))
struct GracefulShutdownPolicyTests {
    @Test("production policy uses the named default")
    func productionDefault() {
        let policy = GracefulShutdownPolicy.production(environment: [:])

        #expect(policy.timeout == .seconds(GracefulShutdownPolicy.defaultTimeoutSeconds))
        #expect(policy.timeoutDescription == "30-second")
    }

    @Test("production policy reads a positive environment override")
    func productionEnvironmentOverride() {
        let policy = GracefulShutdownPolicy.production(environment: [
            GracefulShutdownPolicy.environmentKey: "45"
        ])

        #expect(policy.timeout == .seconds(45))
        #expect(policy.timeoutDescription == "45-second")
    }

    @Test("completed operation wins before the deadline")
    func completedOperation() async {
        let policy = GracefulShutdownPolicy(
            timeout: .seconds(1),
            timeoutDescription: "test")

        let outcome = await policy.run {}

        #expect(outcome == .completed)
    }

    @Test("deadline cancels cleanup and returns timeout")
    func timeoutReturns() async {
        let cancelled = Mutex(false)
        let policy = GracefulShutdownPolicy(
            timeout: .milliseconds(1),
            timeoutDescription: "test")

        let outcome = await policy.run {
            await withTaskCancellationHandler {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }

        #expect(outcome == .timedOut)
        #expect(cancelled.withLock { $0 })
    }
}
