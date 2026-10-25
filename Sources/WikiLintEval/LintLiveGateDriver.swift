import Foundation
import WikiFSCore
import WikiFSTypes

#if canImport(WikiFSEngine) && os(macOS)
import WikiCtlCore
import WikiFSEngine

// MARK: - Errors

/// Why a live gate run could not start or must stop. Every case names the
/// missing prerequisite — the driver never guesses a substitute
/// configuration or falls back to a local shim.
public enum LintLiveGateError: Error, Equatable, Sendable {
    /// The operator's provider configuration has no ENABLED provider with
    /// the requested id. The detail names what IS configured.
    case providerAbsent(requested: String, configured: [String])
    /// The provider exists but its probed model catalog holds no model
    /// matching the requested id or display name.
    case modelAbsent(requested: String, provider: String, available: [String])
    /// The matched model advertises no thinking-effort tiers, so the
    /// "lowest production effort" cannot be pinned.
    case effortUnadvertised(provider: String, model: String)
    /// The output directory is not isolated (it must live under tmp/).
    case outputDirectoryNotIsolated(String)
    /// The eval daemon substrate could not boot or serve its socket.
    case daemonUnavailable(String)
    /// A fixture group required by the plan is missing from the manifest.
    case fixtureMissing(String)
    /// The wall-clock ceiling passed before the suite finished.
    case wallClockExceeded

    public var localizedDescription: String {
        switch self {
        case .providerAbsent(let requested, let configured):
            "named prerequisite: no ENABLED provider '\(requested)' in the operator's provider configuration "
                + "(enabled: \(configured.isEmpty ? "none" : configured.joined(separator: ", ")))"
        case .modelAbsent(let requested, let provider, let available):
            "named prerequisite: provider '\(provider)' has no probed model matching '\(requested)' "
                + "(available: \(available.prefix(8).joined(separator: ", ")))"
        case .effortUnadvertised(let provider, let model):
            "named prerequisite: model '\(model)' on provider '\(provider)' advertises no thinking-effort tiers, "
                + "so the lowest production effort cannot be pinned"
        case .outputDirectoryNotIsolated(let detail):
            "output directory is not isolated: \(detail)"
        case .daemonUnavailable(let detail):
            "eval daemon substrate unavailable: \(detail)"
        case .fixtureMissing(let id):
            "named prerequisite: canonical fixture '\(id)' is missing from the manifest"
        case .wallClockExceeded:
            "the wall-clock ceiling passed before the suite finished"
        }
    }
}

// MARK: - Configuration

/// Configuration for one live gate run (plan §6.3/§6.10/§6.11).
public struct LintLiveGateConfiguration: Sendable {
    /// The operator's REAL provider-config directory (the App Group
    /// container). READ-ONLY: loaded with discovery disabled, credentials
    /// stay in the Keychain and are never copied.
    public var providerConfigDirectory: URL
    /// The dedicated eval App Group container directory. Disposable wikis
    /// live only here — never in the operator's container.
    public var evalContainerDirectory: URL
    /// The eval App Group id (set in the driver process environment before
    /// any child spawns, so every container resolution in this run — the
    /// substrate, the breaker state, and the sandboxed child's wikictl —
    /// lands on the eval container).
    public var evalAppGroupID: String
    /// Where artifacts land. Must live under tmp/ — enforced at start.
    public var outputDirectory: URL
    /// The evaluated configuration: provider id, model id or display-name
    /// prefix, and (resolved) the LOWEST advertised effort tier.
    public var providerID: String
    public var modelID: String
    /// Bail trials at the evaluated configuration (plan floor: 20).
    public var bailTrials: Int
    /// Runs of every remaining fixture group (plan floor: 3).
    public var groupRuns: Int
    /// Hard wall-clock ceiling; past it the run aborts cleanly and reports
    /// partials (plan ceiling: 8 hours).
    public var wallClockCeiling: Duration
    /// Rate-limit backoff: exponential from this base, capped.
    public var backoffBaseSeconds: UInt64
    public var backoffCapSeconds: UInt64
    /// Rate-limit retries per trial before the trial fails honestly.
    public var maxRateLimitRetries: Int

    public static let defaultBailTrials = 20
    public static let defaultGroupRuns = 3
    public static let defaultWallClockCeiling = Duration.seconds(8 * 3600)
    public static let defaultBackoffBaseSeconds: UInt64 = 5
    public static let defaultBackoffCapSeconds: UInt64 = 120
    public static let defaultMaxRateLimitRetries = 5

    public init(
        providerConfigDirectory: URL,
        evalContainerDirectory: URL,
        evalAppGroupID: String,
        outputDirectory: URL,
        providerID: String,
        modelID: String,
        bailTrials: Int = LintLiveGateConfiguration.defaultBailTrials,
        groupRuns: Int = LintLiveGateConfiguration.defaultGroupRuns,
        wallClockCeiling: Duration = LintLiveGateConfiguration.defaultWallClockCeiling,
        backoffBaseSeconds: UInt64 = LintLiveGateConfiguration.defaultBackoffBaseSeconds,
        backoffCapSeconds: UInt64 = LintLiveGateConfiguration.defaultBackoffCapSeconds,
        maxRateLimitRetries: Int = LintLiveGateConfiguration.defaultMaxRateLimitRetries
    ) {
        self.providerConfigDirectory = providerConfigDirectory
        self.evalContainerDirectory = evalContainerDirectory
        self.evalAppGroupID = evalAppGroupID
        self.outputDirectory = outputDirectory
        self.providerID = providerID
        self.modelID = modelID
        self.bailTrials = bailTrials
        self.groupRuns = groupRuns
        self.wallClockCeiling = wallClockCeiling
        self.backoffBaseSeconds = backoffBaseSeconds
        self.backoffCapSeconds = backoffCapSeconds
        self.maxRateLimitRetries = maxRateLimitRetries
    }
}

// MARK: - Evaluated configuration resolution

/// The configuration the driver resolved from the operator's provider
/// configuration — the exact evaluated configuration every admission check
/// and report line names.
public struct LintEvaluatedConfiguration: Equatable, Sendable {
    public let providerID: String
    public let providerLabel: String
    public let modelID: String
    public let modelLabel: String
    /// The provider's advertised revision fingerprint, when the config
    /// evidence carries one (else nil — a documented key limitation).
    public let modelRevision: String?
    /// The lowest advertised effort tier's value id (the `thought_level`
    /// value sent at spawn).
    public let effort: String
    /// The full acceptance-key components (pipeline hashes included).
    public let components: LintAcceptanceKey.Components
}

public enum LintLiveGateResolution {

    /// Effort values ranked lowest-first; the first rank an advertised
    /// choice matches wins. Unknown values rank after all known ones in
    /// advertised order.
    static let effortRankLowestFirst = [
        "minimal", "low", "medium", "high", "max", "highest",
    ]

