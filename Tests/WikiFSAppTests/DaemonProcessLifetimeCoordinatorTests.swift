#if os(macOS)
import Synchronization
import Testing
@testable import WikiFSCore
@testable import wikid

@Suite("Daemon process lifetime coordinator", .serialized, .timeLimit(.minutes(1)))
struct DaemonProcessLifetimeCoordinatorTests {
    @Test("shutdown completes before process completion and runs once")
    func shutdownCompletesBeforeProcessCompletion() async {
        let events = Mutex<[String]>([])
        let coordinator = DaemonProcessLifetimeCoordinator(
            shutdown: {
                events.withLock { $0.append("shutdown") }
            },
            didShutdown: {
                events.withLock { $0.append("complete") }
            })

        coordinator.requestShutdown()
        coordinator.requestShutdown()
        await coordinator.awaitShutdown()

        #expect(events.withLock { $0 } == ["shutdown", "complete"])
    }

    @Test("timeout still completes process termination once")
    func timeoutCompletesTermination() async {
        let events = Mutex<[String]>([])
        let policy = GracefulShutdownPolicy(
            timeout: .milliseconds(1),
            timeoutDescription: "test")
        let coordinator = DaemonProcessLifetimeCoordinator(
            shutdown: {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    events.withLock { $0.append("cancelled") }
                }
            },
            policy: policy,
            didShutdown: {
                events.withLock { $0.append("complete") }
            })

        coordinator.requestShutdown()
        coordinator.requestShutdown()
        await coordinator.awaitShutdown()

        #expect(events.withLock { events in
            events.filter { $0 == "complete" }.count
        } == 1)
    }
}
#endif
