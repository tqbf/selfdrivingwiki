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
    /// The one-shot readiness gate; admission awaits this before answering.
    /// Awaiting a Task's result repeatedly is safe — every admission call
    /// waits out the same settled gate.
    private let readiness: Task<Void, Never>

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
        readiness = Task { [listener] in
            do {
                try await listener.waitUntilServing(timeout: Self.readinessTimeout)
            } catch {
                // The readiness result is read when admission is asked for;
                // a failed bind keeps admission unavailable.
                DebugLog.store("wikid: gRPC listener failed readiness: \(error)")
            }
        }
    }

    /// The XPC admission answer for one connection. Never logs credentials.
    func admissionReply(connectionID: String) async -> Data {
        _ = await readiness.result
        let offer = store.admissionOffer(
            socketPath: listener.socketPath, connectionID: connectionID)
        let reply = DaemonGRPCAdmissionReply(
            endpointAvailable: true,
            socketPath: offer.socketPath,
            bootstrapCredentialHex: offer.bootstrapCredentialHex,
            daemonInstanceID: offer.daemonInstanceID,
            bootstrapValidForSeconds: Double(DaemonSessionStore.bootstrapLifetimeNanoseconds)
                / 1_000_000_000)
        let data = (DebugLog.trying("JSONEncoder.encode", operation: {
            try JSONEncoder().encode(reply)
        })) ?? Data()
        return data
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