    /// Resolve the evaluated configuration from an already-loaded provider
    /// configuration (WikiStrategyEval posture: the config directory is read
    /// with discovery disabled). Throws a NAMED prerequisite when the
    /// requested provider, model, or effort tier is absent.
    public static func resolve(
        configuration: AgentProvidersConfig,
        requestedProviderID: String,
        requestedModelID: String,
        pipeline: LintAcceptanceManifest.Pipeline
    ) throws -> LintEvaluatedConfiguration {
        let enabled = configuration.enabledProviders
        guard let provider = enabled.first(where: {
            $0.id.rawValue.caseInsensitiveCompare(requestedProviderID) == .orderedSame
        }) else {
            throw LintLiveGateError.providerAbsent(
                requested: requestedProviderID,
                configured: enabled.map(\.id.rawValue))
        }
        let models = configuration.cachedModels(forProvider: provider.id)
        let requested = requestedModelID.lowercased()
        let matched = models.first { $0.modelId.rawValue.lowercased() == requested }
            ?? models.first { $0.name.lowercased() == requested }
            ?? models.first { $0.name.lowercased().hasPrefix(requested) }
        guard let model = matched else {
            throw LintLiveGateError.modelAbsent(
                requested: requestedModelID, provider: provider.id.rawValue,
                available: models.map(\.name))
        }
        // The LOWEST advertised effort tier: ranked lowest-first, then
        // advertised order for unknown values.
        guard let catalog = model.thinkingOptionCatalog, !catalog.choices.isEmpty else {
            throw LintLiveGateError.effortUnadvertised(
                provider: provider.id.rawValue, model: model.name)
        }
        guard let lowest = catalog.choices.min(by: { lhs, rhs in
            let lhsRank = LintLiveGateResolution.effortRankLowestFirst.firstIndex {
                lhs.id.rawValue.caseInsensitiveCompare($0) == .orderedSame
            } ?? LintLiveGateResolution.effortRankLowestFirst.count
            let rhsRank = LintLiveGateResolution.effortRankLowestFirst.firstIndex {
                rhs.id.rawValue.caseInsensitiveCompare($0) == .orderedSame
            } ?? LintLiveGateResolution.effortRankLowestFirst.count
            return lhsRank == rhsRank
                ? lhs.id.rawValue < rhs.id.rawValue
                : lhsRank < rhsRank
        }) else {
            throw LintLiveGateError.effortUnadvertised(
                provider: provider.id.rawValue, model: model.name)
        }
        let components = LintAcceptanceKey.Components(
            provider: provider.id.rawValue,
            model: model.modelId.rawValue,
            modelRevision: nil,
            effort: lowest.id.rawValue,
            promptSHA256: pipeline.promptSHA256,
            detectorRevision: pipeline.detectorRevision,
            fixtureDigest: pipeline.fixtureDigest)
        return LintEvaluatedConfiguration(
            providerID: provider.id.rawValue,
            providerLabel: provider.label,
            modelID: model.modelId.rawValue,
            modelLabel: model.name,
            modelRevision: nil,
            effort: lowest.id.rawValue,
            components: components)
    }
}

// MARK: - Budget (pure, testable)

/// The run's budget: trial counts bound the suite; the wall-clock ceiling
/// bounds its duration; the backoff schedule bounds retry pressure.
public struct LintLiveGateBudget: Sendable {
    public let deadline: ContinuousClock.Instant
    public let ceiling: Duration

    public init(now: ContinuousClock.Instant = .now, ceiling: Duration) {
        self.deadline = now + ceiling
        self.ceiling = ceiling
    }

    public func timeRemaining(now: ContinuousClock.Instant = .now) -> Duration {
        let remaining = now.duration(to: deadline)
        return remaining > .zero ? remaining : .zero
    }

    public func isExhausted(now: ContinuousClock.Instant = .now) -> Bool {
        now >= deadline
    }

    /// Exponential backoff before retry N (1-based): base × 2^(N−1), capped.
    public func backoffSeconds(retry: Int, base: UInt64, cap: UInt64) -> UInt64 {
        guard retry > 0 else { return 0 }
        let exponent = min(retry - 1, 16)
        let scaled = base.multipliedReportingOverflow(by: 1 << exponent)
        return scaled.overflow ? cap : min(scaled.partialValue, cap)
    }
}

// MARK: - Suite composition (pure, testable)

/// One planned trial.
public struct LintLiveTrialPlan: Equatable, Sendable {
    public let fixtureID: String
    public let trialIndex: Int
    /// Clean/idempotence group: the lint runs TWICE and each run must write
    /// zero page edits (AC-06).
    public let isIdempotencePair: Bool

    public init(fixtureID: String, trialIndex: Int, isIdempotencePair: Bool = false) {
        self.fixtureID = fixtureID
        self.trialIndex = trialIndex
        self.isIdempotencePair = isIdempotencePair
    }
}

public enum LintLiveGateSuiteComposer {
    /// The canonical bail fixture id (the #1461 shape: clean pre-flight
    /// report over one hidden whole-body fence defect).
    public static let bailFixtureID = "bail-d25-wrap"

    /// Compose the suite: `bailTrials` independent bail trials plus
    /// `groupRuns` runs of every remaining fixture group. The clean fixture's
    /// runs are idempotence pairs (two lint runs each).
    public static func compose(
        manifest: LintEvalFixtureManifest,
        bailTrials: Int,
        groupRuns: Int
    ) throws -> [LintLiveTrialPlan] {
        let all = manifest.tuning + manifest.heldOut
        guard all.contains(where: { $0.id == bailFixtureID }) else {
            throw LintLiveGateError.fixtureMissing(bailFixtureID)
        }
        var trials: [LintLiveTrialPlan] = []
        for index in 1...max(bailTrials, 0) {
            trials.append(LintLiveTrialPlan(fixtureID: bailFixtureID, trialIndex: index))
        }
        for fixture in all where fixture.id != bailFixtureID {
            let idempotent = fixture.seededDefects.isEmpty
            for index in 1...max(groupRuns, 0) {
                trials.append(LintLiveTrialPlan(
                    fixtureID: fixture.id, trialIndex: index,
                    isIdempotencePair: idempotent))
            }
        }
        return trials
    }
}

// MARK: - Per-trial record (capture per §6.11)

/// One trial's captured evidence — persisted even for FAILED trials, never
/// dropped from totals.
public struct LintLiveTrialRecord: Codable, Sendable {
    public let fixtureID: String
    public let trialIndex: Int
    public let isIdempotencePair: Bool
    public let wikiID: String
    public let startedAt: Date
    public let finishedAt: Date
    /// The authority tier the plan granted (reportOnly on refusals).
    public let authorityTier: String
    public let authorityReason: String?
    /// The dispatch outcome's status + audit detail.
    public let runStatus: String
    public let runDetail: String
    /// Classes the run repaired, host-observed (seed evidence gone).
    public let appliedClasses: [String]
    /// Score hits as per-defect units ("D25#1") — host-observed.
    public let hits: [String]
    /// The diff-oracle verdict (hunks reconstructed from the store-observed
    /// change regions — the same server-observed definition production
    /// verification uses).
    public let oracleAccepted: Bool
    public let oracleRejections: [String]
    public let scorePassed: Bool
    public let scoreFailures: [String]
    /// For idempotence pairs: per-run write counts (both must be zero).
    public let idempotenceWrites: [Int]?
    /// Rate-limit retries this trial consumed.
    public let rateLimitRetries: Int
    public let seededBodySHA256: String
    public let finalBodySHA256: String
    public let transcriptDirectory: String?
    public let error: String?

