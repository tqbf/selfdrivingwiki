#if os(macOS)
import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import WikiCtlCore

/// Phase 5.1–5.2 of `plans/wiki-strategies-and-cumulative-ingestion.md`:
/// the DETERMINISTIC cumulative-ingestion pipeline harness.
///
/// What these tests prove — and deliberately do not:
///
/// - Each scenario drives the REAL production traversal: `AgentLauncher.run`
///   → staging (`OperationRequest.stage` / `AgentStaging`) → the multi-phase
///   orchestrator (`runACPIngestPlannerExecutors`: planner → pre-launch plan
///   validation (`ACPIngestPlanValidation` via the injected
///   `planValidationResolveTitle`) → executor(s) → finalizer) — reusing the
///   same injection seam as `QuotaFallbackIntegrationTests` and the launcher
///   traversal proven by `AgentLoopPluginBootTests`.
/// - The scripted agent's actions run through the PRODUCTION CLI dispatch
///   seam (`ScriptedWikiCtl`: `ArgumentParser.parse` → `PageCommand.run` /
///   `LogIndexCommand.run` → the composed upsert, with the real
///   exit-3 conflict family: `PageConflictError`,
///   `PageCreateConflictError`, `PageExpectedTargetMissingError`) against a
///   disposable database. Nothing hands a premerged body to the store.
/// - Conforming scripts follow the CURRENT production executor contract:
///   one JSON read per page supplying body+head; new page →
///   `page add --create-only`; existing page → `--expect-head`; on exit 3,
///   re-read BOTH body and head, RECOMPUTE against the new body, retry
///   ONCE; a second conflict is reported, never looped. The prompt
///   assertions check those ACTUAL contract clauses of
///   `prompts/ingest-executor.md` — not just a CAS heading.
/// - `nonconformingScript` deliberately violates the contract to
///   demonstrate that prompt delivery is a transport guarantee, not a
///   semantic one — a scripted pass is not a live semantic pass (that
///   harness is phase 5.3–5.5).
///
/// Bounded and nonblocking per the phase 5 test strategy: no subprocesses
/// are spawned by the scripts, every action is a finite in-process store
/// call bounded by `FakeAgentBackend.scriptedActionBound`, and the suite is
/// serialized with a time limit. All fixtures (disposable DB, provider
/// config, quota state) live under the PROJECT-relative `tmp/` directory
/// per AGENTS — never the system temporaryDirectory and never the real App
/// Group container.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct CumulativeIngestPipelineTests {

    // MARK: - Fixtures

    /// Fixture facts. `FACT-*` markers are the evidence-retention handles the
    /// assertions track across versions; everything else is inert prose that
    /// pads each source past `IngestPlan`'s tiny-source threshold so the run
    /// takes the multi-phase planner/executor/finalizer path.
    private struct Fixture {
        let sourceAID: SourceID
        let sourceBID: SourceID

        static let title = "Mira Chen"

        init(store: GRDBWikiStore) throws {
            sourceAID = try store.addSource(
                filename: "chapter-one.md",
                data: Self.paddedSource(facts: [Self.factA])).id
            sourceBID = try store.addSource(
                filename: "chapter-two.md",
                data: Self.paddedSource(facts: [Self.factB])).id
        }
        static let sourceAName = "Chapter One"
        static let sourceBName = "Chapter Two"
        static let factA = "FACT-A1: Mira Chen pilots the cargo skiff *Long Reach*."
        static let factB =
            "FACT-B1: The *Long Reach* was re-registered as *Second Dawn* after the Kessel run."
        static let racingFact =
            "FACT-R1: A racing editor recorded Mira's debt to the Kessel guild."
        static let stateMarkdown = "# Wiki State\n\n## Pages\n\n- (none yet)\n"
        static let systemPrompt = "sys-pipeline"
        /// Staged-range string the batched plan assigns for source B; the
        /// executor prompt must render it verbatim next to B's leaf.
        static let supportingRanges = "lines 40-60"

        var leafA: String {
            AgentStaging.shellSafeLeaf(name: Self.sourceAName, sourceID: sourceAID, ext: "md")
        }

        var leafB: String {
            AgentStaging.shellSafeLeaf(name: Self.sourceBName, sourceID: sourceBID, ext: "md")
        }

        /// A staged source body over the tiny-source threshold carrying the
        /// given fact lines.
        static func paddedSource(facts: [String]) -> Data {
            var text = "# Source\n\n"
            text += facts.map { "- \($0)" }.joined(separator: "\n")
            text += "\n\n"
            // Inert filler (~4.8 KB) so `IngestPlan.decide` routes the run to
            // the multi-phase path — same size class the existing launcher
            // tests use.
            text += String(repeating: "Filler line of inert source prose for size.\n", count: 110)
            return Data(text.utf8)
        }

        static func source(_ id: SourceID, name: String, facts: [String])
            -> OperationRequest.StagedSource
        {
            OperationRequest.StagedSource(
                bytes: paddedSource(facts: facts),
                ext: "md",
                displayPath: "sources/by-id/\(id.rawValue).md",
                name: name,
                sourceID: id)
        }

        func sourceA() -> OperationRequest.StagedSource {
            Self.source(sourceAID, name: Self.sourceAName, facts: [Self.factA])
        }

        func sourceB() -> OperationRequest.StagedSource {
            Self.source(sourceBID, name: Self.sourceBName, facts: [Self.factB])
        }

        /// Plan JSON for one page assignment. `supporting` (default nil) is
        /// the REAL optional supporting-source list of phase 4 §4.6 — the
        /// batched scenario populates it so the rendered executor prompt (and
        /// pre-launch validation) exercise the actual field.
        static func plan(
            _ planSources: [SourceID],
            leaf: String,
            supporting: [ACPIngestSupportingSource]? = nil
        ) throws -> Data {
            try JSONEncoder().encode(ACPIngestPlan(
                pages: [ACPIngestPageAssignment(
                    title: title,
                    sourceFile: leaf,
                    sourceRanges: "1-120",
                    outline: "Character page for \(title)",
                    supportingSources: supporting)],
                sourceIDs: planSources.map(\.rawValue)))
        }

        /// The page body a CONFORMING executor composes when creating the
        /// page from source A.
        static let createBodyA = "# \(title)\n\n- \(factA)\n- Maintains a running account with the Kessel guild.\n"

        /// The paragraph a conforming executor APPENDS when reconciling
        /// source B into the current body.
        static let reconcileBParagraph = "\n\n## Later evidence\n\n- \(factB)\n"
    }

    /// The clauses of the production executor reconciliation contract these
    /// pipeline tests require — the ACTUAL text of `prompts/ingest-executor.md`
    /// steps 2–5 (body+head single read, reconcile-not-append, exactly one
    /// expectation flag, re-read + RECOMPUTE + retry ONCE on exit 3, report a
    /// second conflict), not a mere CAS heading. Each fragment lies on one
    /// line of the authored prompt.
    private static let reconciliationContractClauses: [String] = [
        "ONE JSON read per page",
        "head_version_id",
        "do not append blindly",
        "Preserve existing claims that remain supported",
        "--expect-head",
        "--create-only",
        "mutually exclusive",
        "RECOMPUTE the reconciliation against the new body",
        "old composed body with only a refreshed head",
        "retry ONCE",
        "A SECOND conflict on the same page: report that page as failed",
    ]

    /// Executor-prompt contract check: returns the clauses MISSING from the
    /// captured production prompt (empty = contract delivered).
    private func missingContractClauses(in prompt: String) -> [String] {
        Self.reconciliationContractClauses.filter { !prompt.contains($0) }
    }

    // MARK: - Fixture roots (project tmp/, per AGENTS)

    /// Project-relative scratch root (`tmp/`, gitignored) — NOT the system
    /// temporaryDirectory. `swift test` runs with the working directory at
    /// the package root, so this lands beside the other project scratch
    /// artifacts.
    private static let projectTmpRoot: URL =
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp", isDirectory: true)

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = Self.projectTmpRoot
            .appendingPathComponent("cumulative-ingest-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A disposable file-backed wiki DB under the project `tmp/` fixture
    /// root (same construction as `TestStoreFactory.fileBacked`, rooted here
    /// instead of the system temp per the strict fixture-path rule).
    private func makeDisposableStore(label: String, in root: URL) throws -> GRDBWikiStore {
        let dir = root.appendingPathComponent("db-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try GRDBWikiStore(
            databaseURL: dir.appendingPathComponent("wiki.sqlite", isDirectory: false))
    }

    private func removeFixture(at directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove cumulative ingest fixture: \(error)")
        }
    }

    // MARK: - Harness

    /// Wire a launcher for the full production `run()` traversal on the fake
    /// backend — the same injection surface `QuotaFallbackIntegrationTests`
    /// uses. The provider is a resolvable stub (`/usr/bin/true`) with a
    /// selected model so `SpawnModelGuard` lets every ingest stage spawn.
    /// The phase 4 §4.7 pre-launch plan validator resolves titles through
    /// `planValidationResolveTitle` bound to the FIXTURE store — the
    /// launcher never derives a database path itself, and no resolver in
    /// this wiring can reach the real App Group container.
    private func makeLauncher(
        backend: FakeAgentBackend,
        tempDir: URL,
        store: GRDBWikiStore
    ) -> AgentLauncher {
        let launcher = AgentLauncher()
        launcher.resolveBackend = { _, _, _, _ in backend }
        launcher.acpCredentialStore = InMemoryACPCredentialStore()
        launcher.planValidationResolveTitle = { title in
            try store.resolveTitleToID(title)
        }
        let provider = AgentProvider(
            id: ProviderID(rawValue: "fake-acp"),
            label: "Fake",
            command: ["/usr/bin/true"],
            enabled: true,
            isDefault: true)
        launcher.resolveSelectedProvider = { provider }
        do {
            let config = AgentProvidersConfig(
                providers: [provider],
                selectedModelIds: [provider.id.rawValue: ModelID(rawValue: "fake-model")])
            try config.save(to: tempDir)
        } catch {
            Issue.record("Failed to save provider config to temp dir: \(error)")
        }
        launcher.resolveProvidersContainerDirectory = { tempDir }
        launcher.containerDirectory = tempDir
        launcher.makeQuotaFallbackCoordinator = {
            QuotaFallbackCoordinator(
                quotaStateURL: tempDir.appendingPathComponent("quota-state.json"))
        }
        return launcher
    }

    /// Drive one full production ingest run for `sources` on `launcher`.
    @discardableResult
    private func runIngest(
        launcher: AgentLauncher,
        sources: [OperationRequest.StagedSource],
        stateMarkdown: String = Fixture.stateMarkdown
    ) async -> AgentLauncher {
        await launcher.run(
            request: .ingest(sources: sources, stateMarkdown: stateMarkdown),
            wikiID: WikiID(rawValue: "cumulative-ingest"),
            wikiRoot: Self.projectTmpRoot.path,
            systemPrompt: Fixture.systemPrompt,
            wikictlDirectory: Self.projectTmpRoot.path,
            ingestingSourceIDs: [],
            onEvent: nil,
            onLock: {},
            onUnlock: {})
        return launcher
    }

    /// Behaviors for one conforming single-executor run: planner writes the
    /// plan, `executorActions` play the executor, finalizer logs each source.
    private func runBehaviors(
        planJSON: Data,
        executorActions: [FakeAgentAction],
        executorEvents: [AgentEvent] = [.messageStop],
        finalizerSourceIDs: [SourceID]
    ) -> [FakeSessionBehavior] {
        [
            FakeSessionBehavior(events: [.messageStop], planJSON: planJSON),
            FakeSessionBehavior(events: executorEvents, actions: executorActions),
            FakeSessionBehavior(events: [.messageStop], actions: finalizerSourceIDs.map { id in
                .logAppend(kind: "ingest", title: "Ingested \(id.rawValue)", source: id.rawValue)
            }),
        ]
    }

    /// The conforming CREATE sequence after a missing-page read: one
    /// `page get` (exit 1) followed by `page add --create-only` — the
    /// production contract's new-page write, never a blind create.
    private static func conformingCreateActions(body: String, sourceID: SourceID) -> [FakeAgentAction] {
        [
            .getPage(title: Fixture.title),
            .writePage(
                title: Fixture.title,
                body: body,
                head: .blind,          // --create-only and --expect-head are mutually exclusive
                createOnly: true,
                sources: [sourceID.rawValue + ":primary"]),
        ]
    }

    // MARK: - Store assertion helpers

    private func requirePageID(_ store: GRDBWikiStore, title: String) throws -> PageID {
        guard let id = try store.resolveTitleToID(title) else {
            Issue.record("page \(title.debugDescription) does not exist")
            struct MissingPage: Error {}
            throw MissingPage()
        }
        return id
    }

    private func body(_ store: GRDBWikiStore, pageID: PageID) throws -> String {
        try store.getPage(id: pageID).bodyMarkdown
    }

    private func versionCount(_ store: GRDBWikiStore, pageID: PageID) throws -> Int {
        try store.pageVersionHistory(pageID: pageID).count
    }

    private func headProvenanceSourceIDs(_ store: GRDBWikiStore, pageID: PageID) throws -> Set<String> {
        guard let head = try store.pageHeadVersionID(pageID: pageID) else { return [] }
        return Set(try store.pageVersionSources(versionID: head).map(\.sourceID.rawValue))
    }

    private func executorPrompt(_ sentTexts: [String], run: Int) -> String {
        // Per run the fake sees [planner, executor, finalizer] sends; with
        // one executor per run, run 0 → index 1, run 1 → index 4.
        let index = run * 3 + 1
        guard sentTexts.count > index else {
            Issue.record("missing executor prompt at index \(index) (have \(sentTexts.count))")
            return ""
        }
        return sentTexts[index]
    }

    /// Assert the captured executor prompt delivers the full production
    /// reconciliation contract (the actual clauses, see
    /// `reconciliationContractClauses`).
    private func expectReconciliationContractDelivered(_ prompt: String) {
        let missing = missingContractClauses(in: prompt)
        #expect(missing.isEmpty,
                "executor prompt must deliver the reconciliation contract; missing: \(missing)")
    }

    // MARK: - AC.6: successiveSources

    /// Source A is ingested in one full pipeline run; source B is ingested in
    /// a LATER run. Run A's executor reads the title as missing and creates
    /// via `--create-only`; run B's executor reads the existing page's
    /// body+head in one JSON read, recomposes, and writes with
    /// `--expect-head`. One PageID survives both runs, evidence from A is
    /// retained in the reconciled body, history records both versions, and
    /// the head version's provenance names BOTH sources (B primary, A
    /// supporting — retained claims keep their evidence).
    @Test func successiveSources() async throws {
        let tempDir = try makeTempDir("successive")
        defer { removeFixture(at: tempDir) }
        let store = try makeDisposableStore(label: "successive", in: tempDir)
        let fixture = try Fixture(store: store)

        // Run A — conforming create: missing-page read, then --create-only.
        let fakeA = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceAID], leaf: fixture.leafA),
            executorActions: [
                .readStateFile,
                .readStagedSource(leaf: fixture.leafA),
            ] + Self.conformingCreateActions(body: Fixture.createBodyA, sourceID: fixture.sourceAID),
            finalizerSourceIDs: [fixture.sourceAID]),
            scriptStore: store)
        let launcherA = makeLauncher(backend: fakeA, tempDir: tempDir, store: store)
        await runIngest(launcher: launcherA, sources: [fixture.sourceA()])

        let pageIDAfterA = try requirePageID(store, title: Fixture.title)

        // Run B — conforming reconcile: one JSON read supplies body AND head,
        // recompose, write with --expect-head.
        let fakeB = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceBID], leaf: fixture.leafB),
            executorActions: [
                .readStateFile,
                .readStagedSource(leaf: fixture.leafB),
                .getPage(title: Fixture.title),
                .reconcileWrite(
                    title: Fixture.title,
                    compose: { current in (current ?? "") + Fixture.reconcileBParagraph },
                    head: .fromLastRead,
                    createOnly: false,
                    sources: [
                        fixture.sourceBID.rawValue + ":primary",
                        fixture.sourceAID.rawValue + ":supporting",
                    ]),
            ],
            finalizerSourceIDs: [fixture.sourceBID]),
            scriptStore: store)
        let launcherB = makeLauncher(backend: fakeB, tempDir: tempDir, store: store)
        await runIngest(launcher: launcherB, sources: [fixture.sourceB()])

        // Traversal: three phases per run on the production multi-phase path.
        let startsA = await fakeA.startCount
        let startsB = await fakeB.startCount
        #expect(startsA == 3, "run A must traverse planner/executor/finalizer (preflightError=\(launcherA.preflightError ?? "nil"))")
        #expect(startsB == 3, "run B must traverse planner/executor/finalizer (preflightError=\(launcherB.preflightError ?? "nil"))")
        #expect(launcherA.exitStatus == 0 && launcherB.exitStatus == 0)

        // Prompt delivery: each executor prompt carries the ACTUAL
        // reconciliation contract plus its assignment context (title,
        // primary source leaf, staged state file, source ids).
        let executorPromptA = executorPrompt(await fakeA.sentTexts, run: 0)
        let executorPromptB = executorPrompt(await fakeB.sentTexts, run: 0)
        expectReconciliationContractDelivered(executorPromptA)
        expectReconciliationContractDelivered(executorPromptB)
        for prompt in [executorPromptA, executorPromptB] {
            #expect(prompt.contains(Fixture.title))
            #expect(prompt.contains("WIKI_STATE.md"))
        }
        #expect(executorPromptA.contains(fixture.leafA))
        #expect(executorPromptA.contains(fixture.sourceAID.rawValue))
        #expect(executorPromptB.contains(fixture.leafB))
        #expect(executorPromptB.contains(fixture.sourceBID.rawValue))

        // System prompts captured per session (phase 5.1 capture seam).
        let systemPromptsA = await fakeA.recordedSystemPrompts
        #expect(systemPromptsA.count == 3)
        #expect(systemPromptsA.allSatisfy { $0 == Fixture.systemPrompt })

        // The staged state file the production `stage()` wrote was readable
        // at the executor's scratch, byte-identical to the run's snapshot.
        let stateFiles = await fakeA.capturedStateFileContents
        #expect(stateFiles == [Fixture.stateMarkdown])

        // Both staged sources were read by their executors.
        let capturedA = await fakeA.capturedStagedSources
        let capturedB = await fakeB.capturedStagedSources
        #expect(capturedA.map(\.leaf) == [fixture.leafA])
        #expect(capturedA.first?.content.contains(Fixture.factA) == true)
        #expect(capturedB.map(\.leaf) == [fixture.leafB])
        #expect(capturedB.first?.content.contains(Fixture.factB) == true)

        // Run A's create was --create-only (the missing-read write), exit 0.
        let recordsA = await fakeA.actionRecords
        let createRecords = recordsA.filter { $0.label.hasPrefix("writePage") }
        #expect(createRecords.count == 1)
        #expect(createRecords.first?.exitCode == ScriptedCLIOutcome.Code.success)

        // Cumulative state: one stable page, retained evidence, history,
        // provenance.
        let pageIDAfterB = try requirePageID(store, title: Fixture.title)
        #expect(pageIDAfterB == pageIDAfterA, "successive upserts must keep one PageID")
        let finalBody = try body(store, pageID: pageIDAfterB)
        #expect(finalBody.contains(Fixture.factA), "A's evidence must survive B's reconcile")
        #expect(finalBody.contains(Fixture.factB))
        #expect(try versionCount(store, pageID: pageIDAfterB) == 2)
        #expect(try headProvenanceSourceIDs(store, pageID: pageIDAfterB)
            == [fixture.sourceAID.rawValue, fixture.sourceBID.rawValue])

        // The B executor's write was a CAS write, not blind: it threads the
        // head captured by its read.
        let recordsB = await fakeB.actionRecords
        let reconcileRecords = recordsB.filter { $0.label.hasPrefix("reconcileWrite") }
        #expect(reconcileRecords.count == 1)
        #expect(reconcileRecords.first?.exitCode == ScriptedCLIOutcome.Code.success)
        let readRecords = recordsB.filter { $0.label.hasPrefix("getPage") }
        #expect(readRecords.count == 1 && readRecords.first?.exitCode == ScriptedCLIOutcome.Code.success)
    }

    // MARK: - AC.6: batchedSources

    /// Sources A and B are ingested in ONE run. The plan carries the REAL
    /// optional supporting-source list (phase 4 §4.6): primary A, supporting
    /// B with staged ranges. The executor prompt renders the supporting
    /// reference (`- Supporting: <leaf>, <ranges>`), the executor reads BOTH
    /// staged sources and writes once citing both, the pre-launch validation
    /// (with the fixture-bound `planValidationResolveTitle`) accepts the
    /// plan, and the finalizer logs both files.
    @Test func batchedSources() async throws {
        let tempDir = try makeTempDir("batch")
        defer { removeFixture(at: tempDir) }
        let store = try makeDisposableStore(label: "batch", in: tempDir)
        let fixture = try Fixture(store: store)

        let fake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan(
                [fixture.sourceAID, fixture.sourceBID],
                leaf: fixture.leafA,
                supporting: [ACPIngestSupportingSource(
                    sourceFile: fixture.leafB,
                    sourceRanges: Fixture.supportingRanges)]),
            executorActions: [
                .readStateFile,
                .readStagedSource(leaf: fixture.leafA),
                .readStagedSource(leaf: fixture.leafB),
            ] + [
                .reconcileWrite(
                    title: Fixture.title,
                    compose: { _ in
                        "# \(Fixture.title)\n\n- \(Fixture.factA)\n- \(Fixture.factB)\n"
                    },
                    head: .blind,          // missing read → --create-only
                    createOnly: true,
                    sources: [
                        fixture.sourceAID.rawValue + ":primary",
                        fixture.sourceBID.rawValue + ":supporting",
                    ]),
            ],
            finalizerSourceIDs: [fixture.sourceAID, fixture.sourceBID]),
            scriptStore: store)

        let launcher = makeLauncher(backend: fake, tempDir: tempDir, store: store)
        await runIngest(launcher: launcher, sources: [fixture.sourceA(), fixture.sourceB()])

        let starts = await fake.startCount
        #expect(starts == 3, "batch run must traverse planner/executor/finalizer (preflightError=\(launcher.preflightError ?? "nil"))")
        #expect(launcher.exitStatus == 0)

        // Both staged sources were delivered to the one executor's scratch
        // and read.
        let captured = await fake.capturedStagedSources
        #expect(Set(captured.map(\.leaf)) == Set([fixture.leafA, fixture.leafB]))

        // The executor prompt named both source ids (SOURCE_IDS), the
        // assigned primary, delivered the reconciliation contract, and
        // rendered the supporting-source reference VERBATIM (leaf + staged
        // ranges) — the phase 4 §4.6 rendering.
        let prompt = executorPrompt(await fake.sentTexts, run: 0)
        #expect(prompt.contains(fixture.sourceAID.rawValue))
        #expect(prompt.contains(fixture.sourceBID.rawValue))
        #expect(prompt.contains(fixture.leafA))
        expectReconciliationContractDelivered(prompt)
        #expect(prompt.contains("- Supporting: \(fixture.leafB), \(Fixture.supportingRanges)"),
                "the executor prompt must render the plan's supporting-source reference with its staged ranges")

        // One page, one version, both facts, both provenance edges.
        let pageID = try requirePageID(store, title: Fixture.title)
        let finalBody = try body(store, pageID: pageID)
        #expect(finalBody.contains(Fixture.factA))
        #expect(finalBody.contains(Fixture.factB))
        #expect(try versionCount(store, pageID: pageID) == 1)
        #expect(try headProvenanceSourceIDs(store, pageID: pageID)
            == [fixture.sourceAID.rawValue, fixture.sourceBID.rawValue])

        // The finalizer logged both files ingested.
        let logRecords = (await fake.actionRecords).filter { $0.label.hasPrefix("logAppend") }
        #expect(logRecords.count == 2)
        #expect(logRecords.allSatisfy { $0.exitCode == ScriptedCLIOutcome.Code.success })
    }

    // MARK: - AC.6: conflictRecomposesFromNewBody

    /// A racing writer commits between the executor's read and its write.
    /// The CAS write fails (exit 3); the conforming executor RE-READS body
    /// and head in one JSON read, RECOMPUTES from the NEW body (never
    /// resending the stale composition with a refreshed head), and retries
    /// once with the fresh head. The racing writer's evidence survives — no
    /// lost update.
    @Test func conflictRecomposesFromNewBody() async throws {
        // Source IDs are seeded by the per-store fixture.
        let tempDir = try makeTempDir("conflict")
        defer { removeFixture(at: tempDir) }
        let store = try makeDisposableStore(label: "conflict", in: tempDir)
        let fixture = try Fixture(store: store)

        // Seed the page with source A (conforming create).
        let seedFake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceAID], leaf: fixture.leafA),
            executorActions: Self.conformingCreateActions(body: Fixture.createBodyA, sourceID: fixture.sourceAID),
            finalizerSourceIDs: [fixture.sourceAID]),
            scriptStore: store)
        let seedLauncher = makeLauncher(backend: seedFake, tempDir: tempDir, store: store)
        await runIngest(launcher: seedLauncher, sources: [fixture.sourceA()])

        // Run B with a race injected between the read and the write.
        let racingBody = "# \(Fixture.title)\n\n- \(Fixture.racingFact)\n"
        let fake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceBID], leaf: fixture.leafB),
            executorActions: [
                .getPage(title: Fixture.title),
                .racingWrite(title: Fixture.title, body: racingBody, sources: []),
                // Stale head → the production upsert must throw
                // PageConflictError → exit 3.
                .reconcileWrite(
                    title: Fixture.title,
                    compose: { current in (current ?? "") + Fixture.reconcileBParagraph },
                    head: .fromLastRead,
                    createOnly: false,
                    sources: [fixture.sourceBID.rawValue + ":primary"]),
                // Conforming retry: re-read body AND head, recompose from the
                // racing writer's body, thread the fresh head.
                .getPage(title: Fixture.title),
                .reconcileWrite(
                    title: Fixture.title,
                    compose: { current in (current ?? "") + Fixture.reconcileBParagraph },
                    head: .fromLastRead,
                    createOnly: false,
                    sources: [
                        fixture.sourceBID.rawValue + ":primary",
                        fixture.sourceAID.rawValue + ":supporting",
                    ]),
            ],
            finalizerSourceIDs: [fixture.sourceBID]),
            scriptStore: store)
        let launcher = makeLauncher(backend: fake, tempDir: tempDir, store: store)
        await runIngest(launcher: launcher, sources: [fixture.sourceB()])

        // The production contract was delivered to this executor too.
        expectReconciliationContractDelivered(executorPrompt(await fake.sentTexts, run: 0))

        let records = await fake.actionRecords
        let writes = records.filter { $0.label.hasPrefix("reconcileWrite") }
        #expect(writes.count == 2, "exactly one conflict + one retry")
        #expect(writes.first?.hadCASConflict == true, "stale-head write must exit 3")
        #expect(writes.first?.stderr.contains("CAS conflict") == true)
        #expect(writes.last?.exitCode == ScriptedCLIOutcome.Code.success)
        #expect(launcher.exitStatus == 0)

        let pageID = try requirePageID(store, title: Fixture.title)
        let finalBody = try body(store, pageID: pageID)
        #expect(finalBody.contains(Fixture.racingFact),
                "the retried body must be recomposed from the RACING writer's body")
        #expect(finalBody.contains(Fixture.factB))
        #expect(try versionCount(store, pageID: pageID) == 3,
                "seed + racing + one reconciled retry")
    }

    // MARK: - AC.6: secondConflictReportsFailure

    /// A second consecutive conflict is REPORTED, not retried: the executor
    /// re-read, recomposed, retried once, conflicted again, and stopped. No
    /// executor write committed; the page stays at the racing writer's head.
    /// The transport still reports run success — the failure lives in the
    /// agent's reported transcript, which is exactly the gap
    /// `nonconformingScript` demonstrates structurally.
    @Test func secondConflictReportsFailure() async throws {
        // Source IDs are seeded by the per-store fixture.
        let tempDir = try makeTempDir("second-conflict")
        defer { removeFixture(at: tempDir) }
        let store = try makeDisposableStore(label: "second-conflict", in: tempDir)
        let fixture = try Fixture(store: store)

        let seedFake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceAID], leaf: fixture.leafA),
            executorActions: Self.conformingCreateActions(body: Fixture.createBodyA, sourceID: fixture.sourceAID),
            finalizerSourceIDs: [fixture.sourceAID]),
            scriptStore: store)
        let seedLauncher = makeLauncher(backend: seedFake, tempDir: tempDir, store: store)
        await runIngest(launcher: seedLauncher, sources: [fixture.sourceA()])

        let racingBody1 = "# \(Fixture.title)\n\n- \(Fixture.racingFact) (first)\n"
        let racingBody2 = "# \(Fixture.title)\n\n- \(Fixture.racingFact) (second)\n"
        let reportText =
            "CAS conflict persisted after one retry — reporting the conflict instead of looping."
        let fake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceBID], leaf: fixture.leafB),
            executorActions: [
                .getPage(title: Fixture.title),
                .racingWrite(title: Fixture.title, body: racingBody1, sources: []),
                .reconcileWrite(
                    title: Fixture.title,
                    compose: { current in (current ?? "") + Fixture.reconcileBParagraph },
                    head: .fromLastRead,
                    createOnly: false,
                    sources: [fixture.sourceBID.rawValue + ":primary"]),
                .getPage(title: Fixture.title),
                .racingWrite(title: Fixture.title, body: racingBody2, sources: []),
                .reconcileWrite(
                    title: Fixture.title,
                    compose: { current in (current ?? "") + Fixture.reconcileBParagraph },
                    head: .fromLastRead,
                    createOnly: false,
                    sources: [fixture.sourceBID.rawValue + ":primary"]),
            ],
            executorEvents: [.assistantText(reportText), .messageStop],
            finalizerSourceIDs: [fixture.sourceBID]),
            scriptStore: store)
        let launcher = makeLauncher(backend: fake, tempDir: tempDir, store: store)
        await runIngest(launcher: launcher, sources: [fixture.sourceB()])

        // The "report a second conflict" clause was in the delivered prompt.
        expectReconciliationContractDelivered(executorPrompt(await fake.sentTexts, run: 0))

        let records = await fake.actionRecords
        let writes = records.filter { $0.label.hasPrefix("reconcileWrite") }
        #expect(writes.count == 2, "the contract allows exactly one retry")
        // Computed before the macro: a keypath predicate (`\.hadCASConflict`)
        // inside `#expect` selects a rethrows overload and fails to compile.
        let bothWritesConflicted = writes.allSatisfy { $0.hadCASConflict }
        #expect(bothWritesConflicted, "both writes must conflict")

        let pageID = try requirePageID(store, title: Fixture.title)
        #expect(try versionCount(store, pageID: pageID) == 3,
                "seed + two racing writes; the executor committed nothing")
        #expect(try body(store, pageID: pageID) == racingBody2)

        // The failure is reported in the transcript. Note the transport-level
        // status is still success — a scripted/transport pass is NOT evidence
        // of semantic correctness (see `nonconformingScript`).
        #expect(launcher.exitStatus == 0)
        #expect(launcher.events.contains { $0 == .assistantText(reportText) })
    }

    // MARK: - AC.6: concurrentCreationReconciles (phase 4 §4.4)

    /// The create-versus-create race: the executor probes the page as
    /// missing, another writer creates it first, and the executor's
    /// `page add --create-only` must CONFLICT — `PageCreateConflictError`,
    /// exit 3, nothing written — instead of silently replacing the winner.
    /// The executor then reads the created page's body+head in one JSON read
    /// and reconciles against it with `--expect-head`.
    ///
    /// `--create-only` is REQUIRED production surface here (phase 4 §4.4
    /// landed): no `withKnownIssue` fallback. Unit counterparts:
    /// `AgentCASTests.createOnlyConflictDoesNotOverwrite` /
    /// `createOnlyCreatesAbsentPage` / `mutuallyExclusiveExpectationsRejected`.
    @Test func concurrentCreationReconciles() async throws {
        let tempDir = try makeTempDir("create-race")
        defer { removeFixture(at: tempDir) }
        let store = try makeDisposableStore(label: "create-race", in: tempDir)
        let fixture = try Fixture(store: store)

        let creatorBody = "# \(Fixture.title)\n\n- \(Fixture.racingFact)\n"
        let fake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceAID], leaf: fixture.leafA),
            executorActions: [
                .listPages,
                // The race: another writer creates the page between the
                // executor's missing-page probe and its create.
                .racingWrite(title: Fixture.title, body: creatorBody, sources: []),
                .writePage(
                    title: Fixture.title,
                    body: Fixture.createBodyA,
                    head: .blind,
                    createOnly: true,
                    sources: [fixture.sourceAID.rawValue + ":primary"]),
                // Reconcile against the winner: read its body+head in one
                // JSON read, recompose, CAS write.
                .getPage(title: Fixture.title),
                .reconcileWrite(
                    title: Fixture.title,
                    compose: { current in (current ?? "") + "\n\n- \(Fixture.factA)\n" },
                    head: .fromLastRead,
                    createOnly: false,
                    sources: [fixture.sourceAID.rawValue + ":primary"]),
            ],
            finalizerSourceIDs: [fixture.sourceAID]),
            scriptStore: store)
        let launcher = makeLauncher(backend: fake, tempDir: tempDir, store: store)
        await runIngest(launcher: launcher, sources: [fixture.sourceA()])

        // The delivered prompt includes the create-only leg of the contract.
        expectReconciliationContractDelivered(executorPrompt(await fake.sentTexts, run: 0))

        let records = await fake.actionRecords
        let createWrite = records.first { $0.label.hasPrefix("writePage") }
        #expect(createWrite != nil, "the create-only attempt must have been dispatched")
        // STRICT: a page appearing since the missing-page read conflicts the
        // create-only write (exit 3, PageCreateConflictError), and nothing
        // was written by the failed attempt.
        #expect(createWrite?.hadCASConflict == true,
                "the raced --create-only write must exit 3")
        #expect(createWrite?.stderr.contains("create-only conflict") == true)
        #expect(createWrite?.stderr.contains("Nothing was written") == true)

        // The winner's evidence survives the reconciliation, one page,
        // executor evidence merged on top, exactly two versions (the
        // conflicted create contributed none).
        let pageID = try requirePageID(store, title: Fixture.title)
        let finalBody = try body(store, pageID: pageID)
        #expect(finalBody.contains(Fixture.racingFact), "the racing creator's evidence must survive")
        #expect(finalBody.contains(Fixture.factA))
        #expect(try versionCount(store, pageID: pageID) == 2)
        #expect(try headProvenanceSourceIDs(store, pageID: pageID)
            == [fixture.sourceAID.rawValue])
        #expect(launcher.exitStatus == 0)

        // The missing-page probe really saw an empty wiki before the race.
        let listRecord = records.first { $0.label == "listPages" }
        #expect(listRecord?.exitCode == ScriptedCLIOutcome.Code.success)
        #expect(listRecord?.stdout.contains(Fixture.title) != true)
    }

    // MARK: - Negative control: prompt delivery ≠ semantic obedience

    /// An INTENTIONALLY NONCONFORMING executor: it never reads the existing
    /// page and writes with NEITHER expectation flag (the legacy blind
    /// write), dropping A's evidence. The production transport accepts every
    /// step — the executor prompt DELIVERED the full reconciliation contract
    /// (one-flag writes, reconcile-not-append, retry-once discipline), the
    /// write went through the real dispatch/upsert seam, and A's fact is
    /// gone anyway.
    ///
    /// This is the structural demonstration that the deterministic harness
    /// proves prompt DELIVERY and transport behavior, never semantic
    /// obedience — the distinction AC.6 guards against overclaiming and the
    /// live semantic evaluation (phase 5.3–5.5) exists to measure.
    @Test func nonconformingScript() async throws {
        let tempDir = try makeTempDir("nonconforming")
        defer { removeFixture(at: tempDir) }
        let store = try makeDisposableStore(label: "nonconforming", in: tempDir)
        let fixture = try Fixture(store: store)

        // Seed the page with source A (conforming create).
        let seedFake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceAID], leaf: fixture.leafA),
            executorActions: Self.conformingCreateActions(body: Fixture.createBodyA, sourceID: fixture.sourceAID),
            finalizerSourceIDs: [fixture.sourceAID]),
            scriptStore: store)
        let seedLauncher = makeLauncher(backend: seedFake, tempDir: tempDir, store: store)
        await runIngest(launcher: seedLauncher, sources: [fixture.sourceA()])

        let pageIDAfterA = try requirePageID(store, title: Fixture.title)

        // Nonconforming run B: no read, NO expectation flag (blind legacy
        // write — violates the exactly-one-flag contract), evidence dropped.
        let droppedABody = "# \(Fixture.title)\n\n- \(Fixture.factB)\n"
        let fake = FakeAgentBackend(behaviors: runBehaviors(
            planJSON: try Fixture.plan([fixture.sourceBID], leaf: fixture.leafB),
            executorActions: [
                .writePage(
                    title: Fixture.title,
                    body: droppedABody,
                    head: .blind,
                    createOnly: false,
                    sources: [fixture.sourceBID.rawValue + ":primary"]),
            ],
            executorEvents: [
                .assistantText("wrote the page without reading it (nonconforming)"),
                .messageStop,
            ],
            finalizerSourceIDs: [fixture.sourceBID]),
            scriptStore: store)
        let launcher = makeLauncher(backend: fake, tempDir: tempDir, store: store)
        await runIngest(launcher: launcher, sources: [fixture.sourceB()])

        // The transport did not (and cannot) police the violation…
        let records = await fake.actionRecords
        let writes = records.filter { $0.label.hasPrefix("writePage") }
        #expect(writes.count == 1)
        #expect(writes.first?.exitCode == ScriptedCLIOutcome.Code.success,
                "a blind write is a legal production operation")
        #expect(launcher.exitStatus == 0)

        // …even though the production executor prompt DID deliver the full
        // reconciliation contract and the assigned context.
        let prompt = executorPrompt(await fake.sentTexts, run: 0)
        expectReconciliationContractDelivered(prompt)
        #expect(prompt.contains(Fixture.title))
        #expect(prompt.contains(fixture.leafB))

        // And the semantic violation landed: A's evidence is gone, the page
        // identity is stable, and history records the blind overwrite.
        let pageIDAfterB = try requirePageID(store, title: Fixture.title)
        #expect(pageIDAfterB == pageIDAfterA)
        let finalBody = try body(store, pageID: pageIDAfterB)
        #expect(finalBody.contains(Fixture.factB))
        #expect(!finalBody.contains(Fixture.factA),
                "the nonconforming script dropped A's evidence and nothing caught it — by design of this control")
    }
}
#endif // os(macOS)
