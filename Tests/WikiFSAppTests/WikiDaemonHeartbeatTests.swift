#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import wikid

/// Tests for the `WikiDaemon` liveness heartbeat (#878 BLOCKER 1.2).
struct WikiDaemonHeartbeatTests {

    private func tempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-heartbeat-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func emitHeartbeatDoesNotCrash() async {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)
        // Should complete without crashing, even with no queue engine.
        await daemon.emitHeartbeat()
    }

    @Test func emitHeartbeatWithQueueEngine() async throws {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)

        // Ensure the queue engine exists (the heartbeat reads its snapshot).
        #if canImport(WikiFSEngine)
        _ = try await daemon.ensureQueueEngine()
        #endif

        // Should complete without crashing.
        await daemon.emitHeartbeat()
    }

    @Test func startHeartbeatIsIdempotent() {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)

        daemon.heartbeatInterval = .milliseconds(10)
        daemon.startHeartbeat()
        daemon.startHeartbeat()  // second call should cancel + restart
        daemon.stopHeartbeat()
    }

    @Test func stopHeartbeatCancelsTask() async {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)

        daemon.heartbeatInterval = .milliseconds(10)
        daemon.startHeartbeat()
        daemon.stopHeartbeat()

        // After stop, sleeping briefly should not produce any issue.
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func heartbeatIntervalDefaultsTo60Seconds() {
        let dir = tempDirectory()
        let daemon = WikiDaemon(containerDirectory: dir)
        #expect(daemon.heartbeatInterval == .seconds(60))
    }
}
#endif
