import Foundation
import WikiFSCore
import WikiFSTypes

#if canImport(WikiFSEngine) && os(macOS)
import WikiFSEngine

/// Why a live evaluation could not run or must stop.
public enum LiveEvaluationError: Error, Equatable, Sendable {
    /// The explicit provider-config directory holds no enabled provider and
    /// no usable `agent-providers.json`. The harness never seeds or discovers
    /// providers on its own — a missing configuration is a stop, not a
    /// fallback.
    case providerConfigurationUnavailable(String)
    /// A scenario fixture failed self-validation.
    case fixtureInvalid([String])
    /// The requested output location would break isolation.
    case outputDirectoryNotIsolated(String)
    /// The launcher run itself failed (preflight error, bad exit).
    case ingestionRunFailed(String)

    public var localizedDescription: String {
        switch self {
        case .providerConfigurationUnavailable(let detail):
            "provider configuration unavailable: \(detail)"
        case .fixtureInvalid(let problems):
            "scenario fixture invalid: \(problems.joined(separator: "; "))"
        case .outputDirectoryNotIsolated(let detail):
            "output directory must live outside ~/Library/Group Containers: \(detail)"
        case .ingestionRunFailed(let detail):
            "ingestion run failed: \(detail)"
        }
    }
}

/// Configuration for one live evaluation run.
public struct LiveEvaluationConfiguration: Sendable {
    /// The operator's REAL provider-config directory (the App Group
    /// container). Read-only: the harness loads
    /// `AgentProvidersConfig.loadOrSeed(from:discover:)` with discovery
    /// DISABLED, so nothing is seeded or discovered, and credentials stay in
    /// the Keychain (read at spawn time by the production credential store,
    /// never copied).
    public var providerConfigDirectory: URL
    /// Where all disposable artifacts land (wiki databases, state markdown,
    /// reports). Must live OUTSIDE `~/Library/Group Containers` — enforced at
    /// start. Use the project's gitignored `tmp/` directory.
    public var outputDirectory: URL
    public var budget: EvaluationBudget
    public var scenarioIDs: [EvaluationScenarioID]
    /// Keep the disposable fixture directories after the run (debugging).
    public var keepFixtureDirectories: Bool

    public init(
        providerConfigDirectory: URL,
        outputDirectory: URL,
        budget: EvaluationBudget = EvaluationBudget(),
        scenarioIDs: [EvaluationScenarioID] = EvaluationScenarioID.allCases,
        keepFixtureDirectories: Bool = false
    ) {
        self.providerConfigDirectory = providerConfigDirectory
        self.outputDirectory = outputDirectory
        self.budget = budget
        self.scenarioIDs = scenarioIDs
        self.keepFixtureDirectories = keepFixtureDirectories
    }
}

/// The live semantic evaluation harness (plan Phase 5.3-5.4).
///
/// What makes a run LIVE: the operator's REAL configured provider (via the
/// production `AgentProviderRuntimeFactory` composition), the REAL
/// `AgentLauncher` multi-phase ingest path — launched with the REAL
/// agent-loop service (`AgentLoopPlugin` activation over StorePlugin →
/// SessionsPlugin → ChatsPersistencePlugin, booted per leg against the leg's
/// disposable database through the engine's approved
/// `AgentLoopRuntimeFactory` composition), so every agent turn traverses the
/// production loop
/// (turn-started → pre-step waterfall → request waterfall → backend stream →
/// step-completed → turn-completed) exactly as the daemon profile runs it —
/// REAL ingestion of source A then source B through the production staging
/// seam, and page writes performed by the real agent through `wikictl` —
/// targeted at a DISPOSABLE fixture database under the output directory via
/// the launcher's explicit-database override and `wikictl --database-path`.
/// Nothing in the operator's App Group container is written: no registry row,
/// no group-container directory, no provider-config change, and quota state
/// is redirected to a fixture file.
///
/// Complete run evidence is retained per leg and per batch: each batch's
/// state markdown (the prompt context rendered before its run), each agent
/// turn's loop traversal, and each run's artifacts (log, wire trace, usage).
///
/// Results are labeled with their true ``EvaluationRunKind``; this harness is
/// the ONLY producer of `.live` records.
public struct LiveEvaluationHarness: Sendable {

    private let configuration: LiveEvaluationConfiguration
    private let evaluator = StructuralEvaluator()
    private let recorder = WikiObservationRecorder()
    private let reportWriter = EvaluationReportWriter()

