#if os(macOS)
import Foundation
import WikiFSCore

/// The in-app ACP adapter upgrade manager (plans/agent-adapter-upgrade-manager.md).
///
/// One check = decide → probe → commit:
/// 1. DECIDE (pure) for every enabled stored provider against the loaded
///    registry (`ACPAdapterUpgradeDecision.decide`).
/// 2. PROBE candidates that are `knownSupported`, eligible, not suppressed,
///    not in live use, and not in automatic backoff — through the injected
///    probe seam (`ACPAdapterCandidateProbe` in production; initialize-only).
/// 3. COMMIT once, under the `AgentProvidersConfigStore` kernel lock, with a
///    CAS recheck per provider: the adoption lands only if the provider
///    still exists and its command still equals the probed from-command
///    (MUST-FIX: no file/process I/O inside the lock; the user may have
///    edited or removed the provider during the probe).
///
/// Adoption rules (fail closed everywhere):
/// - Only `knownSupported` candidates auto-adopt — a verified contract
///   exists and its predicate admits the version.
/// - Ownership gates: `.userOwned` providers and drifted/custom command
///   shapes are never rewritten; a `.managed` baseline must still match.
/// - A restored candidate version stays suppressed for automatic checks
///   until a strictly newer candidate appears; a manual check retries.
/// - Probe failures record a bounded exponential backoff so a broken
///   upstream release cannot loop probes.
public actor ACPAdapterUpgradeManager {
    /// `.automatic` — the launch/activation path: honors backoff and restore
    /// suppression. `.manual` — the Settings "Check for Adapter Updates"
    /// action: bypasses backoff and suppression (the explicit user retry).
    public enum CheckMode: Equatable, Sendable {
        case automatic
        case manual
    }

    /// Why an adoptable-looking candidate was not probed/adopted this check.
    public enum SkipReason: Equatable, Sendable {
        /// A chat or queue workload is live on this provider; the next
        /// eligible check (or launch) retries.
        case liveUse
        /// Automatic checks wait out the recorded probe backoff.
        case backoff(until: Date)
        /// The user restored this exact version; automatic checks leave it.
        case restored(version: ACPAgentVersion)
        /// The user owns the command (edited in Settings).
        case userOwned
        /// The command shape is not a known catalog/legacy shape (custom
        /// wrapper, extra flags, absolute custom runner).
        case customCommandShape
        /// A managed baseline no longer matches (hand-edited file).
        case commandDrifted
    }

    /// What one provider's check concluded.
    public enum ProviderOutcome: Equatable, Sendable {
        case upToDate
        case notApplicable
        /// A newer pin exists; the support class says whether it can ever
        /// auto-adopt (AC 4: unsupported is visible, never committed).
        case updateAvailable(support: ACPAdapterSupport)
        case skipped(SkipReason)
        case probeFailed(reason: String, backoffUntil: Date)
        case adopted(from: [String], to: ACPPackageSpec)
        /// The candidate passed the probe but the config changed underneath
        /// (edited/removed during the probe). Nothing was written.
        case commitSkipped
    }

    /// Per-provider results of one check, keyed by provider id raw value.
    public struct Outcome: Equatable, Sendable {
        public var results: [String: ProviderOutcome]

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.results == rhs.results
        }

        init(results: [String: ProviderOutcome] = [:]) {
            self.results = results
        }

        public func outcome(for providerID: ProviderID) -> ProviderOutcome? {
            results[providerID.rawValue]
        }
    }

    /// Injected dependencies. All seams are `Sendable` closures so tests run
    /// the manager without network or subprocess.
    public struct Dependencies: Sendable {
        /// Loads the registry agents (production: `ACPRegistryClient
        /// .loadAgents()` — cache-TTL-gated live fetch with fallbacks).
        public var loadRegistryAgents: @Sendable () async -> [KnownACPAgent]
        /// Probes one candidate provider with an initialize-only handshake
        /// (production: `ACPAdapterCandidateProbe` behind login-shell PATH
        /// resolution). Tests inject a stub.
        public var probeCandidate: @Sendable (AgentProvider) async throws -> ACPAdapterCandidateReport
        /// The provider ids currently running a live chat or queue workload.
        /// Adoption never races a live session (the next check or launch
        /// retries).
        public var providersInLiveUse: @Sendable () async -> Set<ProviderID>
        /// The clock (tests inject a fixed one).
        public var now: @Sendable () -> Date

        public init(
            loadRegistryAgents: @escaping @Sendable () async -> [KnownACPAgent],
            probeCandidate: @escaping @Sendable (AgentProvider) async throws -> ACPAdapterCandidateReport,
            providersInLiveUse: @escaping @Sendable () async -> Set<ProviderID>,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.loadRegistryAgents = loadRegistryAgents
            self.probeCandidate = probeCandidate
            self.providersInLiveUse = providersInLiveUse
            self.now = now
        }
    }

    /// Backoff policy for repeated probe failures: base delay doubles with
    /// each consecutive failure, capped so a broken release still gets one
    /// automatic attempt per day.
    public static let probeBackoffBase: TimeInterval = 3_600
    public static let probeBackoffCap: TimeInterval = 86_400

    private let directory: URL
    private let store: AgentProvidersConfigStore
    private let dependencies: Dependencies

    public init(
        directory: URL,
        store: AgentProvidersConfigStore,
        dependencies: Dependencies
    ) {
        self.directory = directory
        self.store = store
        self.dependencies = dependencies
    }

    /// Run one check. Serialized by the actor; concurrent callers queue
    /// behind the running check.
    public func runCheck(mode: CheckMode) async -> Outcome {
        let now = dependencies.now()
        let agents = await dependencies.loadRegistryAgents()
        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let config = AgentProvidersConfig.loadOrSeed(from: directory)
        let liveUse = await dependencies.providersInLiveUse()

        // Phase 1+2 (pure decisions + probes, no locks held).
        var collectedFindings: [(ProviderID, ACPAdapterUpgradeDecision)] = []
        var outcomes: [String: ProviderOutcome] = [:]
        var probeResults: [(ProviderID, ProbePlan)] = []

        for provider in config.providers where provider.enabled {
            let agent = agentsByID[provider.id]
            let decision = ACPAdapterUpgradeDecision.decide(
                storedCommand: provider.command,
                registryCommand: agent?.command)
            switch decision {
            case .upToDate:
                collectedFindings.append((provider.id, decision))
                outcomes[provider.id.rawValue] = .upToDate
                continue
            case .notApplicable:
                collectedFindings.append((provider.id, decision))
                outcomes[provider.id.rawValue] = .notApplicable
                continue
            case .updateAvailable(let target, let support):
                collectedFindings.append((provider.id, decision))
                guard support.isAutoAdoptable else {
                    // AC 4: visible, never auto-adopted.
                    outcomes[provider.id.rawValue] = .updateAvailable(support: support)
                    continue
                }
                // Eligibility gates, in fail-closed order.
                if let skip = skipReason(
                    provider: provider,
                    registryCommand: agent?.command,
                    state: config.adapterUpgradeState(for: provider.id),
                    target: target,
                    liveUse: liveUse,
                    mode: mode,
                    now: now) {
                    outcomes[provider.id.rawValue] = .skipped(skip)
                    continue
                }
                probeResults.append((provider.id, ProbePlan(
                    provider: provider, target: target, mode: mode,
                    previousFailure: config.adapterUpgradeState(for: provider.id)?.probeFailure)))
            }
        }

        // Probes run sequentially — each spawns a subprocess; one at a time
        // is the polite shape.
        var probeOutcomes: [(ProviderID, ProbeOutcome)] = []
        for (providerID, plan) in probeResults {
            let outcome = await runProbe(plan)
            probeOutcomes.append((providerID, outcome))
        }

        // Phase 3: ONE locked mutation applies findings, adoptions (CAS),
        // and failure records.
        let adoptionRecords: [ProviderID: AdapterAdoptionRecord] = Dictionary(
            uniqueKeysWithValues: probeOutcomes.compactMap { id, outcome in
                guard case .commit(let record) = outcome else { return nil }
                return (id, record)
            })
        let failureRecords: [ProviderID: AdapterProbeFailure] = Dictionary(
            uniqueKeysWithValues: probeOutcomes.compactMap { id, outcome in
                guard case .failure(let failure) = outcome else { return nil }
                return (id, failure)
            })

        // Frozen inputs for the locked commit phase (Swift 6: a @Sendable
        // closure cannot capture mutating locals).
        let findings = collectedFindings
        let committed: AgentProvidersConfig?
        do {
            committed = try await store.mutate { latest in
                var working = latest
                for (providerID, decision) in findings {
                    var state = working.adapterUpgradeState(for: providerID) ?? AdapterUpgradeState()
                    state.finding = decision
                    state.checkedAt = now
                    working = working.settingAdapterUpgradeState(state, forProvider: providerID)
                }
                for (providerID, failure) in failureRecords {
                    var state = working.adapterUpgradeState(for: providerID) ?? AdapterUpgradeState()
                    state.probeFailure = failure
                    state.checkedAt = now
                    working = working.settingAdapterUpgradeState(state, forProvider: providerID)
                }
                for (providerID, record) in adoptionRecords {
                    // CAS: the adoption lands only while the provider still
                    // exists and still runs the probed from-command.
                    guard let current = working.provider(id: providerID),
                          current.command == record.fromCommand,
                          let adopted = working.adoptingAdapter(record, forProvider: providerID) else {
                        continue
                    }
                    working = adopted
                }
                return working
            }
        } catch {
            DebugLog.agent("ACPAdapterUpgradeManager: config mutation failed — findings discarded this check: \(error.localizedDescription)")
            committed = nil
        }

        // Derive final outcomes from the committed value (a CAS failure is
        // visible as an unchanged command).
        guard let committed else {
            var discarded = outcomes
            for (providerID, _) in probeResults {
                discarded[providerID.rawValue] = .commitSkipped
            }
            return Outcome(results: discarded)
        }
        for (providerID, plan) in probeResults {
            guard let probeOutcome = probeOutcomes.first(where: { $0.0 == providerID })?.1 else {
                continue
            }
            switch probeOutcome {
            case .commit(let record):
                if committed.provider(id: providerID)?.command == plan.target.launchCommand {
                    outcomes[providerID.rawValue] = .adopted(
                        from: record.fromCommand, to: plan.target)
                } else {
                    outcomes[providerID.rawValue] = .commitSkipped
                }
            case .failure(let failure):
                outcomes[providerID.rawValue] = .probeFailed(
                    reason: failure.lastError, backoffUntil: failure.backoffUntil)
            }
        }

        DebugLog.agent(
            "ACPAdapterUpgradeManager.runCheck(\(mode)): \(outcomes.count) provider(s) checked — adopted=\(adoptionRecords.count) failed=\(failureRecords.count)")
        return Outcome(results: outcomes)
    }

    // MARK: - Probe plan (private)

    private struct ProbePlan: Sendable {
        let provider: AgentProvider
        let target: ACPPackageSpec
        let mode: CheckMode
        /// The state's current failure record, for backoff escalation.
        let previousFailure: AdapterProbeFailure?
    }

    private enum ProbeOutcome: Sendable {
        /// Verified — ready to commit.
        case commit(AdapterAdoptionRecord)
        /// Errored or verification-rejected — recorded with the next backoff
        /// so a broken candidate cannot loop probes.
        case failure(AdapterProbeFailure)
    }

    /// Probe one candidate. NEVER throws — every failure (transport error or
    /// verification rejection) becomes a recorded `AdapterProbeFailure`.
    private func runProbe(_ plan: ProbePlan) async -> ProbeOutcome {
        let now = dependencies.now()
        let candidate = AgentProvider(
            id: plan.provider.id,
            label: plan.provider.label,
            command: plan.target.launchCommand,
            env: plan.provider.env,
            enabled: plan.provider.enabled,
            isDefault: plan.provider.isDefault)
        let report: ACPAdapterCandidateReport
        do {
            report = try await dependencies.probeCandidate(candidate)
        } catch {
            DebugLog.agent(
                "ACPAdapterUpgradeManager: probe failed provider=\(plan.provider.id) — \(error.localizedDescription)")
            return .failure(Self.makeFailure(
                previous: plan.previousFailure, reason: error.localizedDescription, now: now))
        }
        guard let contract = ACPAdapterCompatibility.contract(forPackage: plan.target.package) else {
            // Unreachable: only contracted candidates reach the probe.
            return .failure(Self.makeFailure(
                previous: plan.previousFailure,
                reason: "no verified contract for \(plan.target.package)", now: now))
        }
        switch ACPAdapterProbeVerification.verify(report, contract: contract) {
        case .accepted:
            let record = AdapterAdoptionRecord(
                adoptedAt: now,
                fromCommand: plan.provider.command ?? [],
                fromSpec: ACPPackageCommandParser.parse(plan.provider.command),
                toSpec: plan.target)
            return .commit(record)
        case .rejected(let rejection):
            // Defense in depth tripped: the on-disk candidate is not what
            // the registry claimed. Record as a failure with backoff.
            DebugLog.agent(
                "ACPAdapterUpgradeManager: probe REJECTED provider=\(plan.provider.id) — \(String(describing: rejection))")
            return .failure(Self.makeFailure(
                previous: plan.previousFailure,
                reason: String(describing: rejection), now: now))
        }
    }

    private static func makeFailure(
        previous: AdapterProbeFailure?, reason: String, now: Date
    ) -> AdapterProbeFailure {
        // Exponential: 1h, 2h, 4h, 8h, 16h, then the 24h cap — a broken
        // upstream release still gets one automatic attempt per day.
        let count = (previous?.count ?? 0) + 1
        let delay = min(
            Self.probeBackoffCap,
            Self.probeBackoffBase * pow(2, Double(count - 1)))
        return AdapterProbeFailure(
            count: count,
            lastError: reason,
            lastFailedAt: now,
            backoffUntil: now.addingTimeInterval(delay))
    }

    /// The fail-closed eligibility gates for probing/adopting `target`.
    private func skipReason(
        provider: AgentProvider,
        registryCommand: [String]?,
        state: AdapterUpgradeState?,
        target: ACPPackageSpec,
        liveUse: Set<ProviderID>,
        mode: CheckMode,
        now: Date
    ) -> SkipReason? {
        if liveUse.contains(provider.id) { return .liveUse }
        if let failure = state?.probeFailure, mode == .automatic,
           now < failure.backoffUntil {
            return .backoff(until: failure.backoffUntil)
        }
        if let suppressed = state?.suppressedCandidateVersion,
           suppressed == target.version, mode == .automatic {
            return .restored(version: suppressed)
        }
        switch state?.ownership {
        case .userOwned:
            return .userOwned
        case .managed(let baseline):
            // Managed baseline must still match the live command.
            return provider.command == baseline ? nil : .commandDrifted
        case nil:
            // Legacy provider (no recorded ownership): adopt only when the
            // stored command is a known catalog/legacy shape — the registry
            // shape minus the version pin (MUST-FIX: package recognition is
            // not ownership).
            guard let registryCommand,
                  let storedShape = ACPPackageCommandParser.shape(provider.command),
                  let registryShape = ACPPackageCommandParser.shape(registryCommand),
                  storedShape == registryShape else {
                return .customCommandShape
            }
            return nil
        }
    }

    private func probeOutcomeFor(
        providerID: ProviderID,
        probeOutcomes: [(ProviderID, ProbeOutcome)]
    ) -> ProbeOutcome? {
        probeOutcomes.first { $0.0 == providerID }?.1
    }
}
#endif
