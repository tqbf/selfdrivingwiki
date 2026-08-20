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
