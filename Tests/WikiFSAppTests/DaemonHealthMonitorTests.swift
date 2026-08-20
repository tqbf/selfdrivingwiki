#if os(macOS)
import Foundation
import Testing
@testable import WikiCtlCore
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

@MainActor
@Suite("Daemon health monitor adapter", .serialized, .timeLimit(.minutes(1)))
struct DaemonHealthMonitorAdapterTests {
    @Test func initialStateIsDisconnected() {
        let monitor = DaemonHealthMonitor(services: ServiceRecorder().services)
        #expect(monitor.state == .disconnected)
        #expect(!monitor.isMonitoring)
    }

    @Test func connectedReconnectingAndDisconnectedEventsMapDeterministically() {
        let monitor = DaemonHealthMonitor(services: ServiceRecorder().services)
        let id = DaemonTransportCandidateID()
        monitor.start()
        monitor.consume(.reconnecting)
        #expect(monitor.state == .reconnecting)
        monitor.consume(.awaitingAcceptance(id))
        #expect(monitor.state == .reconnecting)
        monitor.consume(.connected(id))
        #expect(monitor.state == .connected)
        monitor.consume(.disconnected(id))
        #expect(monitor.state == .disconnected)
    }

    @Test func forceReconnectForwardsWithoutDuplicateDisconnect() async {
        let recorder = ServiceRecorder()
        let monitor = DaemonHealthMonitor(services: recorder.services)
        monitor.start()
        monitor.consume(.disconnected(nil))
        await monitor.forceReconnect()
        await monitor.forceReconnect()
        #expect(await recorder.reconnectCount == 2)
        #expect(monitor.state == .disconnected)
    }

    @Test func interruptionDoesNotFlapConnectedPresentation() {
        let monitor = DaemonHealthMonitor(services: ServiceRecorder().services)
        let id = DaemonTransportCandidateID()
        monitor.start()
        monitor.consume(.connected(id))
        monitor.consume(.interrupted(id))
        #expect(monitor.state == .connected)
    }

    @Test func stopPreventsLaterEventUpdates() {
        let monitor = DaemonHealthMonitor(services: ServiceRecorder().services)
        monitor.start()
        monitor.consume(.connected(DaemonTransportCandidateID()))
        monitor.stop()
        monitor.consume(.reconnecting)
        #expect(monitor.state == .connected)
        #expect(!monitor.isMonitoring)
    }

    @Test func stoppedEventLeavesFinalDisconnectedState() {
        let monitor = DaemonHealthMonitor(services: ServiceRecorder().services)
        monitor.start()
        monitor.consume(.connected(DaemonTransportCandidateID()))
        monitor.consume(.stopped)
        #expect(monitor.state == .disconnected)
        #expect(!monitor.isMonitoring)
    }
}

private actor ServiceRecorder {
    private(set) var reconnectCount = 0

    nonisolated var services: DaemonTransportServices {
        DaemonTransportServices(
            startAdmission: {},
            acknowledge: { _ in },
            requestManualReconnect: { [weak self] in await self?.recordReconnect() },
            events: { AsyncStream { $0.finish() } },
            availability: { .idle },
            stop: {})
    }

    private func recordReconnect() { reconnectCount += 1 }
}

/// Characterization tests for the unchanged low-level XPC health boundary.
struct WikiDaemonConnectionHealthTests {
    @Test func healthCheckReturnsFalseForInvalidatedConnection() async throws {
        let connection = try #require(try? WikiDaemonConnection.connect())
        connection.invalidate()
        #expect(await connection.healthCheck(timeout: 2) == false)
    }

    @Test func daemonProxyReturnsProxyOnFreshConnection() throws {
        let connection = try #require(try? WikiDaemonConnection.connect())
        _ = try connection.daemonProxy()
        connection.invalidate()
    }

    @Test func daemonProxyUsesGuardLetNotForceCast() throws {
        let connection = try #require(try? WikiDaemonConnection.connect())
        do { _ = try connection.daemonProxy() }
        catch { #expect(error is WikiDaemonError) }
        connection.invalidate()
    }

    @Test func setInvalidationHandlerIsCallable() throws {
        let connection = try #require(try? WikiDaemonConnection.connect())
        connection.setInvalidationHandler {}
        connection.invalidate()
    }

    @Test func healthCheckTimeoutParameterIsRespected() async throws {
        let connection = try #require(try? WikiDaemonConnection.connect())
        let start = Date()
        _ = await connection.healthCheck(timeout: 1)
        #expect(Date().timeIntervalSince(start) < 30)
    }

    @Test func serviceNameMatchesXPCBundleIdentifier() {
        #expect(WikiDaemonConnection.serviceName == WikiIdentifiers.daemonServiceID)
        #expect(!WikiDaemonConnection.serviceName.isEmpty)
        #expect(WikiDaemonConnection.serviceName.contains("."))
    }

    @Test func daemonServiceIDDefaultsToAppBundleIDSuffix() {
        let config = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("signing/local.config"),
            encoding: .utf8)
        if config?.contains("DAEMON_BUNDLE_ID=") != true {
            #expect(WikiIdentifiers.daemonServiceID.hasSuffix(".wikid"))
        }
    }
}
#endif
