import Testing
import Foundation
@testable import WikiFSCore

/// Adapter adoption storage + rollback round-trips (AC 2 / AC 3) and the
/// ownership rules that keep user-customized commands manager-free.
@Suite
struct AdapterUpgradeStateTests {

    // MARK: - Fixtures

    private let codexFrom = ACPPackageSpec(
        runner: .npx,
        package: "@agentclientprotocol/codex-acp",
        version: ACPAgentVersion(rawValue: "2.2.2"))
    private let codexTo = ACPPackageSpec(
        runner: .npx,
        package: "@agentclientprotocol/codex-acp",
        version: ACPAgentVersion(rawValue: "2.9.0"))

    private func config(
        command: [String],
        providerID: ProviderID = ProviderID(rawValue: "codex-acp"),
        label: String = "Codex",
        env: [String: String] = ["ANTHROPIC_BASE_URL": "https://example.internal"]
    ) -> AgentProvidersConfig {
        AgentProvidersConfig(providers: [
            AgentProvider(
                id: providerID,
                label: label,
                command: command,
                env: env,
                enabled: true,
                isDefault: true)
        ])
    }

    private func adoption(from: [String], to: ACPPackageSpec) -> AdapterAdoptionRecord {
        AdapterAdoptionRecord(
            adoptedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fromCommand: from,
            fromSpec: ACPPackageCommandParser.parse(from),
            toSpec: to)
    }

    // MARK: - Decode defaults

    @Test func preUpgradeManagerFileDecodesWithEmptyState() throws {
        // A legacy agent-providers.json without the adapterUpgrades key.
        let legacyJSON = """
        {"providers":[{"id":"codex-acp","label":"Codex","command":["npx","@agentclientprotocol/codex-acp@2.2.2"],"env":{},"enabled":true,"isDefault":true}]}
        """
        let decoded = try JSONDecoder().decode(AgentProvidersConfig.self, from: Data(legacyJSON.utf8))
        #expect(decoded.adapterUpgrades.isEmpty)
        #expect(decoded.providers.count == 1)
    }

