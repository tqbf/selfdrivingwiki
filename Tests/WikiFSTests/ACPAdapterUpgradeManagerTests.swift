import Testing
import Foundation
import WikiFSCore
@testable import WikiFSEngine

/// The upgrade manager's check loop, named per acceptance criterion.
/// All seams are injected — no network, no subprocess — but commits go
/// through a REAL `AgentProvidersConfigStore` on a temp directory, so the
/// locked-mutation path is exercised end to end.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ACPAdapterUpgradeManagerTests {

    // MARK: - Harness

    /// A lock-protected box for seam values the test mutates mid-check.
    private final class LockedBox<T: Sendable>: @unchecked Sendable {
        private var value: T
        private let lock = NSLock()
        init(_ value: T) { self.value = value }
        var wrapped: T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ newValue: T) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    private let codexID = ProviderID(rawValue: "codex-acp")

    private func registryAgent(command: [String]) -> KnownACPAgent {
        KnownACPAgent(
            id: codexID,
            label: "Codex",
            summary: "fixture",
            detectExecutable: "npx",
            command: command,
            autoDetectable: false)
    }

    private struct Harness {
        let directory: URL
        let store: AgentProvidersConfigStore
        let registry: LockedBox<[KnownACPAgent]>
        let reports: LockedBox<ACPAdapterCandidateReport>
        let probeErrors: LockedBox<Error?>
        let liveUse: LockedBox<Set<ProviderID>>
        let now: LockedBox<Date>
        let manager: ACPAdapterUpgradeManager

        func config() throws -> AgentProvidersConfig {
            AgentProvidersConfig.load(from: directory)
                ?? AgentProvidersConfig.seed(discovered: [])
        }
    }

    private func makeHarness(
        storedCommand: [String],
        additionalProviders: [AgentProvider] = []
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-upgrade-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var providers = [
            AgentProvider(
                id: codexID,
                label: "Codex",
                command: storedCommand,
                env: [:],
                enabled: true,
                isDefault: true)
        ]
        providers.append(contentsOf: additionalProviders)
        let config = AgentProvidersConfig(providers: providers)
        try config.save(to: directory)
        let store = AgentProvidersConfigStore(directory: directory)
        let registry = LockedBox<[KnownACPAgent]>([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        ])
        let compliant = ACPAdapterCandidateReport(
            protocolVersion: 1,
            reportedIdentity: CodexThinkingCapabilityAdapter.identity,
            reportedVersion: ACPAgentVersion(rawValue: "2.9.0"))
        let reports = LockedBox<ACPAdapterCandidateReport>(compliant)
        let probeErrors = LockedBox<Error?>(nil)
        let liveUse = LockedBox<Set<ProviderID>>([])
        let now = LockedBox<Date>(Date(timeIntervalSince1970: 1_700_000_000))
        let manager = ACPAdapterUpgradeManager(
            directory: directory,
            store: store,
            dependencies: .init(
                loadRegistryAgents: { registry.wrapped },
                probeCandidate: { candidate in
                    if let error = probeErrors.wrapped { throw error }
                    _ = candidate
                    return reports.wrapped
                },
                providersInLiveUse: { liveUse.wrapped },
                now: { now.wrapped }))
        return Harness(
            directory: directory,
            store: store,
            registry: registry,
            reports: reports,
            probeErrors: probeErrors,
            liveUse: liveUse,
            now: now,
            manager: manager)
    }

    private func cleanup(_ harness: Harness) {
        do {
            try FileManager.default.removeItem(at: harness.directory)
        } catch {
            DebugLog.agent("ACPAdapterUpgradeManagerTests: cleanup failed — \(error.localizedDescription)")
        }
    }

    // MARK: - AC 1: convergence without opening Settings

    @Test func startupCheckRunsWithoutOpeningSettings() async throws {
        // A stored old pin + a newer in-range registry pin + a compliant
        // probe: one automatic check adopts. No Settings UI involved.
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        let outcome = await harness.manager.runCheck(mode: .automatic)
        #expect(outcome.outcome(for: codexID) == .adopted(
            from: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            to: ACPPackageSpec(
                runner: .npx,
                package: "@agentclientprotocol/codex-acp",
                version: ACPAgentVersion(rawValue: "2.9.0"))))
        let config = try harness.config()
        #expect(config.provider(id: codexID)?.command == ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        let state = try #require(config.adapterUpgradeState(for: codexID))
        #expect(state.lastAdoption?.toSpec.version == ACPAgentVersion(rawValue: "2.9.0"))
        #expect(state.finding == .upToDate)
    }

    @Test func expiredTTLChecksAgain() async throws {
        // While the registry still serves the old pin the provider is
        // up to date. When the (TTL-expired) fetch surfaces a newer pin,
        // the NEXT automatic check adopts it.
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        let first = await harness.manager.runCheck(mode: .automatic)
        #expect(first.outcome(for: codexID) == .upToDate)

        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        let second = await harness.manager.runCheck(mode: .automatic)
        guard case .adopted = second.outcome(for: codexID) else {
            Issue.record("expected adoption after the registry moved, got \(second)")
            return
        }
    }

    // MARK: - AC 2: a failed probe never changes the stored command

    @Test func failedProbeLeavesCommandAndHistoryUnchanged() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        harness.probeErrors.set(ACPProviderModelProbeError.timedOut)
        let outcome = await harness.manager.runCheck(mode: .automatic)
        guard case .probeFailed(_, let backoffUntil) = outcome.outcome(for: codexID) else {
            Issue.record("expected probeFailed, got \(outcome)")
            return
        }
        let config = try harness.config()
        // The stored command is untouched.
        #expect(config.provider(id: codexID)?.command == ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        // No adoption history, but the failure is recorded with backoff.
        let state = try #require(config.adapterUpgradeState(for: codexID))
        #expect(state.lastAdoption == nil)
        #expect(state.probeFailure?.count == 1)
        #expect(state.probeFailure?.backoffUntil == backoffUntil)
    }

    @Test func backoffDefersAutomaticChecksAndManualBypasses() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        harness.probeErrors.set(ACPProviderModelProbeError.timedOut)
        _ = await harness.manager.runCheck(mode: .automatic)
        harness.probeErrors.set(nil)

        // A second AUTOMATIC check inside the backoff window skips.
        let deferred = await harness.manager.runCheck(mode: .automatic)
        guard case .skipped(.backoff) = deferred.outcome(for: codexID) else {
            Issue.record("expected backoff skip, got \(deferred)")
            return
        }
        // The MANUAL check bypasses backoff (the explicit user retry) — and
        // the compliant probe adopts.
        let manual = await harness.manager.runCheck(mode: .manual)
        guard case .adopted = manual.outcome(for: codexID) else {
            Issue.record("expected manual adoption, got \(manual)")
            return
        }
    }

    @Test func backoffEscalatesAndCapsAtOneDay() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        harness.probeErrors.set(ACPProviderModelProbeError.timedOut)
        // Escape the backoff between failures by advancing the clock far
        // past each window, mirroring days passing between launches. Six
        // consecutive failures reach the 24h cap (1h, 2h, 4h, 8h, 16h, 24h).
        for expectedCount in 1...6 {
            _ = await harness.manager.runCheck(mode: .automatic)
            let state = try #require(try harness.config().adapterUpgradeState(for: codexID))
            #expect(state.probeFailure?.count == expectedCount)
            // Advance past the recorded backoff so the next check probes.
            if let until = state.probeFailure?.backoffUntil {
                harness.now.set(until.addingTimeInterval(60))
            }
        }
        let state = try #require(try harness.config().adapterUpgradeState(for: codexID))
        let until = try #require(state.probeFailure?.backoffUntil)
        let failedAt = try #require(state.probeFailure.map(\.lastFailedAt))
        let delay = until.timeIntervalSince(failedAt)
        #expect(delay == ACPAdapterUpgradeManager.probeBackoffCap)
    }

    // MARK: - AC 3 + restore suppression

    @Test func restoredCandidateIsSuppressedForAutomaticChecksAndRetriedManually() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        _ = await harness.manager.runCheck(mode: .automatic)
        // The user clicks Restore previous command.
        let restored = try #require(try harness.config().restoringPreviousAdapterCommand(forProvider: codexID))
        try restored.save(to: harness.directory)

        // The automatic check must NOT undo the restore.
        let auto = await harness.manager.runCheck(mode: .automatic)
        guard case .skipped(.restored(let version)) = auto.outcome(for: codexID) else {
            Issue.record("expected restored skip, got \(auto)")
            return
        }
        #expect(version == ACPAgentVersion(rawValue: "2.9.0"))
        #expect(try harness.config().provider(id: codexID)?.command == ["npx", "@agentclientprotocol/codex-acp@2.2.2"])

        // The manual check is the explicit retry and adopts again.
        let manual = await harness.manager.runCheck(mode: .manual)
        guard case .adopted = manual.outcome(for: codexID) else {
            Issue.record("expected manual retry to adopt, got \(manual)")
            return
        }
    }

    // MARK: - AC 4: unsupported is visible, never committed

    @Test func unsupportedCandidateIsVisibleAndNeverCommitted() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@3.0.0"])
        ])
        let outcome = await harness.manager.runCheck(mode: .automatic)
        #expect(outcome.outcome(for: codexID) == .updateAvailable(support: .unsupported))
        let config = try harness.config()
        #expect(config.provider(id: codexID)?.command == ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        let state = try #require(config.adapterUpgradeState(for: codexID))
        guard case .updateAvailable(let target, let support) = state.finding else {
            Issue.record("expected a recorded finding, got \(String(describing: state.finding))")
            return
        }
        #expect(target.version == ACPAgentVersion(rawValue: "3.0.0"))
        #expect(support == .unsupported)
        #expect(state.lastAdoption == nil)
    }

    @Test func unverifiedPackageIsVisibleAndNeverCommitted() async throws {
        // No verified contract for the gemini package: newer pin is visible,
        // never probed, never committed (fail closed).
        let geminiID = ProviderID(rawValue: "gemini")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-upgrade-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = AgentProvidersConfig(providers: [
            AgentProvider(
                id: geminiID, label: "Gemini",
                command: ["npx", "@google/gemini-cli@0.60.0", "--acp"],
                env: [:], enabled: true, isDefault: true)
        ])
        try config.save(to: directory)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { DebugLog.agent("cleanup failed — \(error.localizedDescription)") }
        }
        let store = AgentProvidersConfigStore(directory: directory)
        let registry = LockedBox<[KnownACPAgent]>([
            KnownACPAgent(
                id: geminiID, label: "Gemini", summary: "fixture",
                detectExecutable: "npx",
                command: ["npx", "@google/gemini-cli@0.63.0", "--acp"],
                autoDetectable: false)
        ])
        let manager = ACPAdapterUpgradeManager(
            directory: directory,
            store: store,
            dependencies: .init(
                loadRegistryAgents: { registry.wrapped },
                probeCandidate: { _ in
                    Issue.record("unverified candidates must never be probed")
                    throw ACPProviderModelProbeError.notConfigured
                },
                providersInLiveUse: { [] },
                now: { Date(timeIntervalSince1970: 1_700_000_000) }))
        let outcome = await manager.runCheck(mode: .automatic)
        #expect(outcome.outcome(for: geminiID) == .updateAvailable(support: .unverified))
        let committed = AgentProvidersConfig.load(from: directory)
        #expect(committed?.provider(id: geminiID)?.command == ["npx", "@google/gemini-cli@0.60.0", "--acp"])
    }

    // MARK: - AC 5: exact pins only

    @Test func adoptedSpawnArgvContainsExactPinOnly() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@1.1.7"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        ])
        let outcome = await harness.manager.runCheck(mode: .automatic)
        guard case .adopted(_, let target) = outcome.outcome(for: codexID) else {
            Issue.record("expected adoption, got \(outcome)")
            return
        }
        // The adopted argv is the spec's launch command: an exact pin, never
        // a floating tag.
        #expect(target.launchCommand == ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        let committed = try harness.config()
        #expect(committed.provider(id: codexID)?.command == target.launchCommand)
        #expect(committed.provider(id: codexID)?.command?.contains("@latest") == false)
    }

    // MARK: - Ownership + live use + CAS

    @Test func userOwnedProviderIsNeverTouched() async throws {
        // A custom-flagged command does not even parse as a package command,
        // so the decision itself is notApplicable — the command is never
        // touched either way.
        let harness = try makeHarness(
            storedCommand: ["npx", "--yes", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        let outcome = await harness.manager.runCheck(mode: .automatic)
        #expect(outcome.outcome(for: codexID) == .notApplicable)
        #expect(try harness.config().provider(id: codexID)?.command == ["npx", "--yes", "@agentclientprotocol/codex-acp@2.2.2"])
    }

    @Test func legacyCustomRunnerShapeIsSkipped() async throws {
        // A stored command that PARSES but does not match the registry's
        // runner shape (bun x wrapper vs the registry's npx form): the
        // shape gate skips it — the user's wrapper is not manager-owned.
        let harness = try makeHarness(
            storedCommand: ["bun", "x", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        let outcome = await harness.manager.runCheck(mode: .automatic)
        guard case .skipped(let reason) = outcome.outcome(for: codexID) else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason == .customCommandShape)
        #expect(try harness.config().provider(id: codexID)?.command == ["bun", "x", "@agentclientprotocol/codex-acp@2.2.2"])
    }

    @Test func managedBaselineDriftIsSkipped() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        // A managed baseline that no longer matches the live command
        // (hand-edited file): skip, never rewrite.
        let state = AdapterUpgradeState(
            ownership: .managed(baseline: ["npx", "@agentclientprotocol/codex-acp@2.0.0"]))
        try harness.config()
            .settingAdapterUpgradeState(state, forProvider: codexID)
            .save(to: harness.directory)
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        let outcome = await harness.manager.runCheck(mode: .automatic)
        guard case .skipped(let reason) = outcome.outcome(for: codexID) else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(reason == .commandDrifted)
    }

    @Test func liveProviderIsDeferredAndRetriedNextCheck() async throws {
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        harness.liveUse.set([codexID])
        let first = await harness.manager.runCheck(mode: .automatic)
        guard case .skipped(.liveUse) = first.outcome(for: codexID) else {
            Issue.record("expected liveUse skip, got \(first)")
            return
        }
        #expect(try harness.config().provider(id: codexID)?.command == ["npx", "@agentclientprotocol/codex-acp@2.2.2"])

        // The workload ends: the next check adopts (MUST-FIX 5 retry).
        harness.liveUse.set([])
        let second = await harness.manager.runCheck(mode: .automatic)
        guard case .adopted = second.outcome(for: codexID) else {
            Issue.record("expected adoption after the workload ended, got \(second)")
            return
        }
    }

    @Test func commitRacingEditLeavesCommandUntouched() async throws {
        // MUST-FIX 4: the CAS recheck inside the locked mutation. The probe
        // stub edits the config WHILE "probing" (simulating a user edit that
        // races the probe); the adoption must not commit over it.
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        let directory = harness.directory
        let racingStore = harness.store
        let racingManager = ACPAdapterUpgradeManager(
            directory: directory,
            store: racingStore,
            dependencies: .init(
                loadRegistryAgents: { harness.registry.wrapped },
                probeCandidate: { candidate in
                    _ = candidate
                    // The user edits the command during the probe.
                    let latest = AgentProvidersConfig.load(from: directory)
                        ?? AgentProvidersConfig.seed(discovered: [])
                    var edited = latest.providers
                    if let index = edited.firstIndex(where: { $0.id == self.codexID }) {
                        edited[index].command = ["npx", "--yes", "@agentclientprotocol/codex-acp@2.2.2"]
                    }
                    let editedConfig = latest.replacingProviders(edited)
                    _ = try await racingStore.mutate { _ in editedConfig }
                    return harness.reports.wrapped
                },
                providersInLiveUse: { [] },
                now: { harness.now.wrapped }))
        let outcome = await racingManager.runCheck(mode: .automatic)
        #expect(outcome.outcome(for: codexID) == .commitSkipped)
        // The user's edit survived untouched.
        #expect(try harness.config().provider(id: codexID)?.command == ["npx", "--yes", "@agentclientprotocol/codex-acp@2.2.2"])
    }

    @Test func adoptionPreservesLabelEnvAndDisabledSibling() async throws {
        let disabled = ProviderID(rawValue: "gemini")
        let harness = try makeHarness(
            storedCommand: ["npx", "@agentclientprotocol/codex-acp@2.2.2"],
            additionalProviders: [
                AgentProvider(
                    id: disabled, label: "Gemini",
                    command: ["gemini", "--acp"],
                    env: ["GEMINI_API_KEY_ALIAS": "work"],
                    enabled: false,
                    isDefault: false)
            ])
        defer { cleanup(harness) }
        harness.registry.set([
            registryAgent(command: ["npx", "@agentclientprotocol/codex-acp@2.9.0"])
        ])
        _ = await harness.manager.runCheck(mode: .automatic)
        let config = try harness.config()
        // The adopted provider keeps its label + env.
        let codex = try #require(config.provider(id: codexID))
        #expect(codex.label == "Codex")
        #expect(codex.env.isEmpty)
        // The disabled plain-binary provider is skipped entirely (disabled
        // providers are not checked, and its binary command is not adoptable
        // anyway).
        #expect(config.provider(id: disabled)?.command == ["gemini", "--acp"])
        #expect(config.adapterUpgradeState(for: disabled) == nil)
    }
}
