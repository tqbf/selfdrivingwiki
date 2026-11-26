#if os(macOS)
import SwiftUI
import WikiCtlCore
import WikiFSCore
import WikiFSEngine

@MainActor
@Observable
final class DaemonHealthMonitor {
    public private(set) var state: DaemonConnectionState = .disconnected
    private(set) var isMonitoring = false
    var onStateChange: ((DaemonConnectionState) -> Void)?

    private let services: DaemonTransportServices
    private var stopped = false

    init(services: DaemonTransportServices) {
        self.services = services
    }

    func start() {
        guard !stopped else { return }
        isMonitoring = true
    }

    func consume(_ event: DaemonTransportEvent) {
        guard !stopped else { return }
        switch event {
        case .reconnecting, .awaitingAcceptance:
            setState(.reconnecting)
        case .connected:
            setState(.connected)
        case .disconnected, .candidateRejected, .acceptanceExpired:
            setState(.disconnected)
        case .interrupted:
            break
        case .stopped:
            stopped = true
            isMonitoring = false
            setState(.disconnected)
        }
    }

    /// A REMOTE store call failed with a transport-level error
    /// (`daemonUnavailable` / `deadlineExceeded` / `epochMismatch` /
    /// `outcomeUnknown`). Feeds the SAME state machine the transport events
    /// drive — the wiki-window reconnecting surface — without a new UI
    /// state (plans/daemon-only-access.md Phase 3 item 4). Recovery needs no
    /// signal here: a daemon that comes back emits the transport events that
    /// set `.connected`, and a degraded-but-live transport never holds the
    /// banner up on its own.
    func noteStoreTransportDegraded() {
        setState(.reconnecting)
    }

    /// The symmetric recovery leg: a REMOTE store call (or the re-handshake
    /// barrier) SUCCEEDED after a degraded episode, which proves the daemon
    /// is reachable again — stand the state back up even when the workload
    /// transport had no event to report (its `.connected` says the same
    /// thing; `setState` dedupes).
    func noteStoreTransportRecovered() {
        setState(.connected)
    }

    func forceReconnect() async {
        guard !stopped else { return }
        DebugLog.store("wikid: forceReconnect requested")
        await services.requestManualReconnect()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        isMonitoring = false
    }

    private func setState(_ newState: DaemonConnectionState) {
        let oldState = state
        guard oldState != newState else { return }
        state = newState
        DebugLog.store("wikid: connection state \(oldState.rawValue) → \(newState.rawValue)")
        onStateChange?(newState)
    }
}

private struct DaemonHealthMonitorKey: EnvironmentKey {
    static let defaultValue: DaemonHealthMonitor? = nil
}

extension EnvironmentValues {
    var daemonHealthMonitor: DaemonHealthMonitor? {
        get { self[DaemonHealthMonitorKey.self] }
        set { self[DaemonHealthMonitorKey.self] = newValue }
    }
}
#endif