    public init(
        fixtureID: String,
        trialIndex: Int,
        isIdempotencePair: Bool,
        wikiID: String,
        startedAt: Date,
        finishedAt: Date,
        authorityTier: String,
        authorityReason: String?,
        runStatus: String,
        runDetail: String,
        appliedClasses: [String],
        hits: [String],
        oracleAccepted: Bool,
        oracleRejections: [String],
        scorePassed: Bool,
        scoreFailures: [String],
        idempotenceWrites: [Int]?,
        rateLimitRetries: Int,
        seededBodySHA256: String,
        finalBodySHA256: String,
        transcriptDirectory: String?,
        error: String?
    ) {
        self.fixtureID = fixtureID
        self.trialIndex = trialIndex
        self.isIdempotencePair = isIdempotencePair
        self.wikiID = wikiID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.authorityTier = authorityTier
        self.authorityReason = authorityReason
        self.runStatus = runStatus
        self.runDetail = runDetail
        self.appliedClasses = appliedClasses
        self.hits = hits
        self.oracleAccepted = oracleAccepted
        self.oracleRejections = oracleRejections
        self.scorePassed = scorePassed
        self.scoreFailures = scoreFailures
        self.idempotenceWrites = idempotenceWrites
        self.rateLimitRetries = rateLimitRetries
        self.seededBodySHA256 = seededBodySHA256
        self.finalBodySHA256 = finalBodySHA256
        self.transcriptDirectory = transcriptDirectory
        self.error = error
    }

    public var passed: Bool {
        error == nil && oracleAccepted && scorePassed
            && (idempotenceWrites ?? []).allSatisfy { $0 == 0 }
    }
}

// MARK: - Gate report (AC.13)

/// The run's gate report. The mechanical verdict is computed here; the
/// human-rubric judgment sections stay PENDING OPERATOR — the operator
/// reviews this report before any approval row ships.
public struct LintLiveGateReport: Codable, Sendable {
    public struct RunMetadata: Codable, Sendable {
        public let runKind: String
        public let startedAt: Date
        public let finishedAt: Date
        public let provider: String
        public let providerLabel: String
        public let model: String
        public let modelLabel: String
        public let advertisedRevision: String?
        public let configuredEffort: String
        public let effectiveEffort: String
        public let promptSHA256: String
        public let detectorRevision: String
        public let fixtureDigest: String
        public let acceptanceKeySHA256: String
        public let evalAppGroupID: String
    }

    public struct GroupSummary: Codable, Sendable {
        public let fixtureID: String
        public let trials: Int
        public let passed: Int
        public let failed: Int
    }

    public let metadata: RunMetadata
    public let plannedTrials: Int
    public let executedTrials: Int
    public let trials: [LintLiveTrialRecord]
    public let groups: [GroupSummary]
    /// Per-class aggregate (class → seeded / hit / false-confirmed).
    public let classScores: [ClassScoreLine]
    public let wallClockConsumedSeconds: Double
    public let rateLimitRetries: Int
    public let abortedEarly: Bool
    public let abortReason: String?
    public let verdict: String
    public let blockingReasons: [String]
    /// Always true in this report: the operator reviews the evidence before
    /// any approval row ships (AC.13's human-rubric sections).
    public let humanRubricSections: String

    public struct ClassScoreLine: Codable, Sendable {
        public let defectClass: String
        public let seeded: Int
        public let hits: Int
        public let falseConfirmed: Int
        public var recall: Double { seeded == 0 ? 0 : Double(hits) / Double(seeded) }
    }

    /// The mechanical gate (AC.13): 20/20 bail + 3× groups + zero missed
    /// seeded defects + zero false confirmed defects + zero unattributed
    /// edits, with no early abort.
    public static func verdict(
        records: [LintLiveTrialRecord], plannedTrials: Int, bailTrials: Int,
        groupRuns: Int, manifest: LintEvalFixtureManifest, abortedEarly: Bool
    ) -> (verdict: String, blockingReasons: [String]) {
        var reasons: [String] = []
        if abortedEarly { reasons.append("the run aborted before the planned suite finished") }
        let executed = records.count
        if executed < plannedTrials {
            reasons.append("executed \(executed) of \(plannedTrials) planned trials")
        }
        let failed = records.filter { !$0.passed }
        if !failed.isEmpty {
            reasons.append(
                "\(failed.count) failing trial(s): "
                    + failed.map { "\($0.fixtureID)#\($0.trialIndex)" }
                        .joined(separator: ", "))
        }
        let bail = records.filter { $0.fixtureID == LintLiveGateSuiteComposer.bailFixtureID }
        let bailPassed = bail.filter(\.passed).count
        if bailPassed < bailTrials {
            reasons.append("bail trials passed \(bailPassed)/\(bailTrials) (need \(bailTrials)/\(bailTrials))")
        }
        let others = Set((manifest.tuning + manifest.heldOut).map(\.id))
            .subtracting([LintLiveGateSuiteComposer.bailFixtureID])
        for fixtureID in others.sorted() {
            let group = records.filter { $0.fixtureID == fixtureID }
            let passed = group.filter(\.passed).count
            if passed < groupRuns {
                reasons.append("group \(fixtureID) passed \(passed)/\(groupRuns)")
            }
        }
        let missedSeeds = records.flatMap(\.scoreFailures).filter { $0.contains("seeded defect missed") }
        if !missedSeeds.isEmpty {
            reasons.append("\(missedSeeds.count) missed seeded defect(s)")
        }
        let falseConfirmed = records.flatMap { record in
            record.scoreFailures.filter { $0.contains("false confirmed") }
        }
        if !falseConfirmed.isEmpty {
            reasons.append("\(falseConfirmed.count) false confirmed defect(s)")
        }
        let unattributed = records.filter { $0.oracleAccepted == false && $0.error == nil }
        if !unattributed.isEmpty {
            reasons.append("\(unattributed.count) trial(s) with unattributed edits (diff oracle rejections)")
        }
        return (reasons.isEmpty ? "PASSED" : "FAILED", reasons)
    }
}

// MARK: - The driver

/// The W3 live gate driver: composes the production provider runtime, the
/// in-process eval daemon substrate, the REAL selected-page coordinator path
/// (real prompts, scoped daemon endpoint, production provider/model/effort,
/// `wikictl page patch`), and the canonical fixture suite; captures evidence
/// per plan §6.11; and emits the AC.13 gate report.
///
/// Disposable wikis are created through the trusted daemon lifecycle APIs
/// (`DaemonWikiRegistryClient`) against the DEDICATED eval App Group
/// container and evicted through the same APIs on success, failure,
/// cancellation, and budget exhaustion. The driver never touches an
/// operator wiki and never writes acceptance records.
public struct LintLiveGateDriver: Sendable {
    private let configuration: LintLiveGateConfiguration

