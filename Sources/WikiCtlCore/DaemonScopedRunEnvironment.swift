#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore

// Scoped-run credential delivery, CLI side (plans/agent-sandbox-scoping.md
// §7). The managed child receives its run endpoint + capability through two
// DEDICATED environment keys — the same keys the launcher exports
// (`AgentScopedRunCredentials` in WikiFSEngine; the literals are restated
// here because this module is the CLI's import boundary, the same way
// `SandboxProfile` restates `SearchSocketWire.maxPathBytes`). The bundled
// `wikictl` reads them AT EXECUTION TIME: when both are present every domain
// request rides the run endpoint with envelope-v2 authorization; when NEITHER
// is present the ordinary trusted path is unchanged; when EXACTLY ONE is
// present the command fails typed — a half-delivered credential must never
// select the unrestricted listener.
//
// The capability is NEVER accepted as a command-line argument (§7: arguments
// surface in process listings and diagnostics) and is never echoed.

/// The scoped daemon-run environment contract for the bundled CLI.
public enum DaemonScopedRunEnvironment {

    /// The child environment key carrying the run endpoint's absolute path.
    /// Mirrors `AgentScopedRunCredentials.endpointEnvironmentKey`.
    public static let endpointKey = "WIKI_DAEMON_RUN_ENDPOINT"
    /// The child environment key carrying the printable run capability.
    /// Mirrors `AgentScopedRunCredentials.capabilityEnvironmentKey`.
    public static let capabilityKey = "WIKI_DAEMON_RUN_CAPABILITY"

    /// How one process's environment resolves.
    public enum Resolution: Sendable, Equatable {
        /// No credential keys: the ordinary trusted CLI path (same-user
        /// trust posture — unchanged behavior for standalone use).
        case ordinary
        /// Both keys present: every domain request rides the run endpoint
        /// with envelope-v2 authorization.
        case scoped(endpointPath: String, capability: String)
    }

    /// Exactly one of the two credential keys is set. This is a delivery
    /// fault (an adapter dropped one key, or a script exported a partial
    /// pair) and MUST fail the command — falling back to the ordinary
    /// endpoint would make "remove one key" a scope downgrade (§7).
    public struct InconsistentCredentialsError: LocalizedError, Equatable {
        public init() {}

        public var errorDescription: String {
            "\(endpointKey) and \(capabilityKey) must be set TOGETHER (managed "
                + "daemon run) or both unset (ordinary use); exactly one is set. "
                + "Refusing to fall back to the ordinary daemon endpoint."
        }
    }

    /// Resolve the credential pair from one environment.
    public static func resolve(
        from environment: [String: String]
    ) throws -> Resolution {
        let endpoint = environment[endpointKey]
        let capability = environment[capabilityKey]
        switch (endpoint, capability) {
        case (nil, nil):
            return .ordinary
        case (.some(let endpointPath), .some(let printable)):
            return .scoped(endpointPath: endpointPath, capability: printable)
        default:
            throw InconsistentCredentialsError()
        }
    }

    /// The envelope authorization for one environment: nil on the ordinary
    /// path, the run capability on the scoped path.
    public static func authorization(
        from environment: [String: String]
    ) throws -> DaemonDomainAuthorization? {
        switch try resolve(from: environment) {
        case .ordinary:
            return nil
        case .scoped(_, let capability):
            return DaemonDomainAuthorization(capability: capability)
        }
    }

    /// Build the domain socket client one command uses: the ordinary
    /// container socket (unchanged behavior) or the run endpoint bound to
    /// the v2 authorization. One factory so every CLI family — command
    /// routing, registry, workload, job — resolves credentials the SAME way.
    public static func domainSocketClient(
        environment: [String: String],
        containerDirectory: URL,
        timeout: TimeInterval = DaemonWorkloadClient.defaultTimeout
    ) throws -> DaemonDomainSocketClient {
        switch try resolve(from: environment) {
        case .ordinary:
            return try DaemonDomainSocketClient(
                containerDirectory: containerDirectory,
                timeout: timeout)
        case .scoped(let endpointPath, let capability):
            return try DaemonDomainSocketClient(
                socketPath: endpointPath,
                authorization: DaemonDomainAuthorization(capability: capability),
                timeout: timeout)
        }
    }
}
#endif