    public init(configuration: LiveEvaluationConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Entry

    public func run() async throws -> EvaluationResultsFile {
        try validateOutputIsolation()

        let scenarios = configuration.scenarioIDs
            .compactMap { EvaluationFixtures.scenario(id: $0) }
        for scenario in scenarios where !scenario.validationProblems.isEmpty {
            throw LiveEvaluationError.fixtureInvalid(scenario.validationProblems)
        }
        guard !scenarios.isEmpty else {
            throw LiveEvaluationError.fixtureInvalid(["no scenarios selected"])
        }

        // Provider configuration: explicit directory, read-only, discovery
        // disabled. An empty configuration is a hard stop.
        let providerConfig = AgentProvidersConfig.loadOrSeed(
            from: configuration.providerConfigDirectory,
            discover: { [] })
        guard !providerConfig.enabledProviders.isEmpty else {
            throw LiveEvaluationError.providerConfigurationUnavailable(
                "no enabled provider in \(configuration.providerConfigDirectory.path) — configure one in the app's Settings → Providers first")
        }
        let provider = providerConfig.selectedProvider()

        try FileManager.default.createDirectory(
            at: configuration.outputDirectory,
            withIntermediateDirectories: true)

        // The production provider-runtime composition, mirrored from
        // `ProductionPluginCatalogs` (daemon profile): same command
        // resolution, same credential stores, same permission default.
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
            // The factory handle owns process-level backend resources; retire
            // them after the run. Fire-and-forget with a note: a hang here
            // must not lose the already-written reports.
            let handle = runtimeHandle
            Task {
                do { try await handle.dispose() }
                catch { DebugLog.agent("eval harness: provider runtime dispose failed: \(error.localizedDescription)") }
            }
        }

        var records: [ScenarioResultRecord] = []
        for scenario in scenarios {
            let record = try await runScenario(
                scenario,
                providerID: provider.id.rawValue,
                providerLabel: provider.label,
                modelID: providerConfig.selectedModelId(forProvider: provider.id)?.rawValue,
                services: runtimeHandle.services)
            records.append(record)
            try reportWriter.writeMarkdownReport(
                scenario: scenario,
                record: record,
                to: configuration.outputDirectory
                    .appendingPathComponent("\(scenario.id.rawValue).report.md"))
        }

        let results = EvaluationResultsFile(
            runKind: .live,
            generatedAt: Date(),
            results: records)
        try reportWriter.writeResultsJSON(
            results,
            to: configuration.outputDirectory.appendingPathComponent("results.json"))
        try writeSummary(records).write(
            to: configuration.outputDirectory.appendingPathComponent("summary.md"),
            atomically: true, encoding: .utf8)
        return results
    }

    // MARK: - One scenario