    public init(configuration: LintLiveGateConfiguration) {
        self.configuration = configuration
    }

    // MARK: Entry

    /// Run the gate. Throws only on start-up prerequisites; trial failures
    /// are captured in the report (the gate verdict is the report's, not an
    /// exception). The substrate handle must be booted over the eval
    /// container by the host; the construction factories come from the host
    /// too (the CORDIS boundary reserves store/model/launcher construction
    /// for plugin/factory/host code).
    public mutating func run(
        substrate: LintEvalSubstrateHandle,
        factories: LintLiveGateFactories
    ) async throws -> LintLiveGateReport {
        try validateOutputIsolation()
        // Every container resolution in THIS process — the substrate, the
        // breaker state, and the sandboxed child's wikictl — must land on the
        // eval container, never the operator's. Set before any spawn.
        setenv("WIKI_APP_GROUP_ID", configuration.evalAppGroupID, 1)

        let manifest = try LintEvalCanonicalFixtures.loadGateManifest()
        let trials = try LintLiveGateSuiteComposer.compose(
            manifest: manifest, bailTrials: configuration.bailTrials,
            groupRuns: configuration.groupRuns)

        // The evaluated configuration from the operator's REAL provider
        // configuration — read-only, discovery disabled. A missing
        // provider/model/effort is a NAMED prerequisite, never a fallback.
        let config = AgentProvidersConfig.loadOrSeed(
            from: configuration.providerConfigDirectory,
            discover: { [] })
        let pipeline = try LintAcceptanceManifest.Pipeline.live()
        let evaluated = try LintLiveGateResolution.resolve(
            configuration: config,
            requestedProviderID: configuration.providerID,
            requestedModelID: configuration.modelID,
            pipeline: pipeline)

        try FileManager.default.createDirectory(
            at: configuration.outputDirectory, withIntermediateDirectories: true)

        let clock = ContinuousClock()
        let start = clock.now
        let budget = LintLiveGateBudget(now: start, ceiling: configuration.wallClockCeiling)

        // The production provider-runtime composition, mirrored from
        // `ProductionPluginCatalogs` (WikiStrategyEval's composition):
        // read-only config reads, login-shell PATH resolution, Keychain
        // credential reads at spawn time, .bypass permission (the eval child
        // is the sandboxed lint agent, scoped-lease governed).
        let configDirectory = configuration.providerConfigDirectory
        let runtimeHandle = try await AgentProviderRuntimeFactory(
            readConfiguration: {
                AgentProvidersConfig.loadOrSeed(from: configDirectory, discover: { [] })
            },
            resolveCommand: { providers in
                await ProviderCommandResolver.resolveCommands(
                    for: providers,
                    searchPath: await PathPreflight.loginShellPATH())
            },
            readCredential: { providerID in
                KeychainACPCredentialStore().apiKey(forProvider: providerID.rawValue)
            },
            readSpawnSecrets: { providerID in
                ProviderSecretEnvironment.resolvedSpawnSecrets(
                    for: providerID,
                    resolving: KeychainCredentialService())
            },
            resolvePermissionPolicy: { _ in .bypass }
        ).assemble()
        defer {
            let handle = runtimeHandle
            Task {
                do { try await handle.dispose() }
                catch { DebugLog.agent("lint eval: provider runtime dispose failed: \(error.localizedDescription)") }
            }
        }

        // The in-process eval daemon substrate (booted by the HOST over the
        // eval container): its scoped-run lease manager is the authority
        // path production lint runs use (lint launches REQUIRE it; there is
        // no unscoped fallback). The HOST owns the substrate lifecycle.

        var records: [LintLiveTrialRecord] = []
        var abortedEarly = false
        var abortReason: String?
        var retriesTotal = 0

        trialLoop: for trial in trials {
            if budget.isExhausted(now: clock.now) {
                abortedEarly = true
                abortReason = LintLiveGateError.wallClockExceeded.localizedDescription
                break trialLoop
            }
            guard let fixture = (manifest.tuning + manifest.heldOut)
                .first(where: { $0.id == trial.fixtureID }) else {
                throw LintLiveGateError.fixtureMissing(trial.fixtureID)
            }
            var retry = 0
            while true {
                if budget.isExhausted(now: clock.now) {
                    abortedEarly = true
                    abortReason = LintLiveGateError.wallClockExceeded.localizedDescription
                    break trialLoop
                }
                do {
                    let (record, retries) = try await runTrial(
                        trial: trial, fixture: fixture, evaluated: evaluated,
                        services: runtimeHandle.services, substrate: substrate,
                        factories: factories)
                    retriesTotal += retries
                    records.append(record)
                    try persist(records: records, evaluated: evaluated, manifest: manifest,
                                trials: trials, start: start, clock: clock,
                                retriesTotal: retriesTotal, abortedEarly: false,
                                abortReason: nil)
                    break
                } catch let error as LintLiveGateError {
                    throw error
                } catch is CancellationError {
                    abortedEarly = true
                    abortReason = "cancelled"
                    break trialLoop
                } catch {
                    if Self.isRateLimit(error), retry < configuration.maxRateLimitRetries {
                        retry += 1
                        retriesTotal += 1
                        let seconds = budget.backoffSeconds(
                            retry: retry,
                            base: configuration.backoffBaseSeconds,
                            cap: configuration.backoffCapSeconds)
                        DebugLog.agent("lint eval: rate-limited on \(trial.fixtureID)#\(trial.trialIndex); backing off \(seconds)s (retry \(retry)/\(configuration.maxRateLimitRetries))")
                        // A cancelled backoff sleep is fine — the next
                        // iteration re-checks the budget before retrying.
                        // swiftlint:disable:next silent_try_optional
                        try? await Task.sleep(for: .seconds(seconds))
                        continue
                    }
                    // An honest failure: recorded, never dropped.
                    records.append(Self.failedRecord(
                        trial: trial, error: error, startedAt: Date()))
                    try persist(records: records, evaluated: evaluated, manifest: manifest,
                                trials: trials, start: start, clock: clock,
                                retriesTotal: retriesTotal, abortedEarly: false,
                                abortReason: nil)
                    break
                }
            }
        }

        return try finalize(
            records: records, evaluated: evaluated, manifest: manifest, trials: trials,
            start: start, clock: clock, retriesTotal: retriesTotal,
            abortedEarly: abortedEarly, abortReason: abortReason)
    }

    // MARK: One trial

