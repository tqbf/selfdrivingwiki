import Testing
import Foundation
@testable import WikiFSCore

/// PURE post-handshake verification of a candidate report against the
/// package contract (no subprocess). Pins the rejection order: protocol,
/// then identity, then version.
@Suite
struct ACPAdapterProbeVerificationTests {

    private let contract = ACPAdapterContract(
        package: "@agentclientprotocol/codex-acp",
        reportedIdentity: CodexThinkingCapabilityAdapter.identity,
        versions: CodexThinkingCapabilityAdapter.supportedVersions)

    private func report(
        protocolVersion: Int? = 1,
        identity: String? = "@agentclientprotocol/codex-acp",
        version: String? = "2.9.0"
    ) -> ACPAdapterCandidateReport {
        ACPAdapterCandidateReport(
            protocolVersion: protocolVersion,
            reportedIdentity: identity.map { ACPAgentIdentity(rawValue: $0) },
            reportedVersion: version.map { ACPAgentVersion(rawValue: $0) })
    }

    @Test func compliantCandidateIsAccepted() {
        #expect(ACPAdapterProbeVerification.verify(report(), contract: contract) == .accepted)
    }

    @Test func wrongProtocolVersionIsRejected() {
        guard case .rejected(.unsupportedProtocol(let reported)) =
            ACPAdapterProbeVerification.verify(report(protocolVersion: 2), contract: contract)
        else {
            Issue.record("expected unsupportedProtocol")
            return
        }
        #expect(reported == 2)
    }

    @Test func missingAgentInfoIsRejectedIdentityMissing() {
        #expect(
            ACPAdapterProbeVerification.verify(report(identity: nil), contract: contract)
            == .rejected(.identityMissing))
    }

    @Test func identityMismatchIsRejected() {
        // The on-disk candidate reports something other than the contract's
        // verified identity — not what the registry claims it is.
        #expect(
            ACPAdapterProbeVerification.verify(report(identity: "imposter-acp"), contract: contract)
            == .rejected(.identityMismatch(
                expected: contract.reportedIdentity,
                reported: ACPAgentIdentity(rawValue: "imposter-acp"))))
    }

    @Test func versionOutsideContractIsRejected() {
        // Defense in depth: the registry claimed an in-range version, but the
        // candidate on disk reports a future major.
        #expect(
            ACPAdapterProbeVerification.verify(report(version: "3.0.0"), contract: contract)
            == .rejected(.versionOutsideContract(reported: ACPAgentVersion(rawValue: "3.0.0"))))
        #expect(
            ACPAdapterProbeVerification.verify(report(version: nil), contract: contract)
            == .rejected(.versionOutsideContract(reported: nil)))
    }

    @Test func identityOnlyContractAcceptsAnyExactVersion() {
        let identityOnly = ACPAdapterContract(
            package: "@example/agent",
            reportedIdentity: ACPAgentIdentity(rawValue: "@example/agent"),
            versions: nil)
        #expect(
            ACPAdapterProbeVerification.verify(
                report(identity: "@example/agent", version: "9.9.9"),
                contract: identityOnly) == .accepted)
    }
}