    private func runScenario(
        _ scenario: EvaluationScenario,
        providerID: String,
        providerLabel: String,
        modelID: String?,
        services: any AgentProviderServices
    ) async throws -> ScenarioResultRecord {
        let startedAt = Date()
        let scenarioDirectory = configuration.outputDirectory
            .appendingPathComponent(scenario.id.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(
            at: scenarioDirectory, withIntermediateDirectories: true)

        let tracker = UsageBudgetTracker(budget: configuration.budget)
        let budgetGate = LiveUsageBudgetGate(budget: configuration.budget)
        let evidenceLedger = ScenarioEvidenceLedger()
        let agentBox = CurrentAgentBox()
        defer { agentBox.set(nil) }

        do {
            let outcome = try await BoundedRunner.withBudget(
                configuration.budget,
                onTimeout: { await agentBox.stopIfPresent() }) {
                try await self.runLegs(
                    scenario: scenario,
                    scenarioDirectory: scenarioDirectory,
                    services: services,
                    tracker: tracker,
                    budgetGate: budgetGate,
                    evidenceLedger: evidenceLedger,
                    agentBox: agentBox)
            }
            let usage = await tracker.current()
            // Complete run evidence: every leg's batches with their prompts,
            // loop traversals, and artifacts — not only the last state.
            let legsEvidence = await evidenceLedger.snapshot()
            let metadata = ScenarioRunMetadata(
                runKind: .live,
                scenarioID: scenario.id,
                startedAt: startedAt,
                finishedAt: Date(),
                wikiID: outcome.finalWikiID,
                databasePath: outcome.finalDatabasePath,
                providerID: providerID,
                providerLabel: providerLabel,
                modelID: modelID,
                usage: UsageSnapshot(totalTokens: usage.totalTokens, cost: usage.cost),
                logFileURL: outcome.logFileURL?.path,
                debugFolderURL: outcome.debugFolderURL?.path,
                stateMarkdown: legsEvidence.last?.batches.last?.stateMarkdown ?? "",
                error: nil,
                strategyDelivered: true,
                legs: legsEvidence)
            let record = ScenarioResultRecord(
                metadata: metadata,
                evaluation: evaluator.evaluate(scenario: scenario, input: outcome.input))
            cleanupFixtures(scenarioDirectory)
            return record
        } catch {
            // A failed/bounded scenario still produces a record — with the
            // error stated and a canned-empty evaluation that reports every
            // check as failed with the run error, so results.json never
            // silently omits a scenario.
            let failedOutcomes = scenario.checks.map { check in
                CheckOutcome(
                    id: checkIdentifier(check),
                    passed: false,
                    detail: "run did not complete: \(error.localizedDescription)")
            }
            // Partial run evidence: every leg/batch that DID complete before
            // the failure, so results.json shows what actually ran.
            let legsEvidence = await evidenceLedger.snapshot()
            let metadata = ScenarioRunMetadata(
                runKind: .live,
                scenarioID: scenario.id,
                startedAt: startedAt,
                finishedAt: Date(),
                wikiID: "",
                databasePath: scenarioDirectory.path,
                providerID: providerID,
                providerLabel: providerLabel,
                modelID: modelID,
                usage: nil,
                logFileURL: nil,
                debugFolderURL: nil,
                stateMarkdown: legsEvidence.last?.batches.last?.stateMarkdown ?? "",
                error: error.localizedDescription,
                strategyDelivered: false,
                strategyDeliveryNote: "run failed before evaluation",
                legs: legsEvidence)
            return ScenarioResultRecord(
                metadata: metadata,
                evaluation: ScenarioEvaluation(
                    scenarioID: scenario.id, outcomes: failedOutcomes))
        }
    }

    private struct LegsOutcome {
        var input: EvaluationInput
        var finalWikiID: String
        var finalDatabasePath: String
        var logFileURL: URL?
        var debugFolderURL: URL?
    }

    /// Run the scenario's legs. Two-source scenarios run both batches into
    /// ONE wiki (A, ingest, B, ingest). The documentation-strategy scenario
    /// runs its single batch twice into TWO fresh wikis — one per strategy.
    private func runLegs(
        scenario: EvaluationScenario,
        scenarioDirectory: URL,
        services: any AgentProviderServices,
        tracker: UsageBudgetTracker,
        budgetGate: LiveUsageBudgetGate,
        evidenceLedger: ScenarioEvidenceLedger,
        agentBox: CurrentAgentBox
    ) async throws -> LegsOutcome {
        if scenario.id == .sameEvidenceDifferentDocumentationStrategy {
            guard let secondStrategy = scenario.secondLegStrategy else {
                throw LiveEvaluationError.fixtureInvalid(
                    ["documentation-strategy scenario requires a second leg strategy"])
            }
            let leg1 = try await runOneLeg(
                label: "leg1",
                scenarioDirectory: scenarioDirectory,
                strategy: scenario.strategy,
                batches: scenario.batches,
                services: services,
                tracker: tracker,
                budgetGate: budgetGate,
                evidenceLedger: evidenceLedger,
                agentBox: agentBox)
            let leg2 = try await runOneLeg(
                label: "leg2",
                scenarioDirectory: scenarioDirectory,
                strategy: secondStrategy,
                batches: scenario.batches,
                services: services,
                tracker: tracker,
                budgetGate: budgetGate,
                evidenceLedger: evidenceLedger,
                agentBox: agentBox)
            return LegsOutcome(
                input: EvaluationInput(before: leg1.observation, after: leg2.observation),
                finalWikiID: leg2.wikiID.rawValue,
                finalDatabasePath: leg2.databaseURL.path,
                logFileURL: leg2.logFileURL,
                debugFolderURL: leg2.debugFolderURL)
        }

        let leg = try await runOneLeg(
            label: "run",
            scenarioDirectory: scenarioDirectory,
            strategy: scenario.strategy,
            batches: scenario.batches,
            services: services,
            tracker: tracker,
            budgetGate: budgetGate,
            evidenceLedger: evidenceLedger,
            agentBox: agentBox)
        return LegsOutcome(
            input: leg.input,
            finalWikiID: leg.wikiID.rawValue,
            finalDatabasePath: leg.databaseURL.path,
            logFileURL: leg.logFileURL,
            debugFolderURL: leg.debugFolderURL)
    }

    private struct LegOutcome {
        var observation: WikiObservation
        var input: EvaluationInput
        var wikiID: WikiID
        var databaseURL: URL
        var logFileURL: URL?
        var debugFolderURL: URL?
    }

    /// One leg: fresh wiki, save the strategy through the REAL store seam,
    /// boot the production agent-loop composition against the leg's disposable
    /// database, import each batch through REAL ingestion (every agent turn
    /// traversing the real loop), observe after each batch.
    private func runOneLeg(
        label: String,
        scenarioDirectory: URL,
        strategy: EvaluationStrategyFixture,
        batches: [[EvaluationSourceFixture]],
        services: any AgentProviderServices,
        tracker: UsageBudgetTracker,
        budgetGate: LiveUsageBudgetGate,
        evidenceLedger: ScenarioEvidenceLedger,
        agentBox: CurrentAgentBox
    ) async throws -> LegOutcome {
        guard !batches.isEmpty else {
            throw LiveEvaluationError.fixtureInvalid(["leg \(label) has no batches"])
        }

        // Fresh disposable wiki: <scenarioDirectory>/<label>/<ulid>.sqlite.
        let legDirectory = scenarioDirectory.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(
            at: legDirectory, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: "eval-\(label)")
        let databaseURL = legDirectory
            .appendingPathComponent("\(descriptor.id.rawValue).sqlite", isDirectory: false)
        _ = try StoreBootstrap().createAndSeed(databaseURL: databaseURL)

        // Production agent-loop runtime: the engine's approved composition
        // boots the same plugin stack the daemon profile boots (StorePlugin
        // on this leg's disposable database → SessionsPlugin →
        // ChatsPersistencePlugin → AgentLoopPlugin), plus this harness's
        // observation-only trace callbacks. The launcher factory below hands
        // out the REAL `AgentLoopPlugin` service, not a stand-in — pre-step
        // gates, request waterfalls, and turn lifecycle events all traverse
        // the production path. See Tests/WikiFSTests/AgentLoopPluginBootTests.swift
        // for the same composition in test form.
        let loopTrace = AgentLoopTraceRecorder()
        let booted: AgentLoopRuntimeHandle
        do {
            booted = try await AgentLoopRuntimeFactory.boot(
                databaseURL: databaseURL,
                wikiID: descriptor.id,
                trace: AgentLoopTraceObserver(
                    onTurnStarted: { event in await loopTrace.recordStart(event) },
                    onStepCompleted: { event in await loopTrace.recordStep(event) },
                    onTurnCompleted: { event in await loopTrace.recordFinish(event) }))
        } catch {
            throw LiveEvaluationError.ingestionRunFailed(
                "agent-loop composition failed to activate on leg \(label): \(error.localizedDescription)")
        }
        // The composed store on this leg's disposable database: strategy
        // saves, source staging, and observations all use the REAL
        // persistence seam (Phase 1). A fresh wiki has no strategy row, so
        // the CAS expectation is nil.
        let store = booted.store
        do {
            try store.saveWikiStrategy(
                name: strategy.name,
                instructions: strategy.instructions,
                expectedRevision: nil)
            guard try store.getWikiStrategy() != nil else {
                throw LiveEvaluationError.ingestionRunFailed(
                    "strategy save did not commit on leg \(label)")
            }
        } catch {
            await Self.shutdownLoopComposition(booted, after: "strategy save on leg \(label)")
            throw error
        }
        await evidenceLedger.beginLeg(EvaluationLegRecord(
            label: label,
            strategyName: strategy.name,
            wikiID: descriptor.id.rawValue,
            databasePath: databaseURL.path))

        do {
            var observations: [WikiObservation] = []
            var lastArtifacts: (log: URL?, debug: URL?) = (nil, nil)
            // The stable fixture mapping for this leg's wiki: observed
            // SourceID → fixture filename stem. Accumulated across batches so
            // a later batch's capture still resolves the EARLIER batch's
            // sources by typed id (listSources returns every source, but only
            // this map knows which stem produced which id).
            var fixtureKeysBySourceID: [SourceID: String] = [:]
            for (batchIndex, batch) in batches.enumerated() {
                var sourceIDs: [SourceID] = []
                for fixture in batch {
                    let summary = try store.addSource(
                        filename: fixture.filename,
                        data: Data(fixture.markdown.utf8))
                    sourceIDs.append(summary.id)
                    fixtureKeysBySourceID[summary.id] = (fixture.filename as NSString).deletingPathExtension
                }
                let turnsBeforeBatch = await loopTrace.count()
                budgetGate.beginLegUsage(await tracker.current())
                let artifacts = try await ingest(
                    store: store,
                    wikiID: descriptor.id,
                    databaseURL: databaseURL,
                    sourceIDs: sourceIDs,
                    services: services,
                    launcherFactory: booted.launcherFactory,
                    budgetGate: budgetGate,
                    agentBox: agentBox)
                lastArtifacts = (log: artifacts.log, debug: artifacts.debug)
                // Each ingestion uses a fresh session. Add its final cumulative
                // usage once to the scenario total, rather than replacing it.
                if let usage = artifacts.usage {
                    try await tracker.recordCompletedRun(usage)
                }
                // Per-batch loop-traversal evidence: the turns this batch's
                // run sent through the production loop (cumulative trace
                // minus the turns earlier batches already claimed).
                let turnTraces = await loopTrace.snapshot()
                let batchTurns = turnTraces.dropFirst(turnsBeforeBatch)
                await evidenceLedger.appendBatch(EvaluationBatchRecord(
                    index: batchIndex,
                    legLabel: label,
                    sourceFilenames: batch.map(\.filename),
                    stateMarkdown: artifacts.stateMarkdown,
                    startedAt: artifacts.startedAt,
                    finishedAt: artifacts.finishedAt,
                    usage: artifacts.usage,
                    logFileURL: artifacts.log?.path,
                    debugFolderURL: artifacts.debug?.path,
                    agentLoopTurns: Array(batchTurns)))
                observations.append(try recorder.capture(
                    from: store,
                    fixtureKeysBySourceID: fixtureKeysBySourceID))
            }
            await evidenceLedger.finishLeg()

            guard let finalObservation = observations.last,
                  let firstObservation = observations.first else {
                throw LiveEvaluationError.ingestionRunFailed("no observations captured on leg \(label)")
            }
            let outcome = LegOutcome(
                observation: finalObservation,
                input: EvaluationInput(
                    before: observations.count > 1
                        ? observations[observations.count - 2]
                        : firstObservation,
                    after: finalObservation),
                wikiID: descriptor.id,
                databaseURL: databaseURL,
                logFileURL: lastArtifacts.log,
                debugFolderURL: lastArtifacts.debug)
            // Retire the composition BEFORE the leg's outcome leaves this
            // scope so its store/read-service connections close before any
            // fixture cleanup. A shutdown failure is logged, not thrown: the
            // leg's results are already complete.
            do {
                try await booted.shutdown()
            } catch {
                DebugLog.agent("eval harness: agent-loop composition shutdown after leg \(label) failed: \(error.localizedDescription)")
            }
            return outcome
        } catch {
            await Self.shutdownLoopComposition(booted, after: "failure on leg \(label)")
            throw error
        }
    }

    // MARK: - One ingestion run (mirrors the daemon provider)

    private struct IngestArtifacts {
        var usage: UsageSnapshot?
        var log: URL?
        var debug: URL?
        var stateMarkdown: String
        var startedAt: Date
        var finishedAt: Date
    }

    private func ingest(
        store: any WikiStore,
        wikiID: WikiID,
        databaseURL: URL,
        sourceIDs: [SourceID],
        services: any AgentProviderServices,
        launcherFactory: AgentLoopLauncherFactory,
        budgetGate: LiveUsageBudgetGate,
        agentBox: CurrentAgentBox
    ) async throws -> IngestArtifacts {
        let startedAt = Date()
        let stateMarkdown = try Self.renderStateMarkdown(from: store)

        // Stage exactly like the daemon provider: the store's own bytes, the
        // by-id display path, the effective name as the citation stem.
        let allSources = try store.listSources()
        var staged: [OperationRequest.StagedSource] = []
        for sourceID in sourceIDs {
            guard let summary = allSources.first(where: { $0.id == sourceID }) else {
                throw LiveEvaluationError.ingestionRunFailed(
                    "source \(sourceID.rawValue) missing before staging")
            }
            let bytes: Data
            do {
                bytes = try store.sourceContent(id: sourceID)
            } catch {
                throw LiveEvaluationError.ingestionRunFailed(
                    "source bytes unavailable for \(sourceID.rawValue): \(error.localizedDescription)")
            }
            staged.append(OperationRequest.StagedSource(
                bytes: bytes,
                ext: summary.ext,
                displayPath: "sources/by-id/\(FilenameEscaping.byIDSourceFilename(sourceID: summary.id, ext: summary.ext))",
                name: summary.effectiveName,
                sourceID: summary.id))
        }

        // Launcher with the explicit-database override + disposable quota
        // state. Constructed through the booted runtime's factory and
        // configured on the main actor like every production call site.
        let quotaStateURL = configuration.outputDirectory
            .appendingPathComponent("quota-state.json", isDirectory: false)
        let launcher = await MainActor.run { () -> AgentLauncher in
            let launcher = launcherFactory(providerServices: services)
            launcher.wikiDatabaseOverride = databaseURL
            launcher.makeQuotaFallbackCoordinator = {
                QuotaFallbackCoordinator(quotaStateURL: quotaStateURL)
            }
            return launcher
        }
        // Register this run's launcher so a budget timeout force-stops ITS
        // agent, and clear the registration when the run ends.
        agentBox.set(launcher)
        defer { agentBox.set(nil) }

        let usageBox = LatestUsageBox()
        await launcher.run(
            request: .ingest(sources: staged, stateMarkdown: stateMarkdown),
            wikiID: wikiID,
            wikiRoot: "",
            systemPrompt: SystemPrompt.defaultBody,
            wikictlDirectory: HelpersLocation.wikictlDirectory,
            ingestingSourceIDs: Set(sourceIDs),
            onEvent: nil,
            onLiveUsage: { usage in
                let snapshot = UsageSnapshot(totalTokens: usage.totalTokens, cost: usage.cost)
                usageBox.record(snapshot)
                if let limit = budgetGate.observe(snapshot) {
                    budgetGate.requestStop { await agentBox.stopIfPresent() }
                    budgetGate.recordFailure(limit)
                }
            },
            onPendingPermission: nil,
            providerLabel: nil,
            onLock: {},
            onUnlock: {})
        await launcher.awaitProviderRelease()
        if let limit = budgetGate.failure() { throw limit }

        let results = await MainActor.run {
            (
                launcher.preflightError,
                launcher.exitStatus,
                launcher.runHadTurnFailure,
                launcher.runTotalUsage,
                launcher.logFileURL,
                launcher.debugFolderURL
            )
        }
        if let preflight = results.0 {
            throw LiveEvaluationError.ingestionRunFailed(preflight)
        }
        if let status = results.1, status != 0, results.2 {
            throw LiveEvaluationError.ingestionRunFailed(
                "agent turn failed or exceeded the time ceiling (exit status \(status))")
        }

        // #1344 parity: the validated-successful run is the completion fact.
        for sourceID in sourceIDs {
            do {
                try store.markSourceIngested(id: sourceID)
            } catch {
                DebugLog.store("eval harness markSourceIngested[\(sourceID.rawValue)] failed: \(error)")
            }
        }

        let usage: UsageSnapshot?
        if let runUsage = results.3 {
            usage = UsageSnapshot(totalTokens: runUsage.totalTokens, cost: runUsage.cost)
        } else {
            usage = usageBox.latest()
        }
        return IngestArtifacts(usage: usage, log: results.4, debug: results.5, stateMarkdown: stateMarkdown, startedAt: startedAt, finishedAt: Date())
    }

    // MARK: - State markdown (mirrors the daemon provider's snapshot)

    static func renderStateMarkdown(from store: any WikiStore) throws -> String {
        let titles = (DebugLog.trying("eval listPages", operation: { try store.listPages(sortBy: .lastUpdated) })) ?? []
        let indexBody = (DebugLog.trying("eval getWikiIndex", operation: { try store.getWikiIndex() }))?.body ?? WikiIndex.defaultBody
        let logEntries = (DebugLog.trying("eval recentLogEntries", operation: { try store.recentLogEntries(limit: WikiStateSnapshot.maxLogEntries) })) ?? []
        let logLines = logEntries.map { LogRenderer.line(for: $0) }
        let bookmarks = (DebugLog.trying("eval listBookmarkNodes", operation: { try store.listBookmarkNodes() })) ?? []
        // Strategy is authority for this evaluation. Unlike optional inventory
        // context, a failed read must stop rather than silently deliver Default.
        let strategy = try store.getWikiStrategy()
        let snapshot = WikiStateSnapshot.make(
            allTitles: titles.map(\.title),
            indexBody: indexBody,
            logLines: logLines,
            bookmarkNodes: bookmarks,
            strategy: strategy)
        return snapshot.renderStateFile()
    }

    // MARK: - Validation + helpers

    private func validateOutputIsolation() throws {
        let groupContainersRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .standardizedFileURL.path
        let outputPath = configuration.outputDirectory.standardizedFileURL.path
        if outputPath == groupContainersRoot || outputPath.hasPrefix(groupContainersRoot + "/") {
            throw LiveEvaluationError.outputDirectoryNotIsolated(outputPath)
        }
    }

    private func cleanupFixtures(_ scenarioDirectory: URL) {
        guard !configuration.keepFixtureDirectories else { return }
        do {
            try FileManager.default.removeItem(at: scenarioDirectory)
        } catch {
            DebugLog.store("eval harness cleanup of \(scenarioDirectory.path) failed: \(error)")
        }
    }

    private func checkIdentifier(_ check: StructuralCheck) -> String {
        switch check {
        case .retainedFact(let title, _): "retainedFact:\(title)"
        case .unsupportedClaim(let title, _): "unsupportedClaim:\(title)"
        case .supersededInterpretation(let title, _, _, _): "supersededInterpretation:\(title)"
        case .citationsPresent(let title, _): "citationsPresent:\(title)"
        case .stablePageIdentity(let title): "stablePageIdentity:\(title)"
        case .noUnrelatedPageEdits: "noUnrelatedPageEdits"
        case .historyDepth(let title, _): "historyDepth:\(title)"
        case .provenanceIncludes(let title, _): "provenanceIncludes:\(title)"
        case .strategyShape(let title, _, _, _): "strategyShape:\(title)"
        case .differentOutputShape(let title): "differentOutputShape:\(title)"
        }
    }

    private func writeSummary(_ records: [ScenarioResultRecord]) -> String {
        var lines = [
            "# Live semantic evaluation — summary",
            "",
            "- Run kind: live (real provider, real launcher, disposable fixture databases)",
            "- Structural checks are heuristics over known fixture phrases; the per-scenario report's human rubric is the authoritative semantic review.",
            "",
            "| Scenario | Structural | Strategy delivered | Error |",
            "| --- | --- | --- | --- |",
        ]
        for record in records {
            lines.append("| \(record.metadata.scenarioID.displayName) | \(record.evaluation.passed ? "PASS" : "FAIL") | \(record.metadata.strategyDelivered ? "yes" : "NO") | \(record.metadata.error ?? "") |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private actor AgentLoopTraceRecorder {
    private var turns: [EvaluationAgentLoopTurn] = []
    private var starts: [String: (String, Int)] = [:]
    func recordStart(_ event: AgentTurnStarted) { starts[event.request.turnID.rawValue] = (event.request.chatID.rawValue, event.request.userText.count) }
    func recordStep(_ event: AgentStepCompleted) {
        let key = event.turnID.rawValue
        let start = starts[key] ?? (event.chatID.rawValue, 0)
        turns.append(EvaluationAgentLoopTurn(turnID: key, chatID: start.0, deliveredPromptCharacters: start.1, streamedEventCount: event.events.count, completed: false))
    }
    func recordFinish(_ event: AgentTurnCompleted) {
        if let index = turns.lastIndex(where: { $0.turnID == event.turnID.rawValue }) { turns[index].completed = true }
    }
    func snapshot() -> [EvaluationAgentLoopTurn] { turns }
    func count() -> Int { turns.count }
}

private actor ScenarioEvidenceLedger {
    private var legs: [EvaluationLegRecord] = []
    func beginLeg(_ leg: EvaluationLegRecord) { legs.append(leg) }
    func appendBatch(_ batch: EvaluationBatchRecord) { legs[legs.count - 1].batches.append(batch) }
    func finishLeg() {}
    func snapshot() -> [EvaluationLegRecord] { legs }
}

/// Lifecycle helper for the engine-provided agent-loop runtime
/// (`AgentLoopRuntimeFactory.boot`). The composition itself — boot,
/// service resolution, trace plugin, and profile ownership — lives behind
/// that engine facade; the harness only retires it here.
private extension LiveEvaluationHarness {
    static func shutdownLoopComposition(_ booted: AgentLoopRuntimeHandle, after reason: String) async {
        do { try await booted.shutdown() } catch { DebugLog.agent("eval harness shutdown (\(reason)) failed: \(error.localizedDescription)") }
    }
}

/// Synchronous callback gate for cumulative provider usage. Provider totals are
/// cumulative within a leg; `prior` carries completed legs into the decision.
///
/// Sendable invariant: the only mutable state (`prior`, `failureValue`,
/// `stopRequested`) is read and written while holding `lock` — every method
/// acquires it before touching state and releases it on every path. `budget`
/// is an immutable `let` of a Sendable value type. The unchecked conformance
/// is required because the backend reports usage from synchronous callbacks
/// that cannot `await` an actor.
// swiftlint:disable:next unchecked_sendable
final class LiveUsageBudgetGate: @unchecked Sendable {
    private let budget: EvaluationBudget
    private let lock = NSLock()
    private var prior = UsageSnapshot(totalTokens: 0)
    private var failureValue: EvaluationRunLimit?
    private var stopRequested = false

    init(budget: EvaluationBudget) { self.budget = budget }

    func beginLegUsage(_ usage: UsageSnapshot) {
        lock.lock(); prior = usage; failureValue = nil; stopRequested = false; lock.unlock()
    }

    func observe(_ usage: UsageSnapshot) -> EvaluationRunLimit? {
        lock.lock(); defer { lock.unlock() }
        guard failureValue == nil else { return nil }
        let sum = prior.totalTokens.addingReportingOverflow(usage.totalTokens)
        let tokens = sum.overflow ? Int.max : sum.partialValue
        if let limit = budget.maxTotalTokens, tokens > limit {
            return .tokenBudgetExceeded(limit: limit, observed: tokens)
        }
        if let limit = budget.maxCost, let cost = usage.cost {
            let combinedCost = (prior.cost ?? 0) + cost
            if combinedCost > limit {
                return .costBudgetExceeded(limit: limit, observed: combinedCost)
            }
        }
        return nil
    }

    func recordFailure(_ failure: EvaluationRunLimit) {
        lock.lock(); defer { lock.unlock() }
        if failureValue == nil { failureValue = failure }
    }

    func failure() -> EvaluationRunLimit? { lock.lock(); defer { lock.unlock() }; return failureValue }

    func requestStop(_ action: @escaping @Sendable () async -> Void) {
        lock.lock()
        guard !stopRequested else { lock.unlock(); return }
        stopRequested = true
        lock.unlock()
        Task { await action() }
    }
}

/// Parking spot for the latest cumulative usage snapshot reported by the
/// backend mid-run. The launcher's callback is synchronous, so this is a
/// lock-protected class (provably thread-safe: one lock, no reentrancy).
/// Sendable invariant: `snapshot` is the only mutable state, and every read
/// and write of it happens while holding `lock`.
// swiftlint:disable:next unchecked_sendable
private final class LatestUsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: UsageSnapshot?

    func record(_ snapshot: UsageSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func latest() -> UsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

/// Holds the CURRENT leg's launcher so a budget timeout can force-stop its
/// agent subprocess. `AgentLauncher` is `@MainActor` and not `Sendable`; the
/// lock protects only the stored reference and every use hops to the main
/// actor, which is the same discipline the class already imposes — the
/// `@unchecked` is local to this box and justified by exactly that.
/// Sendable invariant: `launcher` is the only mutable state, every access to
/// it holds `lock`, and the stored launcher is only messaged from the main
/// actor (`stopIfPresent` hops there before calling `stop()`).
// swiftlint:disable:next unchecked_sendable
private final class CurrentAgentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var launcher: AgentLauncher?

    func set(_ launcher: AgentLauncher?) {
        lock.lock()
        self.launcher = launcher
        lock.unlock()
    }

    func stopIfPresent() async {
        let current: AgentLauncher? = withLock {
            launcher
        }
        guard let current else { return }
        await MainActor.run { current.stop() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

#endif
