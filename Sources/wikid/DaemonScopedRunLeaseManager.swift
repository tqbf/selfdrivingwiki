#if os(macOS)
#if canImport(WikiFSEngine)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSEngine

// The daemon-side implementation of the launcher's scoped-run lease seam
// (plans/agent-sandbox-scoping.md §5/§7). One actor per daemon process,
// installed on WikiDaemon at boot; every launcher the daemon hosts issues its
// run through here. The printable capability exists only inside the issued
// lease — this actor keeps just the lease→run-id mapping it needs for renewal
// and revocation, and the REGISTRY keeps only the digest.

/// Implements ``AgentScopedRunLeaseManaging`` over the in-process
/// ``DaemonRunRegistrationBroker``: mint→register→bind→activate per managed
/// run, owner-side renewal at the launcher's half-life cadence, and
/// idempotent revocation (registry lease + endpoint unlink) from every
/// teardown path. IN-PROCESS ONLY — the Phase 2 §5 audit found the XPC
/// channel unauthenticated, so this surface must never cross a wire.
actor DaemonScopedRunLeaseManager: AgentScopedRunLeaseManaging {

    /// The §6 initial operation policy for a managed wiki run: everything the
    /// agent legitimately needs — reads, CAS edits, source acquisition — for
    /// the ONE registered wiki, and nothing else (registry mutation, global
    /// queue controls, admin maintenance stay unclassified → denied).
    static let managedRunOperationClasses: Set<DaemonRunOperationClass> = [
        .wikiRead, .wikiEdit, .wikiAcquire,
    ]

    enum ManagerError: Error, CustomStringConvertible {
        /// Renewal or revocation arrived for a lease this manager never
        /// issued (or already revoked and dropped). Never leaks run state.
        case unknownLease

        var description: String { "no live run matches the presented lease" }
    }

    private let broker: DaemonRunRegistrationBroker
    /// Canonical §8 paths handed to every issued lease (the launcher builds
    /// the scoped Seatbelt profile from them).
    private let seatbeltInputs: AgentScopedRunSeatbeltInputs
    /// Issued leases → registry run ids. The ONLY place the printable
    /// capability's run identity survives; entries are removed exactly by
    /// `revokeScopedRun` / `revokeAll`.
    private var runIDsByLease: [AgentScopedRunLease: DaemonRunID] = [:]

    /// - Throws: when the ordinary daemon endpoint's path cannot fit a
    ///   socket address (`SearchSocketError.pathTooLong`) — a container
    ///   layout that cannot serve scoped runs at all fails at boot.
    init(
        broker: DaemonRunRegistrationBroker,
        containerDirectory: URL
    ) throws {
        self.broker = broker
        self.seatbeltInputs = AgentScopedRunSeatbeltInputs(
            appGroupContainerPath: containerDirectory.path,
            daemonEndpointPath: try SearchSocketWire.socketPath(
                inContainerDirectory: containerDirectory),
            runsDirectoryPath: containerDirectory.appendingPathComponent(
                DaemonRunRegistrationBroker.runsDirectoryName, isDirectory: true).path)
    }

    func issueScopedRun(for wikiID: WikiID) async throws -> AgentScopedRunLease {
        let handle = try await broker.launchScopedRun(
            scope: DaemonRunScope(wikiID: wikiID),
            operationClasses: Self.managedRunOperationClasses)
        let lease = AgentScopedRunLease(
            credentials: AgentScopedRunCredentials(
                endpointPath: handle.endpointPath,
                capability: handle.capability.printable),
            seatbeltInputs: seatbeltInputs,
            leaseLifetime: DaemonRunRegistry.defaultLeaseLifetime)
        runIDsByLease[lease] = handle.runID
        return lease
    }

    func renewScopedRun(_ lease: AgentScopedRunLease) async throws {
        guard let runID = runIDsByLease[lease] else {
            throw ManagerError.unknownLease
        }
        try await broker.renew(runID: runID)
    }

    func revokeScopedRun(_ lease: AgentScopedRunLease) async {
        // Unknown or already-revoked leases settle quietly: revocation is
        // idempotent by contract, so every teardown path can call this
        // unconditionally.
        guard let runID = runIDsByLease.removeValue(forKey: lease) else { return }
        await broker.revoke(runID: runID)
    }

    /// Revoke every live run — the daemon-shutdown path. The bounded lease
    /// already expires abandoned authority, but a clean shutdown should not
    /// wait out the bound.
    func revokeAll() async {
        let runIDs = Array(runIDsByLease.values)
        runIDsByLease.removeAll()
        for runID in runIDs {
            await broker.revoke(runID: runID)
        }
    }

    /// How many live leases this manager still holds (diagnostics/tests).
    func liveLeaseCount() -> Int {
        runIDsByLease.count
    }
}
#endif
#endif