    /// One trial: disposable wiki → seeded page → launcher → REAL coordinator
    /// dispatch → capture → evict. The wiki is evicted on EVERY exit path.
    func runTrial(
        trial: LintLiveTrialPlan,
        fixture: LintEvalFixture,
        evaluated: LintEvaluatedConfiguration,
        services: any AgentProviderServices,
        substrate: LintEvalSubstrateHandle,
        factories: LintLiveGateFactories
    ) async throws -> (record: LintLiveTrialRecord, retries: Int) {
        let client = try DaemonWikiRegistryClient(
            containerDirectory: configuration.evalContainerDirectory)
        let descriptor = try await client.createWiki(
            name: "lint-eval-\(trial.fixtureID)-\(trial.trialIndex)-\(UUID().uuidString.prefix(8))")
        do {
            let record = try await runTrialBody(
                trial: trial, fixture: fixture, evaluated: evaluated, services: services,
                substrate: substrate, factories: factories, descriptor: descriptor)
            await Self.evictWiki(client, id: descriptor.id, after: "trial completed")
            return (record, 0)
        } catch {
            await Self.evictWiki(client, id: descriptor.id, after: "trial failed")
            throw error
        }
    }

    private func runTrialBody(
        trial: LintLiveTrialPlan,
        fixture: LintEvalFixture,
        evaluated: LintEvaluatedConfiguration,
        services: any AgentProviderServices,
        substrate: LintEvalSubstrateHandle,
        factories: LintLiveGateFactories,
        descriptor: WikiDescriptor
    ) async throws -> LintLiveTrialRecord {
        let startedAt = Date()
        let databaseURL = configuration.evalContainerDirectory
            .appendingPathComponent("\(descriptor.id.rawValue).sqlite", isDirectory: false)
        // Seed the fixture page through the REAL persistence seam on the
        // daemon-created database (a second WAL-mode writer, the same
        // posture as any daemon command). The connection is scoped to this
        // block so it never races the daemon's eviction.
        let (pageID, _, seededBody) = try await Self.seedFixture(
            fixture: fixture, databaseURL: databaseURL, title: trial.fixtureID,
            factories: factories)
        // Per-trial launcher: production composition (per-run state is
        // single-run by design). The scoped-run lease manager is REQUIRED
        // for lint launches; the effort override pins the evaluated tier.
        let quotaStateURL = configuration.outputDirectory
            .appendingPathComponent("quota-state.json", isDirectory: false)
        let launcher = await MainActor.run { () -> AgentLauncher in
            factories.buildLauncher(
                services, substrate.leaseManager, evaluated.effort, quotaStateURL)
        }

        let admission = AgentOperationRunner.LintEvaluationAdmission(
            evaluated: evaluated.components, admittedWikiIDs: [descriptor.id])
        let store = try factories.buildStore(databaseURL)
        let storeModel = await MainActor.run { factories.buildStoreModel(store) }
        let outcome = await AgentOperationRunner.runOneEvaluationLintPage(
            pageID: pageID,
            launcher: launcher,
            store: storeModel,
            wikiID: descriptor.id,
            changeSignaler: LintEvalChangeSignaler(),
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            admission: admission)
        await launcher.awaitProviderRelease()

        // Capture: final bytes from the store's OWN reads, transcripts from
        // the launcher's run scratch. The second (repeat) lint run for
        // idempotence pairs happens inside the same admitted wiki.
        var idempotenceWrites: [Int]? = nil
        if trial.isIdempotencePair {
            let secondOutcome = await AgentOperationRunner.runOneEvaluationLintPage(
                pageID: pageID,
                launcher: launcher,
                store: storeModel,
                wikiID: descriptor.id,
                changeSignaler: LintEvalChangeSignaler(),
                wikictlDirectory: HelpersLocation.wikictlDirectory,
                admission: admission)
            idempotenceWrites = [
                Self.writeCount(of: outcome), Self.writeCount(of: secondOutcome),
            ]
        }

        let captured = try await Self.capture(
            trial: trial, fixture: fixture, seededBody: seededBody,
            outcome: outcome, launcher: launcher, databaseURL: databaseURL,
            wikiID: descriptor.id, startedAt: startedAt,
            idempotenceWrites: idempotenceWrites,
            factories: factories,
            outputDirectory: configuration.outputDirectory)
        return captured
    }

