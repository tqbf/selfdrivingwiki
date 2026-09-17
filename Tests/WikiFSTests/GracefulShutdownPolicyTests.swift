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

    @Test("deadline cancels cleanup and returns timeout", .disabled("Load-flaky on CI runners: the cancellation flag can miss even the load-scaled 2s poll (Actions runs 35271670359, 35278627827); re-enable with a deterministic signal"))
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
        // `run` returns the moment the deadline fires, and cancels the body
        // task afterwards. On a loaded runner the body task may not have
        // STARTED by then — a pre-cancelled task fires its cancellation
        // handler only at registration time, i.e. after `run` returned — so
        // asserting the flag synchronously races the scheduler. Poll for the
        // flag with a load-scaled deadline instead (see `TestTimingScale`).
        let deadline = ContinuousClock.now
            .advanced(by: .milliseconds(TestTimingScale.milliseconds(2000)))
        while ContinuousClock.now < deadline, cancelled.withLock({ $0 }) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(cancelled.withLock { $0 })
    }
}
