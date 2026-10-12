import Testing
import Foundation
@testable import WikiFSCore

/// The adapter-upgrade decision table (pure — no network, no subprocess).
/// Pins the plan's four outcomes plus the parse guards that keep floating
/// tags out of the adoption path (AC 5) and the fail-closed support
/// classification (no contract → unverified → never auto-adopted).
@Suite
struct ACPAdapterUpgradeDecisionTests {

    // MARK: - Helpers

    private func decide(
        stored: [String]?,
        registry: [String]?
    ) -> ACPAdapterUpgradeDecision {
        ACPAdapterUpgradeDecision.decide(
            storedCommand: stored,
            registryCommand: registry)
    }

    // MARK: - Parser

    @Test func parsesExactNpxSpecWithTrailingArguments() throws {
        let parsed = try #require(ACPPackageCommandParser.parse(
            ["npx", "@google/gemini-cli@0.63.0", "--acp"]))
        #expect(parsed.runner == .npx)
        #expect(parsed.package == "@google/gemini-cli")
        #expect(parsed.version == ACPAgentVersion(rawValue: "0.63.0"))
        #expect(parsed.trailingArguments == ["--acp"])
    }

    @Test func parsesScopedPackageWithoutVersionAsFloating() throws {
        let parsed = try #require(ACPPackageCommandParser.parse(
            ["bun", "x", "@agentclientprotocol/claude-agent-acp"]))
        #expect(parsed.runner == .bun)
        #expect(parsed.package == "@agentclientprotocol/claude-agent-acp")
        #expect(parsed.version == nil)
        #expect(parsed.launchCommand == ["bun", "x", "@agentclientprotocol/claude-agent-acp"])
    }

    @Test func parsesBunxAndNpmExecAndUvxForms() throws {
        let bunx = try #require(ACPPackageCommandParser.parse(["bunx", "pkg@1.2.3"]))
        #expect(bunx.runner == .bun)
        #expect(bunx.version == ACPAgentVersion(rawValue: "1.2.3"))

        let npmExec = try #require(ACPPackageCommandParser.parse(
            ["npm", "exec", "--", "pkg@2.0.0", "--serve"]))
        #expect(npmExec.runner == .npmExec)
        #expect(npmExec.version == ACPAgentVersion(rawValue: "2.0.0"))
        #expect(npmExec.trailingArguments == ["--serve"])

        let uvx = try #require(ACPPackageCommandParser.parse(
            ["uvx", "fast-agent-acp==0.10.1", "-x"]))
        #expect(uvx.runner == .uvx)
        #expect(uvx.package == "fast-agent-acp")
        #expect(uvx.version == ACPAgentVersion(rawValue: "0.10.1"))
        #expect(uvx.trailingArguments == ["-x"])
    }

    @Test func floatingVersionFormsParseButNeverYieldExactSpecs() throws {
        for command in [
            ["npx", "@agentclientprotocol/codex-acp"],
            ["npx", "@agentclientprotocol/codex-acp@latest"],
            ["npx", "@agentclientprotocol/codex-acp@^2.2.2"],
            ["npx", "@agentclientprotocol/codex-acp@~2.2"],
            ["npx", "@agentclientprotocol/codex-acp@2.x"],
            ["npx", "@agentclientprotocol/codex-acp@*"],
            ["uvx", "fast-agent-acp"],
            ["uvx", "fast-agent-acp==latest"],
        ] {
            let parsed = try #require(
                ACPPackageCommandParser.parse(command),
                "expected \(command) to parse as a package command")
            #expect(parsed.version == nil, "\(command) must parse as floating")
            #expect(
                ACPPackageCommandParser.exactSpec(parsed) == nil,
                "\(command) must never yield an exact spec")
        }
    }

    @Test func plainBinaryCommandsAreNotPackageCommands() {
        #expect(ACPPackageCommandParser.parse(["gemini", "--acp"]) == nil)
        #expect(ACPPackageCommandParser.parse(["goose", "acp"]) == nil)
        #expect(ACPPackageCommandParser.parse([]) == nil)
        #expect(ACPPackageCommandParser.parse(nil) == nil)
    }

    // MARK: - Decision table

    @Test func registryMissingEntryIsNotApplicable() {
        #expect(decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            registry: nil) == .notApplicable)
    }

    @Test func identicalSpecIsUpToDate() {
        #expect(decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            registry: ["npx", "@agentclientprotocol/codex-acp@2.2.2"]) == .upToDate)
    }

    @Test func newerSupportedRegistryPinIsUpdateAvailableKnownSupported() throws {
        let decision = decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            registry: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        guard case .updateAvailable(let target, let support) = decision else {
            Issue.record("expected updateAvailable, got \(decision)")
            return
        }
        #expect(target.version == ACPAgentVersion(rawValue: "2.9.0"))
        #expect(support == .knownSupported)
    }

    @Test func newerUnsupportedMajorIsUpdateAvailableUnsupported() throws {
        let decision = decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            registry: ["npx", "@agentclientprotocol/codex-acp@3.0.0"])
        guard case .updateAvailable(let target, let support) = decision else {
            Issue.record("expected updateAvailable, got \(decision)")
            return
        }
        #expect(target.version == ACPAgentVersion(rawValue: "3.0.0"))
        #expect(support == .unsupported)
    }

    @Test func plainBinaryStoredCommandIsNotApplicable() {
        // `gemini --acp` is user-owned even though the registry carries a
        // package spec for the same agent id.
        #expect(decide(
            stored: ["gemini", "--acp"],
            registry: ["npx", "@google/gemini-cli@0.63.0", "--acp"]) == .notApplicable)
    }

    @Test func binaryRegistryEntryIsNotApplicable() {
        // The registry itself publishes a plain-binary command (goose) —
        // nothing adoptable.
        #expect(decide(
            stored: ["goose", "acp"],
            registry: ["goose", "acp"]) == .notApplicable)
    }

    @Test func floatingStoredCommandAdoptsExactRegistryPinForContractedPackage() throws {
        // The legacy codex commands are exact but OLD; any registry pin for
        // the same package within the contract range is adoptable.
        let decision = decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@1.1.7"],
            registry: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        guard case .updateAvailable(let target, let support) = decision else {
            Issue.record("expected updateAvailable, got \(decision)")
            return
        }
        #expect(target.package == "@agentclientprotocol/codex-acp")
        #expect(target.version == ACPAgentVersion(rawValue: "2.2.2"))
        #expect(support == .knownSupported)
    }

    @Test func floatingRegistryEntryIsNeverAdoptable() {
        #expect(decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            registry: ["npx", "@agentclientprotocol/codex-acp@latest"]) == .notApplicable)
    }

    @Test func olderRegistryPinKeepsNewerStoredCommand() {
        // No silent downgrades: the stored pin is newer than the registry's.
        #expect(decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            registry: ["npx", "@agentclientprotocol/codex-acp@1.1.7"]) == .upToDate)
    }

    @Test func packageRenameUnderSameAgentIDIsNotApplicable() {
        #expect(decide(
            stored: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            registry: ["npx", "@openai/codex-acp@3.1.0"]) == .notApplicable)
    }

    @Test func uvxUpgradeAcrossPatchVersionIsDetected() throws {
        // The registry's `==` grammar with required trailing args parses and
        // compares. fast-agent-acp has no verified contract, so the support
        // class is unverified (visible, never auto-adopted).
        let decision = decide(
            stored: ["uvx", "fast-agent-acp==0.10.1", "-x"],
            registry: ["uvx", "fast-agent-acp==0.11.0", "-x"])
        guard case .updateAvailable(let target, let support) = decision else {
            Issue.record("expected updateAvailable, got \(decision)")
            return
        }
        #expect(target.version == ACPAgentVersion(rawValue: "0.11.0"))
        #expect(target.trailingArguments == ["-x"])
        #expect(support == .unverified)
    }

    @Test func unverifiedPackageIsNeverKnownSupported() throws {
        // A package without a verified contract classifies as unverified —
        // fail closed, never auto-adopted even when the pin is newer.
        let decision = decide(
            stored: ["npx", "@google/gemini-cli@0.60.0", "--acp"],
            registry: ["npx", "@google/gemini-cli@0.63.0", "--acp"])
        guard case .updateAvailable(let target, let support) = decision else {
            Issue.record("expected updateAvailable, got \(decision)")
            return
        }
        #expect(target.version == ACPAgentVersion(rawValue: "0.63.0"))
        #expect(support == .unverified)
        #expect(!support.isAutoAdoptable)
    }

    @Test func unregisteredIdentitySupportIsUnverified() {
        #expect(
            ACPAdapterCompatibility.support(
                of: ACPPackageSpec(
                    runner: .npx,
                    package: "@google/gemini-cli",
                    version: ACPAgentVersion(rawValue: "99.0.0"))) == .unverified)
    }

    @Test func codexContractRejectsFutureMajorAndAdmitsCurrent() {
        #expect(
            ACPAdapterCompatibility.support(
                of: ACPPackageSpec(
                    runner: .npx,
                    package: "@agentclientprotocol/codex-acp",
                    version: ACPAgentVersion(rawValue: "3.0.0"))) == .unsupported)
        #expect(
            ACPAdapterCompatibility.support(
                of: ACPPackageSpec(
                    runner: .npx,
                    package: "@agentclientprotocol/codex-acp",
                    version: ACPAgentVersion(rawValue: "2.2.2"))) == .knownSupported)
    }

    @Test func contractIdentityIsTypedNotDerivedFromPackageName() {
        // The registry id (`codex-acp`) and the package
        // (`@agentclientprotocol/codex-acp`) differ; the contract's verified
        // reported identity is its own constant.
        let contract = ACPAdapterCompatibility.contract(
            forPackage: "@agentclientprotocol/codex-acp")
        #expect(contract?.reportedIdentity == CodexThinkingCapabilityAdapter.identity)
        #expect(ACPAdapterCompatibility.contract(forPackage: "codex-acp") == nil)
    }

    @Test func shapeComparisonIgnoresPinsButNothingElse() {
        let registry = ["npx", "@agentclientprotocol/codex-acp@2.2.2"]
        let shape = ACPPackageCommandParser.shape(registry)
        #expect(shape == ["npx", "@agentclientprotocol/codex-acp"])
        // Legacy pin of the same shape matches.
        #expect(ACPPackageCommandParser.shape(["npx", "@agentclientprotocol/codex-acp@1.1.7"]) == shape)
        // A user-customized argv (extra flag before the package) does not.
        #expect(ACPPackageCommandParser.shape(["npx", "--yes", "@agentclientprotocol/codex-acp@1.1.7"]) != shape)
        // A custom absolute executable does not.
        #expect(ACPPackageCommandParser.shape(["/usr/local/bin/npmx", "@agentclientprotocol/codex-acp@1.1.7"]) == nil)
        // Plain binaries have no shape.
        #expect(ACPPackageCommandParser.shape(["gemini", "--acp"]) == nil)
    }
}
