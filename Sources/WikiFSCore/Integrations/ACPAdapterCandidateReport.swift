import Foundation

/// What the initialize-only candidate handshake learned about a candidate
/// adapter. Deliberately small: protocol version + reported identity +
/// reported version. The candidate probe performs NO authentication and NO
/// session traffic, so there is nothing else to report.
public struct ACPAdapterCandidateReport: Codable, Hashable, Sendable {
    /// The ACP protocol version the candidate answered with.
    public let protocolVersion: Int?
    /// `InitializeResponse.agentInfo.name` — the candidate's own identity
    /// claim. Verified against the contract table, never against the
    /// distribution package name.
    public let reportedIdentity: ACPAgentIdentity?
    /// `InitializeResponse.agentInfo.version`.
    public let reportedVersion: ACPAgentVersion?

    public init(
        protocolVersion: Int?,
        reportedIdentity: ACPAgentIdentity?,
        reportedVersion: ACPAgentVersion?
    ) {
        self.protocolVersion = protocolVersion
        self.reportedIdentity = reportedIdentity
        self.reportedVersion = reportedVersion
    }
}

/// Why a candidate failed the post-handshake verification.
public enum ACPAdapterProbeRejection: Hashable, Sendable {
    /// The candidate speaks a protocol version this build does not.
    case unsupportedProtocol(reported: Int?)
    /// The candidate reported no `agentInfo` at all — identity cannot be
    /// established, so nothing can be verified.
    case identityMissing
    /// The candidate's reported identity is not the contract's verified
    /// identity — the on-disk candidate is not what the registry says.
    case identityMismatch(expected: ACPAgentIdentity, reported: ACPAgentIdentity)
    /// The reported version falls outside the contract's version range
    /// (defense in depth: the candidate on disk can differ from the
    /// registry's claim).
    case versionOutsideContract(reported: ACPAgentVersion?)
}

/// The verification verdict for one candidate report.
public enum ACPAdapterProbeVerdict: Hashable, Sendable {
    case accepted
    case rejected(ACPAdapterProbeRejection)
}

/// PURE post-handshake verification of a candidate report against the
/// verified contract for its package. No I/O — unit-tested without a
/// subprocess.
public enum ACPAdapterProbeVerification {
    /// The ACP protocol version this build speaks.
    public static let supportedProtocolVersion = 1

    /// Verify `report` against `contract`. Order matters: protocol, then
    /// identity, then version — the diagnostics read in that order.
    public static func verify(
        _ report: ACPAdapterCandidateReport, contract: ACPAdapterContract
    ) -> ACPAdapterProbeVerdict {
        guard report.protocolVersion == supportedProtocolVersion else {
            return .rejected(.unsupportedProtocol(reported: report.protocolVersion))
        }
        guard let identity = report.reportedIdentity else {
            return .rejected(.identityMissing)
        }
        guard identity == contract.reportedIdentity else {
            return .rejected(.identityMismatch(
                expected: contract.reportedIdentity, reported: identity))
        }
        if let versions = contract.versions {
            guard versions.contains(report.reportedVersion) else {
                return .rejected(.versionOutsideContract(reported: report.reportedVersion))
            }
        }
        return .accepted
    }
}