    @Test func adoptionStateRoundTripsThroughJSON() throws {
        let from = ["npx", "@agentclientprotocol/codex-acp@2.2.2"]
        let record = adoption(from: from, to: codexTo)
        let state = AdapterUpgradeState(
            finding: .updateAvailable(target: codexTo, support: .knownSupported),
            checkedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastAdoption: record,
            probeFailure: AdapterProbeFailure(
                count: 1, lastError: "handshake timed out",
                lastFailedAt: Date(timeIntervalSince1970: 1_699_999_000),
                backoffUntil: Date(timeIntervalSince1970: 1_699_999_000 + 3_600)),
            suppressedCandidateVersion: ACPAgentVersion(rawValue: "2.2.9"),
            ownership: .managed(baseline: codexTo.launchCommand))
        let config = config(command: from).settingAdapterUpgradeState(
            state, forProvider: ProviderID(rawValue: "codex-acp"))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentProvidersConfig.self, from: data)
        #expect(decoded.adapterUpgrades == config.adapterUpgrades)
    }

    // MARK: - Adoption commit (AC 2 shape)

    @Test func adoptionSwapsCommandAndPreservesUserSettings() throws {
        let providerID = ProviderID(rawValue: "codex-acp")
        let from = ["npx", "@agentclientprotocol/codex-acp@2.2.2"]
        let config = config(command: from)
        let adopted = try #require(config.adoptingAdapter(
            adoption(from: from, to: codexTo), forProvider: providerID))
        let provider = try #require(adopted.provider(id: providerID))
        // The command is the new exact pin.
        #expect(provider.command == ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        // Everything else is untouched (label, env, enabled, default).
        #expect(provider.label == "Codex")
        #expect(provider.env["ANTHROPIC_BASE_URL"] == "https://example.internal")
        #expect(provider.enabled)
        #expect(provider.isDefault)
        // The rollback record + ownership landed in the same mutation.
        let state = try #require(adopted.adapterUpgradeState(for: providerID))
        #expect(state.lastAdoption?.fromCommand == from)
        #expect(state.lastAdoption?.toSpec == codexTo)
        #expect(state.ownership == .managed(baseline: provider.command ?? []))
        #expect(state.finding == .upToDate)
        #expect(state.probeFailure == nil)
    }

    @Test func adoptionOfMissingProviderReturnsNil() {
        let config = config(command: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        #expect(config.adoptingAdapter(
            adoption(from: [], to: codexTo),
            forProvider: ProviderID(rawValue: "gone")) == nil)
    }

    // MARK: - Rollback (AC 3)

    @Test func restoreButtonCommitsPreviousCommand() throws {
        let providerID = ProviderID(rawValue: "codex-acp")
        let from = ["npx", "@agentclientprotocol/codex-acp@2.2.2"]
        let config = config(command: from)
        let adopted = try #require(config.adoptingAdapter(
            adoption(from: from, to: codexTo), forProvider: providerID))
        let restored = try #require(adopted.restoringPreviousAdapterCommand(forProvider: providerID))
        let provider = try #require(restored.provider(id: providerID))
        // Byte-exact restore.
        #expect(provider.command == from)
        // The rolled-back candidate is suppressed so the automatic loop
        // cannot undo the restore.
        let state = try #require(restored.adapterUpgradeState(for: providerID))
        #expect(state.lastAdoption == nil)
        #expect(state.isSuppressed(candidateVersion: codexTo.version))
        #expect(state.ownership == .managed(baseline: from))
    }

    @Test func restoreWithoutAdoptionReturnsNil() {
        let config = config(command: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        #expect(config.restoringPreviousAdapterCommand(
            forProvider: ProviderID(rawValue: "codex-acp")) == nil)
    }

    // MARK: - Ownership (MUST: package recognition is not ownership)

    @Test func userEditMarksProviderUserOwned() throws {
        let providerID = ProviderID(rawValue: "codex-acp")
        let config = config(command: ["npx", "--yes", "@agentclientprotocol/codex-acp@2.2.2"])
            .markingAdapterCommandUserEdited(forProvider: providerID)
        let state = try #require(config.adapterUpgradeState(for: providerID))
        #expect(state.ownership == .userOwned)
    }

    @Test func twoProviderIDsSharingOnePackageStayIndependent() throws {
        let legacy = ProviderID(rawValue: "codex-acp")
        let custom = ProviderID(rawValue: "my-codex")
        let config = AgentProvidersConfig(providers: [
            AgentProvider(
                id: legacy, label: "Codex",
                command: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
                env: [:], enabled: true, isDefault: true),
            AgentProvider(
                id: custom, label: "My Codex",
                command: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
                env: [:], enabled: true, isDefault: false),
        ])
        let from = ["npx", "@agentclientprotocol/codex-acp@2.2.2"]
        let adopted = try #require(config.adoptingAdapter(
            adoption(from: from, to: codexTo), forProvider: legacy))
        // Only the adopted provider's command moved; the other provider
        // sharing the same package keeps its own pin and empty state.
        #expect(adopted.provider(id: legacy)?.command == codexTo.launchCommand)
        #expect(adopted.provider(id: custom)?.command == from)
        #expect(adopted.adapterUpgradeState(for: custom) == nil)
    }

    // MARK: - Eligibility evaluation (manager-side rule, pure input here)

    @Test func suppressedVersionBlocksCandidateAndNewerVersionDoesNot() throws {
        let providerID = ProviderID(rawValue: "codex-acp")
        let from = ["npx", "@agentclientprotocol/codex-acp@2.2.2"]
        let adopted = try #require(
            config(command: from)
                .adoptingAdapter(adoption(from: from, to: codexTo), forProvider: providerID))
        let restored = try #require(adopted.restoringPreviousAdapterCommand(forProvider: providerID))
        let state = try #require(restored.adapterUpgradeState(for: providerID))
        #expect(state.isSuppressed(candidateVersion: codexTo.version))
        #expect(!state.isSuppressed(candidateVersion: ACPAgentVersion(rawValue: "3.1.0")))
    }

    // MARK: - Display mapping (the Settings row renders these, nothing else)

    @Test func displayMapsAllDecisionStates() throws {
        let providerID = ProviderID(rawValue: "codex-acp")
        let from = ["npx", "@agentclientprotocol/codex-acp@2.2.2"]
        // updateAvailable(knownSupported) → supported-visible.
        let supported = AdapterUpgradeState(
            finding: .updateAvailable(target: codexTo, support: .knownSupported))
        #expect(supported.display == .updateAvailableSupported(spec: codexTo))
        // updateAvailable(unsupported) → unsupported-visible (AC 4).
        let unsupported = AdapterUpgradeState(
            finding: .updateAvailable(target: codexTo, support: .unsupported))
        #expect(unsupported.display == .updateAvailableUnsupported(spec: codexTo))
        // updateAvailable(unverified) → unverified-visible.
        let unverified = AdapterUpgradeState(
            finding: .updateAvailable(target: codexTo, support: .unverified))
        #expect(unverified.display == .updateAvailableUnverified(spec: codexTo))
        // upToDate / notApplicable.
        #expect(AdapterUpgradeState(finding: .upToDate).display == .upToDate)
        #expect(AdapterUpgradeState(finding: .notApplicable).display == .notApplicable)
        #expect(AdapterUpgradeState().display == .notApplicable)
        // probe failure → failed with retry window.
        let failed = AdapterUpgradeState(
            probeFailure: AdapterProbeFailure(
                count: 1, lastError: "handshake timed out",
                lastFailedAt: Date(timeIntervalSince1970: 0),
                backoffUntil: Date(timeIntervalSince1970: 3_600)))
        #expect(failed.display == .probeFailed(
            reason: "handshake timed out",
            retryAfter: Date(timeIntervalSince1970: 3_600)))
        // adoption → adopted (Restore visible).
        let record = adoption(from: from, to: codexTo)
        let adopted = try #require(config(command: from).adoptingAdapter(
            record, forProvider: providerID))
        #expect(adopted.adapterUpgradeState(for: providerID)?.display == .adopted(
            spec: codexTo, adoptedAt: record.adoptedAt))
    }
}
