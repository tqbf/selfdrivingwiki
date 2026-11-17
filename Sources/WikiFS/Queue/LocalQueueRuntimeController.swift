#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

/// The app-side owner of the hot-swap queue client.
///
/// Phase 4 (plans/daemon-only-access.md): the app can never own a local
/// queue engine. The former handoff machine (local assembly, disposal for
/// daemon takeover, relinquishment-driven fallback) is gone; this controller
/// only installs, loses, replaces, and releases the DAEMON queue client.
/// Daemon loss surfaces the `UnavailableQueueEngine` states the
/// `QueueActivityTracker` / `BackgroundIngestCoordinator` consumers already
/// handle.
@MainActor
@Observable
final class LocalQueueRuntimeController {
    struct DaemonEndpoint: Sendable {
        let client: any QueueEngineClient
        let epoch: QueueOwnershipEpoch

        init(client: any QueueEngineClient, epoch: QueueOwnershipEpoch) {
            self.client = client
            self.epoch = epoch
        }
    }

    enum State: Sendable {
        case unavailable(reason: String)
        case daemonActive(epoch: QueueOwnershipEpoch)
        case daemonOwnershipUnresolved(expectedEpoch: QueueOwnershipEpoch, reason: String)
        case disposing

        var name: String {
            switch self {
            case .unavailable: "unavailable"
            case .daemonActive: "daemonActive"
            case .daemonOwnershipUnresolved: "daemonOwnershipUnresolved"
            case .disposing: "disposing"
            }
        }
    }

    private enum Reason {
        static let startup = "Waiting for the daemon queue."
        static let daemonOwnershipUnresolved = "Daemon queue ownership is unresolved."
        static let disposal = "The queue runtime is shutting down."
    }

    let client: QueueEngineHotSwap
    private(set) var state: State

    private var activeTransition: UInt64?

    init() {
        let unavailable = UnavailableQueueEngine(reason: Reason.startup)
        self.client = QueueEngineHotSwap(unavailable)
        self.state = .unavailable(reason: Reason.startup)
    }

    /// Install the daemon queue client. The app never assembles a local
    /// engine first, so activation is a single client swap.
    func activateDaemon(_ endpoint: DaemonEndpoint) async -> Bool {
        guard let transition = beginTransition() else { return false }
        defer { endTransition(transition) }
        await client.swap(to: endpoint.client)
        state = .daemonActive(epoch: endpoint.epoch)
        return true
    }

    /// The daemon connection dropped while it owned the queue. Ownership is
    /// unknown until a daemon reconnects; the client degrades to the
    /// unavailable engine the tracker and coordinator consumers already
    /// handle.
    func daemonOwnershipBecameUnresolved(
        expectedEpoch: QueueOwnershipEpoch,
        reason: String
    ) async {
        guard case .daemonActive(let activeEpoch) = state,
              activeEpoch == expectedEpoch else { return }
        guard let transition = beginTransition() else { return }
        defer { endTransition(transition) }
        state = .daemonOwnershipUnresolved(expectedEpoch: expectedEpoch, reason: reason)
        await client.swap(to: UnavailableQueueEngine(reason: Reason.daemonOwnershipUnresolved))
    }

    /// A reconnecting daemon presented a fresh epoch. Only an epoch CHANGE
    /// resolves the unresolved state; a stale epoch keeps it.
    func replaceUnresolvedDaemon(
        _ endpoint: DaemonEndpoint,
        expectedEpoch: QueueOwnershipEpoch
    ) async -> Bool {
        guard case .daemonOwnershipUnresolved(let unresolvedEpoch, _) = state,
              unresolvedEpoch == expectedEpoch,
              endpoint.epoch != expectedEpoch else {
            return false
        }
        guard let transition = beginTransition() else { return false }
        defer { endTransition(transition) }
        await client.swap(to: endpoint.client)
        state = .daemonActive(epoch: endpoint.epoch)
        return true
    }

    /// Release the queue client. There is no local runtime to drain, so
    /// disposal always completes.
    func dispose() async -> QueueEngineShutdownResult? {
        guard let transition = beginTransition() else { return nil }
        defer { endTransition(transition) }

        state = .disposing
        await client.swap(to: UnavailableQueueEngine(reason: Reason.disposal))
        return .shutDown
    }

    private func beginTransition() -> UInt64? {
        guard activeTransition == nil else { return nil }
        activeTransition = nextGeneration()
        return activeTransition
    }

    private func endTransition(_ transition: UInt64) {
        guard activeTransition == transition else { return }
        activeTransition = nil
    }

    private func nextGeneration() -> UInt64 {
        var current = activeTransition ?? 0
        current &+= 1
        return current
    }
}
#endif
