#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiCtlCore
@testable import wikid

/// Tests for the #878 daemon connection health check.
///
/// `NSXPCConnection` is lazy: `resume()` succeeds even when no daemon is
/// listening. Before #878, `WikiDaemonConnection.connect()` returned a
/// connection that *looked* healthy and the app logged "connected to wikid
/// daemon" while no daemon existed — every subsequent XPC call then failed or
/// hung. These tests pin the new behavior:
///
/// 1. `connect()` throws when pointed at a mach service nobody registered.
/// 2. `connect()` succeeds (health check passes) against a live in-process daemon,
///    and the returned connection is actually usable.
/// 3. The `invalidationHandler` installed by `connect()` fires when the
///    connection breaks, so a mid-session daemon death is observable/logged.
struct WikiDaemonConnectionHealthCheckTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikid-healthcheck-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds an anonymous in-process daemon listener (no launchd) and returns
    /// a handle exposing its endpoint. Caller owns invalidating the listener.
    ///
    /// `NSXPCListener.delegate` is a *weak* reference, so the handle retains the
    /// delegate privately — callers just need to keep the handle alive for the
    /// life of the test, or the listener will refuse every connection
    /// (error 4097) once the delegate is deallocated.
    private func makeDaemonEndpoint() -> DaemonListenerHandle {
        let daemon = WikiDaemon(containerDirectory: makeTempDir())
        let exporter = WikiDaemonExporter(daemon: daemon)
        let listener = NSXPCListener.anonymous()
        let delegate = HealthCheckListenerDelegate(exporter: exporter)
        listener.delegate = delegate
        listener.resume()
        return DaemonListenerHandle(listener: listener, delegate: delegate)
    }

    // MARK: - Health check fails when no daemon is listening (#878 core case)

    /// Pointing `connect` at a mach service name that launchd does not know
    /// about must throw — not return a zombie connection. A missing service
    /// errors well inside the timeout, so this stays fast. (The exact error is
    /// launchd-dependent — either a `connectionFailed` timeout or a propagated
    /// connection `NSError` — so we only assert that *some* error is thrown.)
    @Test func connectThrowsWhenNoDaemonListening() throws {
        let bogusService = "com.selfdrivingwiki.wikid.nonexistent.\(UUID().uuidString)"
        #expect(throws: (any Error).self) {
            try WikiDaemonConnection.connect(
                serviceName: bogusService,
                healthCheckTimeout: 4)
        }
    }

    // MARK: - Health check passes against a live daemon

    /// Against a real in-process daemon, `connect()` must succeed and return a
    /// connection whose calls actually work — proving the health check doesn't
    /// reject healthy daemons.
    @Test func connectSucceedsAndIsUsableAgainstLiveDaemon() async throws {
        let handle = makeDaemonEndpoint()
        defer { handle.listener.invalidate() }

        let conn = try WikiDaemonConnection.connect(
            endpoint: handle.endpoint, healthCheckTimeout: 5)

        // The health check passed; prove the connection really works by making
        // a second call through it. A fresh registry has no wikis.
        let wikis = try await conn.listWikis()
        #expect(wikis.isEmpty)
    }

    // MARK: - Invalidation handler fires on connection break

    /// The `invalidationHandler` installed in `connect()` must fire when the
    /// connection breaks, so a mid-session daemon death is logged (#878 §2).
    @Test func invalidationHandlerFiresOnInvalidate() async throws {
        let handle = makeDaemonEndpoint()
        defer { handle.listener.invalidate() }

        let conn = try WikiDaemonConnection.connect(
            endpoint: handle.endpoint, healthCheckTimeout: 5)

        actor Flag { var fired = false; func set() { fired = true }; var value: Bool { fired } }
        let flag = Flag()
        conn.onInvalidation = { Task { await flag.set() } }

        conn.invalidate()

        // invalidationHandler dispatches asynchronously; poll briefly.
        var observed = false
        for _ in 0..<30 {
            if await flag.value { observed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(observed, "invalidationHandler did not fire after invalidate()")
    }
}

// MARK: - Test helpers

/// Owns an anonymous listener + the (weakly-held-by-the-listener) delegate so
/// the delegate survives for the life of the test. Exposes `listener` and
/// `endpoint`; the delegate is retained privately.
private final class DaemonListenerHandle {
    let listener: NSXPCListener
    let endpoint: NSXPCListenerEndpoint
    private let delegate: HealthCheckListenerDelegate

    init(listener: NSXPCListener, delegate: HealthCheckListenerDelegate) {
        self.listener = listener
        self.endpoint = listener.endpoint
        self.delegate = delegate
    }
}

/// Listener delegate that exports a `WikiDaemonExporter`, including the
/// bidirectional event-sink sub-interface (matches the daemon's real surface).
private final class HealthCheckListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let exporter: WikiDaemonExporter

    init(exporter: WikiDaemonExporter) {
        self.exporter = exporter
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let daemonInterface = NSXPCInterface(with: WikiDaemonProtocol.self)
        let sinkInterface = NSXPCInterface(with: WikiDaemonEventSink.self)
        daemonInterface.setInterface(
            sinkInterface,
            for: #selector(WikiDaemonProtocol.registerEventSink(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        newConnection.exportedInterface = daemonInterface
        newConnection.exportedObject = exporter
        newConnection.resume()
        return true
    }
}
#endif
