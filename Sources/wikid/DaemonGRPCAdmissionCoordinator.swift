#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiDaemonGRPC
import WikiDaemonGRPCContract
import WikiFSCore

/// Owns the daemon's gRPC surface: the session store, the registry event
/// hub, the service provider, and the Unix-domain-socket listener.
///
/// Wiring (plans/app-daemon-wire-contract.md, first slice):
/// - The listener starts AFTER daemon boot settles; the XPC admission
///   selector answers only after ``waitUntilServing`` succeeded — the
///   endpoint and bootstrap credential go out over XPC only when a client
///   can actually connect.
/// - Admission binds each session to the calling XPC connection's stable id;
///   XPC invalidation revokes that session and terminates its streams
///   (``revokeSession(connectionID:)``), before any staging sweep the
///   exporter already performs.
/// - Teardown order enforced by the listener's ``DaemonGRPCListener/stop``:
///   stop accepting → revoke sessions + close streams + close the hub →
///   unlink under the guard flock → release it.
///
/// If the listener cannot start (path overflow, raced sibling, POSIX
/// failure) the daemon stays up on XPC alone and admission answers the
/// versioned `endpointAvailable == false` reply — visible in the log,
/// never fatal to the rest of the daemon.
// Immutable after init (readiness is a `let` assigned in init); no
// lock is needed for thread safety.
// swiftlint:disable:next unchecked_sendable
final class DaemonGRPCAdmissionCoordinator: @unchecked Sendable {

    let store: DaemonSessionStore
    let hub: DaemonRegistryEventHub
    private let provider: AppDaemonServiceProvider
    private let listener: DaemonGRPCListener
    private let lock = NSLock()
    /// Whether readiness SUCCEEDED (nil while pending). Admission answers
    /// the unavailable reply unless the listener VERIFIED ready — a failed
    /// bind or a readiness timeout is never advertised as a serving
    /// endpoint.
    private var readinessSucceeded: Bool?

    private static let readinessTimeout: Duration = .seconds(10)

    /// Build and START the listener. Throws on guard/ownership failure (a
    /// second live listener must surface here, not vanish into a log).
    init(
        containerDirectory: URL,
        listWikisHandler: @escaping @Sendable () async throws -> AppDaemonListWikisReply
    ) throws {
        let store = DaemonSessionStore()
        let hub = DaemonRegistryEventHub()
        let provider = AppDaemonServiceProvider(
            store: store,
            hub: hub,
            handlers: .init(listWikis: listWikisHandler))
        let listener = try DaemonGRPCListener(
            containerDirectory: containerDirectory,
            provider: provider,
            onShutdown: { [hub, store] in
                // Revocation first (no new calls, streams terminated), then
                // the hub (every remaining subscriber ends). The listener
                // unlinks under its guard after this returns.
                store.revokeAll()
                hub.closeAll()
            })
        self.store = store
        self.hub = hub
        self.provider = provider
        self.listener = listener
        try listener.start()
        readinessTask = Task { [weak self, listener] in
            do {
                try await listener.waitUntilServing(timeout: Self.readinessTimeout)
                self?.lock.withLock { self?.readinessSucceeded = true }
            } catch {
                // A failed bind or readiness timeout keeps admission
                // unavailable — never advertise a dead endpoint.
                DebugLog.store("wikid: gRPC listener failed readiness: \(error)")
                self?.lock.withLock { self?.readinessSucceeded = false }
            }
        }
    }

    private var readinessTask: Task<Void, Never>?

    /// The XPC admission answer for one connection. Never logs
    /// credentials. `connectionIsLive` runs at mint time under the store's
    /// lock (see ``DaemonSessionStore/admissionOffer``) so an XPC
    /// connection that died mid-admission cannot mint an orphan session.
    func admissionReply(
        connectionID: String, connectionIsLive: @escaping @Sendable () -> Bool
    ) async -> Data {
        // Wait out readiness, then require SUCCESS + LIVE state: a
        // listener that never verified serving, has stopped, or whose
        // serving loop died answers the unavailable reply.
        while true {
            let succeeded = lock.withLock { readinessSucceeded }
            if let succeeded {
                if !succeeded || !listener.isServing {
                    return Self.unavailableReply()
                }
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return Self.unavailableReply()
            }
        }
        let offer = store.admissionOffer(
            socketPath: listener.socketPath, connectionID: connectionID,
            livenessCheck: connectionIsLive)
        guard let offer else {
            return Self.unavailableReply()
        }
        // Post-mint re-check (shrinks the mint-vs-stop race to the
        // instructions between the store's commit and here): if the
        // listener stopped in that window, revoke the just-minted session
        // rather than handing out a credential for a dead endpoint.
        guard listener.isServing else {
            store.revokeSession(connectionID: connectionID)
            return Self.unavailableReply()
        }
        let reply = DaemonGRPCAdmissionReply(
            endpointAvailable: true,
            socketPath: offer.socketPath,
            bootstrapCredentialHex: offer.bootstrapCredentialHex,
            daemonInstanceID: offer.daemonInstanceID,
            bootstrapValidForSeconds: Double(DaemonSessionStore.bootstrapLifetimeNanoseconds)
                / 1_000_000_000)
        return (DebugLog.trying("JSONEncoder.encode", operation: {
            try JSONEncoder().encode(reply)
        })) ?? Self.unavailableReply()
    }

    private static func unavailableReply() -> Data {
        (DebugLog.trying("JSONEncoder.encode", operation: {
            try JSONEncoder().encode(DaemonGRPCAdmissionReply.unavailable())
        })) ?? Data()
    }

    /// XPC invalidation for one connection: revoke its session (idempotent)
    /// — no new gRPC calls admitted, live streams terminated.
    func revokeSession(connectionID: String) {
        store.revokeSession(connectionID: connectionID)
    }

    /// Terminal teardown before daemon shutdown (see the listener contract).
    func stop() async {
        await listener.stop()
    }
}
#endif
