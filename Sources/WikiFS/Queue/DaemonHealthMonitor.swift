#if os(macOS)
import Foundation
import SwiftUI
import WikiCtlCore
import WikiFSCore

/// App-level coordinator for daemon connection health (#878).
///
/// Owns the recurring 30 s health-ping loop + the XPC invalidation handler.
/// Exposes `@Observable` `state` that drives the menu-bar icon badge and the
/// in-app disconnected/reconnected banner.
///
/// **State machine:**
/// ```
/// .connected ──(ping fails / invalidated)──▶ .disconnected
/// .disconnected ──(ping succeeds)──▶ .reconnecting ──(verified)──▶ .connected
/// ```
///
/// The app wires two closures:
/// - ``onDisconnect`` — swap the queue engine to a local `QueueEngine`.
/// - ``onReconnect`` — swap back to the XPC proxy + re-register the event sink.
///
/// Both fire on the main actor.
@MainActor
@Observable
final class DaemonHealthMonitor {

    // MARK: - Observable state (drives SwiftUI: badge + banner)

    /// Current daemon connection state. Every transition is logged.
    public private(set) var state: DaemonConnectionState = .disconnected

    // MARK: - Callbacks (wired by WikiFSApp)

    /// Fired (on the main actor) when the daemon becomes unreachable. The app
    /// swaps the queue engine to a local `QueueEngine` so the UI stays
    /// functional. Fires exactly once per disconnect (not on every failed ping
    /// while already disconnected).
    var onDisconnect: (() -> Void)?

    /// Fired (on the main actor) when the daemon recovers after a disconnect.
    /// The app swaps back to the XPC proxy + re-registers the event sink. The
    /// closure receives the new `WikiDaemonConnection` (the old one is
    /// invalidated).
    var onReconnect: ((WikiDaemonConnection) -> Void)?

    /// Fired (on the main actor) on EVERY state transition. Used by observers
    /// that don't need the full disconnect/reconnect flow — e.g. the menu-bar
    /// icon badge just needs to know the current state.
    var onStateChange: ((DaemonConnectionState) -> Void)?

    // MARK: - Internal

    /// The health-ping interval. 30 s in production; injectable for tests so
    /// the ping loop can be exercised in milliseconds.
    var healthPingInterval: Duration = .seconds(30)

    /// Health-check timeout passed to `WikiDaemonConnection.healthCheck`.
    var healthCheckTimeout: TimeInterval = 5

    private var connection: WikiDaemonConnection?
    private var healthPingTask: Task<Void, Never>?

    /// Whether monitoring is active (a connection has been handed to `start`).
    private(set) var isMonitoring = false

    // MARK: - Lifecycle

    /// Begin monitoring `connection`. Sets state to `.connected`, installs the
    /// invalidation handler, and starts the recurring health-ping loop.
    func start(connection: WikiDaemonConnection) {
        stop()
        self.connection = connection
        isMonitoring = true
        setState(.connected)
        installInvalidationHandler(connection)
        startHealthPings()
        DebugLog.store("wikid: DaemonHealthMonitor started — state=.connected")
    }

    /// Stop monitoring (cancel the ping loop, clear the connection reference).
    /// Does NOT change `state` — the caller decides the final state.
    func stop() {
        healthPingTask?.cancel()
        healthPingTask = nil
        connection = nil
        isMonitoring = false
    }

    // MARK: - State transitions

    private func setState(_ newState: DaemonConnectionState) {
        let old = state
        guard old != newState else { return }
        state = newState
        DebugLog.store("wikid: connection state \(old.rawValue) → \(newState.rawValue)")
        onStateChange?(newState)
    }

    // MARK: - Invalidation handler (#878 MEDIUM 2)

    private func installInvalidationHandler(_ conn: WikiDaemonConnection) {
        conn.setInvalidationHandler { [weak self] in
            // Fires on an XPC-internal queue — hop to the main actor.
            Task { @MainActor [weak self] in
                self?.handleInvalidation()
            }
        }
    }

    /// Called when the XPC connection is invalidated (daemon process exited).
    /// Transitions to `.disconnected` and fires `onDisconnect` so the app
    /// swaps to a local engine.
    private func handleInvalidation() {
        guard isMonitoring else { return }
        DebugLog.store("wikid: XPC connection invalidated — daemon process exited")
        healthPingTask?.cancel()
        healthPingTask = nil
        connection = nil
        setState(.disconnected)
        onDisconnect?()
    }

    // MARK: - Recurring health ping (#878 BLOCKER 1.1)

    private func startHealthPings() {
        healthPingTask?.cancel()
        let interval = healthPingInterval
        let timeout = healthCheckTimeout
        healthPingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
                await self.performHealthPing(timeout: timeout)
            }
        }
    }

    /// One health-ping iteration. If the daemon responds and we were
    /// `.disconnected`, attempt a reconnect. If the daemon is unreachable and
    /// we were `.connected`, disconnect.
    private func performHealthPing(timeout: TimeInterval) async {
        // If we already have a live connection, ping it.
        if let conn = connection {
            let healthy = await conn.healthCheck(timeout: timeout)
            if healthy {
                // Still connected — nothing to do.
            } else {
                // Ping failed — the connection is half-open. Invalidate it and
                // transition to disconnected.
                DebugLog.store("wikid: health ping failed — marking disconnected")
                conn.invalidate()
                connection = nil
                setState(.disconnected)
                onDisconnect?()
            }
            return
        }

        // No live connection — try to reconnect (launchd auto-launches the
        // daemon on the new NSXPCConnection).
        setState(.reconnecting)
        DebugLog.store("wikid: attempting reconnect via launchd auto-launch")
        guard let newConn = try? WikiDaemonConnection.connect() else {
            DebugLog.store("wikid: reconnect failed — still disconnected")
            setState(.disconnected)
            return
        }
        let healthy = await newConn.healthCheck(timeout: timeout)
        if healthy {
            connection = newConn
            installInvalidationHandler(newConn)
            setState(.connected)
            onReconnect?(newConn)
            DebugLog.store("wikid: reconnected — state=.connected")
        } else {
            newConn.invalidate()
            setState(.disconnected)
            DebugLog.store("wikid: reconnect health check failed — still disconnected")
        }
    }
}

// MARK: - Environment key

private struct DaemonHealthMonitorKey: EnvironmentKey {
    /// `nil` when no monitor is active (e.g. before the app wires the daemon
    /// connection).
    static let defaultValue: DaemonHealthMonitor? = nil
}

extension EnvironmentValues {
    /// The app-wide daemon health monitor (nil before the daemon connection
    /// is wired). Drives the disconnected/reconnected banner + menu-bar badge.
    var daemonHealthMonitor: DaemonHealthMonitor? {
        get { self[DaemonHealthMonitorKey.self] }
        set { self[DaemonHealthMonitorKey.self] = newValue }
    }
}
#endif
