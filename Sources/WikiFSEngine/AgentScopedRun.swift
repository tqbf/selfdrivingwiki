#if os(macOS)
import Foundation
import WikiFSCore

// Scoped daemon-run credential delivery (plans/agent-sandbox-scoping.md §7).
//
// The TRUSTED RUN HOST — the daemon process that owns the in-process
// registration broker — implements ``AgentScopedRunLeaseManaging`` and installs
// it on every launcher it hosts. Before a managed child spawns, the launcher
// issues one lease for the run's ONE wiki; the lease's credentials travel to
// the child through DEDICATED environment keys
// (``AgentScopedRunCredentials/endpointEnvironmentKey`` and
// ``AgentScopedRunCredentials/capabilityEnvironmentKey``); its seatbelt inputs
// select the scoped Seatbelt profile (§8). The launcher revokes through every
// teardown path (success, error, cancellation, spawn failure, owner
// disconnect) and renews at half-life so a bounded lease cannot expire under a
// live session (§5).
//
// The capability is a SECRET: these types never render it into prompts,
// diagnostics, or descriptions, and the CLI never accepts it as an argument.

/// The child-facing credentials of one scoped daemon run. Delivered through
/// dedicated environment keys — never argv, never a prompt-rendered field
/// (§7: arguments appear in process listings and diagnostics).
public struct AgentScopedRunCredentials: Hashable, Sendable {
    /// The child environment key carrying the run endpoint's absolute path.
    /// FINAL NAME — the spawn contract and the bundled CLI both bind it.
    public static let endpointEnvironmentKey = "WIKI_DAEMON_RUN_ENDPOINT"
    /// The child environment key carrying the printable run capability.
    /// FINAL NAME — the spawn contract and the bundled CLI both bind it.
    public static let capabilityEnvironmentKey = "WIKI_DAEMON_RUN_CAPABILITY"

    /// The run endpoint's absolute path (`<container>/r/<opaque>.sock`).
    public let endpointPath: String
    /// The printable capability (the only copy the child ever sees; the
    /// daemon stores just its digest).
    public let capability: String

    public init(endpointPath: String, capability: String) {
        self.endpointPath = endpointPath
        self.capability = capability
    }

    /// The dedicated credential environment for one child spawn. The launcher
    /// merges this into the protected run keys — provider hints cannot
    /// override it, and an adapter that drops it fails the command typed
    /// (no unrestricted fallback).
    public var childEnvironment: [String: String] {
        [
            Self.endpointEnvironmentKey: endpointPath,
            Self.capabilityEnvironmentKey: capability,
        ]
    }
}

/// The canonical paths the launcher needs to wrap a scoped child in the §8
/// Seatbelt profile. Supplied by the trusted host (which owns the endpoint
/// layout) so the engine module never restates the daemon's path conventions.
public struct AgentScopedRunSeatbeltInputs: Hashable, Sendable {
    /// The App Group container directory (the profile's terminal deny
    /// subtree).
    public let appGroupContainerPath: String
    /// The ordinary daemon endpoint's absolute path (denied to the child).
    public let daemonEndpointPath: String
    /// The per-run endpoints directory's absolute path (denied to the child
    /// except for the assigned endpoint).
    public let runsDirectoryPath: String

    public init(
        appGroupContainerPath: String,
        daemonEndpointPath: String,
        runsDirectoryPath: String
    ) {
        self.appGroupContainerPath = appGroupContainerPath
        self.daemonEndpointPath = daemonEndpointPath
        self.runsDirectoryPath = runsDirectoryPath
    }
}

/// One issued scoped run: the child credentials, the seatbelt inputs, and the
/// bounded-lease cadence. Opaque to everyone except the trusted host — the
/// launcher treats it as a revocation token. `Equatable` so the renewal loop
/// can confirm the lease it observed is still the one it issued.
public struct AgentScopedRunLease: Hashable, Sendable {
    public let credentials: AgentScopedRunCredentials
    public let seatbeltInputs: AgentScopedRunSeatbeltInputs
    /// The bounded lease lifetime the trusted owner renews (§5 crash
    /// protection). The launcher renews at HALF this cadence while the run is
    /// live, so a live session never crosses the expiry.
    public let leaseLifetime: Duration

    public init(
        credentials: AgentScopedRunCredentials,
        seatbeltInputs: AgentScopedRunSeatbeltInputs,
        leaseLifetime: Duration
    ) {
        self.credentials = credentials
        self.seatbeltInputs = seatbeltInputs
        self.leaseLifetime = leaseLifetime
    }
}

/// The trusted-owner seam over the daemon's registration broker (§5). The
/// daemon implements it in-process; nothing here is reachable from the child —
/// a same-user child can never mint, renew, or widen a run.
public protocol AgentScopedRunLeaseManaging: Sendable {
    /// Register + bind + activate one run for `wikiID` BEFORE the child
    /// spawns. Throws when registration, endpoint binding, or activation
    /// fails — the caller must fail the launch (never fall back to an
    /// unscoped child).
    func issueScopedRun(for wikiID: WikiID) async throws -> AgentScopedRunLease
    /// Push the bounded lease's expiry out while the run is live. The
    /// launcher calls this at half-life.
    func renewScopedRun(_ lease: AgentScopedRunLease) async throws
    /// Revoke the run: terminal registry revocation plus endpoint teardown.
    /// MUST be idempotent — every teardown path calls it unconditionally.
    func revokeScopedRun(_ lease: AgentScopedRunLease) async
}

/// Why a managed launch refused to start. Typed so the queue item / turn
/// failure names the cause instead of a generic spawn error (§7: missing
/// credentials are a failed command, never an unrestricted fallback).
public enum AgentScopedRunError: Error, LocalizedError, Equatable {
    /// The trusted host could not register, bind, or activate the run.
    case registrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let reason):
            return "scoped daemon run registration failed: \(reason)"
        }
    }
}
#endif