    /// Eviction is best-effort and logged (WikiStrategyEval's posture): a
    /// failed eviction must not lose the trial's record, and a left-behind
    /// wiki IS visible in the eval registry for the operator to see.
    static func evictWiki(
        _ client: DaemonWikiRegistryClient, id: WikiID, after reason: String
    ) async {
        do {
            try await client.deleteWiki(id: id)
        } catch {
            DebugLog.agent("lint eval: throwaway wiki delete (\(reason)) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Seeding + capture (static for testability)

    static func openStore(
        databaseURL: URL, factories: LintLiveGateFactories
    ) throws -> GRDBWikiStore {
        // The on-disk disposable store comes from the HOST-injected factory
        // (the CORDIS boundary reserves GRDBWikiStore construction for
        // plugin/factory/host code).
        try factories.buildStore(databaseURL)
    }

    static func seedFixture(
        fixture: LintEvalFixture, databaseURL: URL, title: String,
        factories: LintLiveGateFactories
    ) async throws -> (PageID, PageVersionID?, String) {
        let store = try openStore(databaseURL: databaseURL, factories: factories)
        defer { _ = store }
        return try await MainActor.run {
            let outcome = try store.upsertPage(
                id: nil, title: title, rawBody: fixture.body,
                expectation: .expectedAbsence, author: "lint-eval-driver",
                provenance: [])
            let read = try store.readPageCoherent(id: outcome.id)
            return (outcome.id, read.headVersionID, read.body)
        }
    }

    /// The host-observed write count of one dispatch outcome: a page whose
    /// head moved was written; anything else was not.
    static func writeCount(of outcome: AgentOperationRunner.LintPageDispatchOutcome) -> Int {
        outcome.status == .dispatched && outcome.authority?.tier == .evaluationAdmission
            ? 1 : 0
    }

    static func capture(
        trial: LintLiveTrialPlan,
        fixture: LintEvalFixture,
        seededBody: String,
        outcome: AgentOperationRunner.LintPageDispatchOutcome,
        launcher: AgentLauncher,
        databaseURL: URL,
        wikiID: WikiID,
        startedAt: Date,
        idempotenceWrites: [Int]?,
        factories: LintLiveGateFactories,
        outputDirectory: URL
    ) async throws -> LintLiveTrialRecord {
        // Final bytes from the store's own reads.
        let store = try Self.openStore(databaseURL: databaseURL, factories: factories)
        let finalBody: String
        do {
            let read = try await MainActor.run { try store.readPageCoherent(id: outcome.pageID) }
            finalBody = read.body
        } catch {
            finalBody = seededBody
        }

        // Hunks reconstructed from the SERVER-OBSERVED change region — the
        // same definition production verification uses (prefix/suffix trim
        // over store bytes). Classes come from the fixture's own repair
        // declarations where the observed edit matches one, else from the
        // seeded evidence the region covers — never from agent claims.
        let reconstructed = Self.observedHunks(
            before: seededBody, after: finalBody, fixture: fixture)
        let oracle = LintDiffOracle.verify(
            original: seededBody, new: finalBody,
            hunks: reconstructed.hunks, fixture: fixture)
        let observed = LintEvalScoring.ObservedRun(
            confirmedClasses: reconstructed.confirmedClasses,
            unresolvedClasses: reconstructed.unresolvedClasses,
            validAsWrittenClasses: [],
            repairedClasses: reconstructed.repairedClasses,
            coverageFailed: outcome.status == .failed)
        let score = LintEvalScoring.score(fixture: fixture, run: observed)

        // Transcript evidence: copy the launcher's run scratch (run report +
        // wire logs) into the artifacts directory.
        let trialDirectory = outputDirectory
            .appendingPathComponent("trials/\(trial.fixtureID)#\(trial.trialIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: trialDirectory, withIntermediateDirectories: true)
        try String(finalBody.utf8).write(
            to: trialDirectory.appendingPathComponent("final-body.md"),
            atomically: true, encoding: .utf8)
        try String(seededBody.utf8).write(
            to: trialDirectory.appendingPathComponent("seeded-body.md"),
            atomically: true, encoding: .utf8)
        var transcriptPath: String?
        if let scratch = await MainActor.run(body: { launcher.lastScratchDirectory }) {
            let target = trialDirectory.appendingPathComponent("transcript", isDirectory: true)
            // Best-effort transcript copy: a scratch that vanished (run
            // cleanup) must not lose the trial's other evidence — the
            // record still carries the score, oracle, and audit detail.
            // swiftlint:disable:next silent_try_optional
            try? FileManager.default.copyItem(at: scratch, to: target)
            transcriptPath = target.path
        }
        // The run outcome's audit detail + the oracle + score, as JSON.
        let detail = """
            runStatus: \(String(describing: outcome.status))
            detail: \(outcome.detail)
            authority: \(outcome.authority.map { $0.auditLabels } ?? "none")
            oracleAccepted: \(oracle.accepted)
            oracleRejections: \(oracle.rejections.map { String(describing: $0) }.joined(separator: "; "))
            scorePassed: \(score.passed)
            scoreFailures: \(score.failureReasons.joined(separator: "; "))
            """
        try String(detail.utf8).write(
            to: trialDirectory.appendingPathComponent("outcome.txt"),
            atomically: true, encoding: .utf8)

        return LintLiveTrialRecord(
            fixtureID: trial.fixtureID,
            trialIndex: trial.trialIndex,
            isIdempotencePair: trial.isIdempotencePair,
            wikiID: wikiID.rawValue,
            startedAt: startedAt,
            finishedAt: Date(),
            authorityTier: outcome.authority.map { $0.tier.rawValue } ?? "none",
            authorityReason: outcome.authority?.reason,
            runStatus: String(describing: outcome.status),
            runDetail: outcome.detail,
            appliedClasses: reconstructed.repairedClasses.sorted(),
            hits: score.hits.sorted(),
            oracleAccepted: oracle.accepted,
            oracleRejections: oracle.rejections.map { String(describing: $0) },
            scorePassed: score.passed,
            scoreFailures: score.failureReasons,
            idempotenceWrites: idempotenceWrites,
            rateLimitRetries: 0,
            seededBodySHA256: Self.sha256(seededBody),
            finalBodySHA256: Self.sha256(finalBody),
            transcriptDirectory: transcriptPath,
            error: nil)
    }

    static func failedRecord(
        trial: LintLiveTrialPlan, error: Error, startedAt: Date
    ) -> LintLiveTrialRecord {
        LintLiveTrialRecord(
            fixtureID: trial.fixtureID, trialIndex: trial.trialIndex,
            isIdempotencePair: trial.isIdempotencePair, wikiID: "",
            startedAt: startedAt, finishedAt: Date(),
            authorityTier: "none", authorityReason: nil,
            runStatus: "failed", runDetail: error.localizedDescription,
            appliedClasses: [], hits: [], oracleAccepted: false, oracleRejections: [],
            scorePassed: false, scoreFailures: [], idempotenceWrites: nil,
            rateLimitRetries: 0, seededBodySHA256: "", finalBodySHA256: "",
            transcriptDirectory: nil, error: error.localizedDescription)
    }

    /// Server-observed change regions + host-observed class outcomes: a
    /// seeded defect whose evidence text no longer appears in the final
    /// bytes was repaired; one still present was not.
    ///
    /// Hunk reconstruction is DECLARATION-ANCHORED first: when the fixture
    /// declares exact repairs and applying them (each consumed once, at
    /// their first non-overlapping occurrence) reproduces the observed new
    /// bytes from the seeded bytes, those ARE the hunks the write applied.
    /// Otherwise the change region is reconstructed by prefix/suffix trim —
    /// the same server-observed definition production verification uses —
    /// attributed by declaration or seed evidence, and an edit matching
    /// neither stays unattributable (the oracle rejects it as an undeclared
    /// repair — the honest verdict for it).
    /// Public: the deterministic tests exercise this attribution directly.
    public static func observedHunks(
        before: String, after: String, fixture: LintEvalFixture
    ) -> (hunks: [(hunk: PagePatchHunk, defectClass: LintDefectClass)],
          repairedClasses: Set<String>,
          unresolvedClasses: Set<String>,
          confirmedClasses: Set<String>) {
        var repaired: Set<String> = []
        var unresolved: Set<String> = []
        for seed in fixture.seededDefects {
            if seed.evidence.isEmpty || !after.contains(seed.evidence) {
                repaired.insert(seed.defectClass)
            } else {
                unresolved.insert(seed.defectClass)
            }
        }
        if let declared = declaredHunks(before: before, after: after, fixture: fixture) {
            return (declared, repaired, unresolved, [])
        }
        return (regionHunks(before: before, after: after, fixture: fixture),
                repaired, unresolved, [])
    }

    /// The hunks the fixture's exact declarations produce, when applying
    /// them (in order, each consumed once, at their first non-overlapping
    /// occurrence in the seeded bytes) reproduces the observed new bytes
    /// EXACTLY. Nil when they do not — the write did something else.
    static func declaredHunks(
        before: String, after: String, fixture: LintEvalFixture
    ) -> [(hunk: PagePatchHunk, defectClass: LintDefectClass)]? {
        let originalBytes = Array(before.utf8)
        var hunks: [(hunk: PagePatchHunk, defectClass: LintDefectClass)] = []
        var cursor = 0
        for (index, declaration) in fixture.allowedRepairs.enumerated() {
            guard let newText = declaration.newText else { return nil }
            let oldBytes = Array(declaration.oldText.utf8)
            // First non-overlapping occurrence at or after the cursor.
            var matchStart: Int?
            if oldBytes.isEmpty {
                matchStart = cursor
            } else {
                var position = cursor
                while position + oldBytes.count <= originalBytes.count {
                    if Array(originalBytes[position..<position + oldBytes.count]) == oldBytes {
                        matchStart = position
                        break
                    }
                    position += 1
                }
            }
            guard let start = matchStart else { return nil }
            hunks.append((
                PagePatchHunk(
                    startByte: start, endByte: start + oldBytes.count,
                    oldText: declaration.oldText, newText: newText,
                    reason: "fixture-declared repair \(index)"),
                LintDefectClass(rawValue: declaration.defectClass) ?? .wholeBodyFenceWrap))
            cursor = start + oldBytes.count
        }
        guard LintDiffOracle.apply(hunks: hunks.map(\.hunk), to: before) == after else {
            return nil
        }
        return hunks
    }

    /// The region-reconstruction fallback (declaration match failed): one
    /// change region from prefix/suffix trim, attributed by declaration
    /// (old/new text match), else seed evidence, else the fence-wrap class.
    /// The oracle then judges the reconstructed hunks and rejects anything
    /// unattributable.
    static func regionHunks(
        before: String, after: String, fixture: LintEvalFixture
    ) -> [(hunk: PagePatchHunk, defectClass: LintDefectClass)] {
        let beforeBytes = Array(before.utf8)
        let afterBytes = Array(after.utf8)
        var consumedDeclarations: Set<Int> = []
        var hunks: [(hunk: PagePatchHunk, defectClass: LintDefectClass)] = []
        for region in observedRegions(before: before, after: after) {
            let oldText = String(decoding: beforeBytes[region.old], as: UTF8.self)
            let newText = String(decoding: afterBytes[region.new], as: UTF8.self)
            // Attribution: the first unconsumed declaration matching the
            // exact (old, new) pair; else a seeded class whose evidence the
            // region covers; else the fence-wrap class (the oracle then
            // rejects the hunk as an undeclared repair — the honest verdict
            // for an unattributable edit).
            let attributed: LintDefectClass = fixture.allowedRepairs.indices
                .first { index -> Bool in
                    guard consumedDeclarations.contains(index) == false else { return false }
                    let declaration = fixture.allowedRepairs[index]
                    return declaration.oldText == oldText && declaration.newText == newText
                }
                .map { declarationIndex -> LintDefectClass in
                    consumedDeclarations.insert(declarationIndex)
                    guard let matched = LintDefectClass(
                        rawValue: fixture.allowedRepairs[declarationIndex].defectClass) else {
                        return .wholeBodyFenceWrap
                    }
                    return matched
                }
                ?? fixture.seededDefects
                    .first { seed in seed.evidence.contains(oldText) }
                    .flatMap { LintDefectClass(rawValue: $0.defectClass) }
                ?? .wholeBodyFenceWrap
            hunks.append((
                PagePatchHunk(
                    startByte: region.old.lowerBound, endByte: region.old.upperBound,
                    oldText: oldText, newText: newText,
                    reason: "observed change region (store bytes)"),
                attributed))
        }
        return hunks
    }

    public struct ObservedRegion: Equatable, Sendable {
        public let old: Range<Int>
        public let new: Range<Int>

        public init(old: Range<Int>, new: Range<Int>) {
            self.old = old
            self.new = new
        }
    }

    /// Byte ranges where `after` differs from `before` (common prefix/
    /// suffix trim) — the store-observed change region, in BOTH
    /// coordinate spaces. Public for the deterministic tests.
    public static func observedRegions(before: String, after: String) -> [ObservedRegion] {
        let a = Array(before.utf8)
        let b = Array(after.utf8)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let oldEnd = a.count - suffix
        let newEnd = b.count - suffix
        guard prefix < oldEnd || prefix < newEnd else { return [] }
        return [ObservedRegion(old: prefix..<oldEnd, new: prefix..<newEnd)]
    }

    static func sha256(_ text: String) -> String {
        RendererSHA256.digest(Data(text.utf8)).hex
    }

    /// Rate-limit classification over the failure text (the launcher reports
    /// provider failures through preflight/turn-failure strings).
    static func isRateLimit(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        let markers = ["rate limit", "rate_limit", "429", "too many requests",
                       "quota exceeded", "overloaded", "temporarily unavailable"]
        return markers.contains { text.contains($0) }
    }

    // MARK: Report persistence

    func persist(
        records: [LintLiveTrialRecord],
        evaluated: LintEvaluatedConfiguration,
        manifest: LintEvalFixtureManifest,
        trials: [LintLiveTrialPlan],
        start: ContinuousClock.Instant,
        clock: ContinuousClock,
        retriesTotal: Int,
        abortedEarly: Bool,
        abortReason: String?
    ) throws {
        _ = try finalize(
            records: records, evaluated: evaluated, manifest: manifest, trials: trials,
            start: start, clock: clock, retriesTotal: retriesTotal,
            abortedEarly: abortedEarly, abortReason: abortReason)
    }

    func finalize(
        records: [LintLiveTrialRecord],
        evaluated: LintEvaluatedConfiguration,
        manifest: LintEvalFixtureManifest,
        trials: [LintLiveTrialPlan],
        start: ContinuousClock.Instant,
        clock: ContinuousClock,
        retriesTotal: Int,
        abortedEarly: Bool,
        abortReason: String?
    ) throws -> LintLiveGateReport {
        let finishedAt = Date()
        let consumed = clock.now - start
        let (verdict, reasons) = LintLiveGateReport.verdict(
            records: records, plannedTrials: trials.count,
            bailTrials: configuration.bailTrials, groupRuns: configuration.groupRuns,
            manifest: manifest, abortedEarly: abortedEarly)
        var runStartedAt = finishedAt
        if records.first?.startedAt != nil {
            runStartedAt = records.map(\.startedAt).min() ?? finishedAt
        }
        var groupSummaries: [LintLiveGateReport.GroupSummary] = []
        var seenFixtures: Set<String> = []
        for fixtureID in records.map(\.fixtureID) where seenFixtures.insert(fixtureID).inserted {
            let group = records.filter { $0.fixtureID == fixtureID }
            groupSummaries.append(LintLiveGateReport.GroupSummary(
                fixtureID: fixtureID, trials: group.count,
                passed: group.filter(\.passed).count,
                failed: group.filter { !$0.passed }.count))
        }
        var classLines: [String: (seeded: Int, hits: Int, falseConfirmed: Int)] = [:]
        for fixture in manifest.tuning + manifest.heldOut {
            for seed in fixture.seededDefects {
                var entry = classLines[seed.defectClass] ?? (0, 0, 0)
                entry.seeded += 1
                classLines[seed.defectClass] = entry
            }
        }
        for record in records {
            for unit in record.hits {
                let cls = unit.split(separator: "#").first.map(String.init) ?? unit
                var entry = classLines[cls] ?? (0, 0, 0)
                entry.hits += 1
                classLines[cls] = entry
            }
            for failure in record.scoreFailures
            where failure.hasPrefix("false confirmed defects:") {
                let classes = failure
                    .replacingOccurrences(of: "false confirmed defects:", with: "")
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for cls in classes {
                    var entry = classLines[cls] ?? (0, 0, 0)
                    entry.falseConfirmed += 1
                    classLines[cls] = entry
                }
            }
        }
        let report = LintLiveGateReport(
            metadata: LintLiveGateReport.RunMetadata(
                runKind: "live",
                startedAt: runStartedAt,
                finishedAt: finishedAt,
                provider: evaluated.providerID,
                providerLabel: evaluated.providerLabel,
                model: evaluated.modelID,
                modelLabel: evaluated.modelLabel,
                advertisedRevision: evaluated.modelRevision,
                configuredEffort: evaluated.effort,
                effectiveEffort: evaluated.effort,
                promptSHA256: evaluated.components.promptSHA256,
                detectorRevision: evaluated.components.detectorRevision,
                fixtureDigest: evaluated.components.fixtureDigest,
                acceptanceKeySHA256: LintAcceptanceKey.digest(evaluated.components),
                evalAppGroupID: configuration.evalAppGroupID),
            plannedTrials: trials.count,
            executedTrials: records.count,
            trials: records,
            groups: groupSummaries,
            classScores: classLines
                .map { cls, counts in
                    LintLiveGateReport.ClassScoreLine(
                        defectClass: cls, seeded: counts.seeded,
                        hits: counts.hits, falseConfirmed: counts.falseConfirmed)
                }
                .sorted { $0.defectClass < $1.defectClass },
            wallClockConsumedSeconds: Double(consumed.components.seconds)
                + Double(consumed.components.attoseconds) / 1e18,
            rateLimitRetries: retriesTotal,
            abortedEarly: abortedEarly,
            abortReason: abortReason,
            verdict: verdict,
            blockingReasons: reasons,
            humanRubricSections: "PENDING OPERATOR")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(
            to: configuration.outputDirectory.appendingPathComponent("gate-report.json"),
            options: .atomic)
        try Self.renderMarkdown(report)
            .write(
                to: configuration.outputDirectory.appendingPathComponent("gate-report.md"),
                atomically: true, encoding: .utf8)
        return report
    }

    static func renderMarkdown(_ report: LintLiveGateReport) -> String {
        var lines: [String] = []
        lines.append("# Wiki lint live gate report")
        lines.append("")
        lines.append("- Run kind: \(report.metadata.runKind)")
        lines.append("- Configuration: \(report.metadata.provider) / \(report.metadata.modelLabel) @ \(report.metadata.effectiveEffort) (configured: \(report.metadata.configuredEffort))")
        lines.append("- Acceptance key: \(report.metadata.acceptanceKeySHA256)")
        lines.append("- Pipeline: prompt \(report.metadata.promptSHA256.prefix(12))…, detector \(report.metadata.detectorRevision), fixtures \(report.metadata.fixtureDigest.prefix(12))…")
        lines.append("- Trials: \(report.executedTrials)/\(report.plannedTrials) executed")
        lines.append("- Wall clock: \(Int(report.wallClockConsumedSeconds))s; rate-limit retries: \(report.rateLimitRetries)")
        lines.append("")
        lines.append("## Verdict: \(report.verdict)")
        for reason in report.blockingReasons { lines.append("- \(reason)") }
        if report.blockingReasons.isEmpty { lines.append("- all mechanical gates met") }
        lines.append("")
        lines.append("## Groups")
        lines.append("")
        lines.append("| Fixture | Trials | Passed | Failed |")
        lines.append("| --- | --- | --- | --- |")
        for group in report.groups {
            lines.append("| \(group.fixtureID) | \(group.trials) | \(group.passed) | \(group.failed) |")
        }
        lines.append("")
        lines.append("## Per-class scores")
        lines.append("")
        lines.append("| Class | Seeded | Hits | False confirmed | Recall |")
        lines.append("| --- | --- | --- | --- | --- |")
        for line in report.classScores {
            lines.append("| \(line.defectClass) | \(line.seeded) | \(line.hits) | \(line.falseConfirmed) | \(String(format: "%.2f", line.recall)) |")
        }
        lines.append("")
        lines.append("## Human rubric judgment")
        lines.append("")
        lines.append("PENDING OPERATOR — the operator reviews this report before any approval row ships.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func validateOutputIsolation() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let tmp = cwd.appendingPathComponent("tmp", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let output = configuration.outputDirectory.standardizedFileURL
            .resolvingSymlinksInPath()
        guard output.path.hasPrefix(tmp.path + "/") else {
            throw LintLiveGateError.outputDirectoryNotIsolated(
                "\(output.path) is not under \(tmp.path)/")
        }
        let groupContainers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .standardizedFileURL.path
        if output.path.hasPrefix(groupContainers + "/") {
            throw LintLiveGateError.outputDirectoryNotIsolated(
                "\(output.path) is inside Group Containers")
        }
    }
}

// MARK: - Construction factories

/// The driver's construction seams. The CORDIS boundary rules reserve
/// `GRDBWikiStore`/`WikiStoreModel`/`AgentLauncher` construction for
/// plugin/factory/host code — the `wikid` lint-eval-driver HOST owns these
/// constructions and injects them here, so the driver engine itself stays on
/// the right side of the boundary.
public struct LintLiveGateFactories: Sendable {
    /// The on-disk disposable store constructor (the daemon host owns
    /// `GRDBWikiStore` construction).
    public let buildStore: @Sendable (URL) throws -> GRDBWikiStore
    /// The main-actor store model wrapper over a store.
    public let buildStoreModel: @MainActor @Sendable (any WikiStore) -> WikiStoreModel
    /// One per-trial launcher: production composition with the scoped-run
    /// lease manager, the evaluated effort override, and the disposable
    /// quota state installed. Arguments: provider services, lease manager,
    /// effort value id, quota state URL.
    public let buildLauncher: @MainActor @Sendable (
        any AgentProviderServices, any AgentScopedRunLeaseManaging, String, URL
    ) -> AgentLauncher

    public init(
        buildStore: @escaping @Sendable (URL) throws -> GRDBWikiStore,
        buildStoreModel: @escaping @MainActor @Sendable (any WikiStore) -> WikiStoreModel,
        buildLauncher: @escaping @MainActor @Sendable (
            any AgentProviderServices, any AgentScopedRunLeaseManaging, String, URL
        ) -> AgentLauncher
    ) {
        self.buildStore = buildStore
        self.buildStoreModel = buildStoreModel
        self.buildLauncher = buildLauncher
    }
}

// MARK: - Substrate handle

/// The booted eval daemon substrate, injected into the driver. The driver
/// never constructs the daemon components itself — the host (the runner
/// executable, which links the daemon module) boots the substrate over the
/// eval container and hands the driver the scoped-run lease manager every
/// lint launch requires, plus its stop hook.
public struct LintEvalSubstrateHandle: Sendable {
    public let leaseManager: any AgentScopedRunLeaseManaging
    public let stop: @Sendable () -> Void

    public init(leaseManager: any AgentScopedRunLeaseManaging, stop: @escaping @Sendable () -> Void) {
        self.leaseManager = leaseManager
        self.stop = stop
    }
}

// MARK: - Change signaling

/// The driver's change signaler: the eval container has no File Provider
/// projection, so there is nothing to signal.
/// Sendable invariant: the class holds NO mutable state (both members are
/// constants/nil), so any instance is safely shareable.
// swiftlint:disable:next unchecked_sendable
final class LintEvalChangeSignaler: ChangeSignaler, @unchecked Sendable {
    func signalChange() async {}
    var path: String? { nil }
}

#endif
