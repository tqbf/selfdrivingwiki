import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore
@testable import WikiStrategyEval

/// The evaluation harness's negative controls (plan Phase 5.5, AC.7):
/// `passAndFailureClassification` proves the evaluator returns pass for a
/// conforming canned capture and failure for each documented semantic failure
/// mode (dropped evidence, unsupported claim, stale-write loss, unqualified
/// superseded claim, wrong strategy output, recreated page identity, missing
/// citation rows). `boundedCancellation` proves the budget wrapper stops a
/// runaway body through structured cancellation and a force-stop hook. No
/// provider, database, or subprocess is touched: every input is canned.
@Suite("Wiki strategy evaluation harness", .serialized, .timeLimit(.minutes(2)))
struct WikiStrategyEvaluationHarnessTests {

    // MARK: - Canned capture builders

    private let maraID = PageID(rawValue: "01MARA")
    private let homeID = PageID(rawValue: "00HOME")

    private func observedPage(
        id: PageID = PageID(rawValue: "01MARA"),
        title: String = "Mara Voss",
        body: String,
        version: Int = 2,
        historyDepth: Int = 2,
        provenance: [String] = ["meridian-chapter-03.md", "meridian-chapter-07.md"],
        sourceLinks: [String] = ["meridian-chapter-03.md", "meridian-chapter-07.md"],
        provenanceIDs: [SourceID] = [],
        sourceLinkIDs: [SourceID] = []
    ) -> ObservedPage {
        ObservedPage(
            id: id,
            title: title,
            body: body,
            version: version,
            updatedAt: Date(),
            historyDepth: historyDepth,
            provenanceSourceNames: provenance,
            citationNames: sourceLinks,
            sourceLinkNames: sourceLinks,
            provenanceSourceIDs: provenanceIDs,
            sourceLinkIDs: sourceLinkIDs)
    }

    private func homePage(body: String = "Home") -> ObservedPage {
        ObservedPage(
            id: homeID,
            title: "Home",
            body: body,
            version: 1,
            updatedAt: Date(),
            historyDepth: 1,
            provenanceSourceNames: [],
            citationNames: [],
            sourceLinkNames: [])
    }

    /// A conforming final body: retained fact, corrected account, qualified
    /// history, citations.
    private var conformingBody: String {
        """
        Mara Voss is the chief cartographer of the *Meridian*, a post she has
        held for nine years. Previously the crew believed Mara sabotaged the
        beacon at Kelso Harbor. Chapter 7 corrects the record: her brother Ilya
        Voss confessed that he sabotaged the beacon and framed her, and the
        inquiry cleared Mara, who had shut the harbor relay to warn the fleet
        ([[source:meridian-chapter-07.md]]). The original accusation and its
        chisel-mark evidence appear in [[source:meridian-chapter-03.md]].
        """
    }

    private func input(
        beforePage: ObservedPage,
        afterPage: ObservedPage,
        beforeHomeBody: String = "Home",
        afterHomeBody: String = "Home"
    ) -> EvaluationInput {
        EvaluationInput(
            before: WikiObservation(
                pages: [beforePage, homePage(body: beforeHomeBody)],
                sources: [
                    ObservedSource(id: SourceID(rawValue: "01S3"), name: "meridian-chapter-03.md"),
                    ObservedSource(id: SourceID(rawValue: "01S7"), name: "meridian-chapter-07.md"),
                ]),
            after: WikiObservation(
                pages: [afterPage, homePage(body: afterHomeBody)],
                sources: [
                    ObservedSource(id: SourceID(rawValue: "01S3"), name: "meridian-chapter-03.md"),
                    ObservedSource(id: SourceID(rawValue: "01S7"), name: "meridian-chapter-07.md"),
                ]))
    }

    private func evaluate(_ input: EvaluationInput) -> ScenarioEvaluation {
        StructuralEvaluator().evaluate(scenario: EvaluationFixtures.characterHistory, input: input)
    }

    private func failingCheckIDs(_ evaluation: ScenarioEvaluation) -> [String] {
        evaluation.failedChecks.map(\.id)
    }

    private func beforePage() -> ObservedPage {
        observedPage(
            body: """
            Mara Voss is the chief cartographer of the *Meridian*. The crew
            believed Mara sabotaged the beacon at Kelso Harbor
            ([[source:meridian-chapter-03.md]]).
            """,
            version: 1,
            historyDepth: 1,
            provenance: ["meridian-chapter-03.md"],
            sourceLinks: ["meridian-chapter-03.md"])
    }

    // MARK: - passAndFailureClassification (plan AC.7)

    @Test("a conforming capture passes every structural check")
    func passAndFailureClassification() throws {
        // PASS: conforming before/after pair.
        let passing = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(body: conformingBody)))
        #expect(passing.passed, "conforming capture should pass: \(passing.failedChecks.map(\.detail))")

        // FAIL — evidence drop: the retained fact vanished from the final body.
        let evidenceDrop = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(
                body: conformingBody.replacingOccurrences(of: "chief cartographer", with: "sailor"))))
        #expect(!evidenceDrop.passed)
        #expect(failingCheckIDs(evidenceDrop).contains("retainedFact:Mara Voss"))

        // FAIL — unsupported claim: a fact no fixture source states.
        let unsupported = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(
                body: conformingBody + "\nMara later signed the Kelso Pact with the harbor guild.")))
        #expect(!unsupported.passed)
        #expect(failingCheckIDs(unsupported).contains("unsupportedClaim:Mara Voss"))

        // FAIL — stale-write loss: run B never recorded a version (history
        // depth stayed at 1), so the reconciliation was lost.
        let staleWrite = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(body: conformingBody, version: 1, historyDepth: 1)))
        #expect(!staleWrite.passed)
        #expect(failingCheckIDs(staleWrite).contains("historyDepth:Mara Voss"))

        // FAIL — recreated page identity: run B produced a NEW page id.
        let recreated = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(
                id: PageID(rawValue: "02NEWPAGE"),
                body: conformingBody)))
        #expect(!recreated.passed)
        #expect(failingCheckIDs(recreated).contains("stablePageIdentity:Mara Voss"))

        // FAIL — missing citation row: the database has no source-link edge
        // for the chapter-07 source.
        let uncited = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(
                body: conformingBody,
                sourceLinks: ["meridian-chapter-03.md"])))
        #expect(!uncited.passed)
        #expect(failingCheckIDs(uncited).contains("citationsPresent:Mara Voss"))

        // FAIL — unrelated page edits: Home changed under the run.
        let unrelatedEdits = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(body: conformingBody),
            afterHomeBody: "Home (rewritten by the run)"))
        #expect(!unrelatedEdits.passed)
        #expect(failingCheckIDs(unrelatedEdits).contains("noUnrelatedPageEdits"))
    }

    @Test("qualified history of a superseded claim passes")
    func qualifiedSupersededHistoryPasses() {
        let evaluation = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(body: conformingBody)))
        #expect(evaluation.passed)
        #expect(!failingCheckIDs(evaluation).contains("supersededInterpretation:Mara Voss"))
    }

    @Test("current supported framing is not classified as the old accusation")
    func currentFramingIsNotSuperseded() {
        let evaluation = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(body: conformingBody)))
        #expect(!failingCheckIDs(evaluation).contains("supersededInterpretation:Mara Voss"))
    }

    @Test("unqualified repetition of a superseded claim fails even when the first mention is qualified")
    func supersededRepetitionFails() {
        // The first mention is properly qualified. The LAST sentence repeats
        // the old claim far from any qualifier word — presenting it as current
        // truth. First-occurrence-only checking would pass this; the
        // evaluator must not. (The repeated phrase must stay on ONE line:
        // phrase matching is literal, and a line wrap would hide the
        // repetition from the scanner.)
        let body = """
        Mara Voss is the chief cartographer of the *Meridian*. Previously the
        crew believed Mara sabotaged the beacon. Ilya Voss confessed that he
        framed her, and the inquiry cleared Mara, who shut the harbor relay to
        warn the fleet ([[source:meridian-chapter-07.md]]). The original
        accusation appears in [[source:meridian-chapter-03.md]]. The watch log
        went back to the bridge the next morning and the transit notes were
        filed with the chart corrections for that week. Mara sabotaged the beacon,
        the galley story finished, and nothing more came of it.
        """
        let evaluation = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(body: body)))
        #expect(!evaluation.passed)
        #expect(failingCheckIDs(evaluation).contains("supersededInterpretation:Mara Voss"))
    }

    // MARK: - Superseded repository decision (markdown-aware current assertions)

    /// The supersededRepositoryDecision canned scaffold: typed fixture keys,
    /// both ADRs linked and in head provenance, two versions recorded. Only
    /// the after body varies per test.
    private func storageInput(afterBody: String) -> EvaluationInput {
        let adr014 = ObservedSource(
            id: SourceID(rawValue: "01ADR14"),
            name: "ADR 014: One shared database for all wikis",
            fixtureKey: "adr-014-storage-layout")
        let adr021 = ObservedSource(
            id: SourceID(rawValue: "01ADR21"),
            name: "ADR 021: One database per wiki",
            fixtureKey: "adr-021-per-wiki-databases")
        let sources = [adr014, adr021]
        func storagePage(
            body: String,
            version: Int,
            historyDepth: Int,
            provenanceIDs: [SourceID],
            sourceLinkIDs: [SourceID]
        ) -> ObservedPage {
            ObservedPage(
                id: PageID(rawValue: "01STORAGE"),
                title: "Storage architecture",
                body: body,
                version: version,
                updatedAt: Date(),
                historyDepth: historyDepth,
                provenanceSourceNames: [],
                citationNames: [],
                sourceLinkNames: [],
                provenanceSourceIDs: provenanceIDs,
                sourceLinkIDs: sourceLinkIDs)
        }
        // A plausible leg-1 page: ADR 014 recorded when it was the only
        // source. No check reads this body; it exists so identity and
        // unrelated-edit checks see a real before/after pair.
        let beforeBody = """
        # Storage architecture

        ## ADR 014: One shared database for all wikis

        Status: accepted.

        Self Driving Wiki stores every wiki in ONE shared SQLite database
        inside the app group container, chosen for one backup target and
        cross-wiki joins.
        """
        return EvaluationInput(
            before: WikiObservation(
                pages: [
                    storagePage(
                        body: beforeBody, version: 1, historyDepth: 1,
                        provenanceIDs: [adr014.id], sourceLinkIDs: [adr014.id]),
                    homePage(),
                ],
                sources: sources),
            after: WikiObservation(
                pages: [
                    storagePage(
                        body: afterBody, version: 2, historyDepth: 2,
                        provenanceIDs: [adr014.id, adr021.id],
                        sourceLinkIDs: [adr014.id, adr021.id]),
                    homePage(),
                ],
                sources: sources))
    }

    private func evaluateStorage(_ afterBody: String) -> ScenarioEvaluation {
        StructuralEvaluator().evaluate(
            scenario: EvaluationFixtures.supersededDecision,
            input: storageInput(afterBody: afterBody))
    }

    /// The live-run shape that regressed on 2026-10-03
    /// (tmp/wiki-strategy-eval/2026-10-03T002006Z/supersededRepositoryDecision.report.md):
    /// ADR 021 presented as current, ADR 014 kept under an explicitly
    /// historical `##` section with `###` subsections ("Historical decision",
    /// "Rationale stated by ADR 014"), and both ADRs' wording quoted verbatim
    /// in footnote definitions. The old sentence scanner flagged the
    /// historical-subsection sentences ("stored every wiki in one shared
    /// SQLite database", "selected a single shared database") because neither
    /// sentence repeated a qualifier word. Historical-section scope and
    /// footnote exclusion must keep this page passing.
    @Test("an explicitly historical section and footnote source quotes are not current assertions")
    func historicalSectionAndFootnoteQuotesAreNotCurrentAssertions() {
        let body = """
        # Storage architecture

        ## ADR 021: One database per wiki

        ADR 021 is accepted and supersedes ADR 014.[^adr021-status] The current
        architecture stores each wiki in its own SQLite database file, named by
        the wiki's ULID inside the app group container.[^adr021-decision]

        ### Stated rationale

        ADR 014's single shared database made concurrent writers from the queue
        daemon block each other, and one corrupted file risked every wiki at
        once.[^adr021-rationale] Per-wiki databases let each wiki vacuum and
        migrate independently; the registry (`wikis.json`) replaces cross-wiki
        joins.[^adr021-independence]

        ### Migration

        ADR 014's schema ladder moves to a per-wiki migrator, and the shared
        database is retired after migration completes.[^adr021-migration]

        ## ADR 014: One shared database for all wikis

        ADR 014 is recorded as accepted, but superseded by ADR 021.[^adr014-status]
        This page preserves ADR 014 as architectural history; its rationale is
        not the current rationale.

        ### Historical decision

        Self Driving Wiki stored every wiki in one shared SQLite database inside
        the app group container.[^adr014-decision]

        ### Rationale stated by ADR 014

        The team selected a single shared database to provide one backup target.[^adr014-backup]
        It also allowed cross-wiki queries to join without leaving the database
        file,[^adr014-queries] while the migration plan required only one schema
        ladder.[^adr014-migration]

        ### Consequences noted at the time

        Writers for different wikis contended on one write lock.[^adr014-contention]
        The team accepted that contention because deployments were single-user.[^adr014-singleuser]

        [^adr021-status]: [[source:adr-021-per-wiki-databases#"Status: accepted. Supersedes ADR 014."|ADR 021: One database per wiki]] — status, "Status: accepted. Supersedes ADR 014."
        [^adr021-decision]: [[source:adr-021-per-wiki-databases#"Self Driving Wiki stores each wiki in its OWN SQLite database file"|ADR 021: One database per wiki]] — Decision, "Self Driving Wiki stores each wiki in its OWN SQLite database file, named by the wiki's ULID inside the app group container."
        [^adr021-rationale]: [[source:adr-021-per-wiki-databases#"ADR 014's single shared database made concurrent writers from the queue daemon block each other"|ADR 021: One database per wiki]] — Stated rationale, "ADR 014's single shared database made concurrent writers from the queue daemon block each other, and one corrupted file risked every wiki at once."
        [^adr014-status]: [[source:adr-014-storage-layout#"Status: accepted (superseded by ADR 021)."|ADR 014: One shared database for all wikis]] — status, "Status: accepted (superseded by ADR 021)."
        [^adr014-decision]: [[source:adr-014-storage-layout#"Self Driving Wiki stores every wiki in ONE shared SQLite database"|ADR 014: One shared database for all wikis]] — Decision, "Self Driving Wiki stores every wiki in ONE shared SQLite database inside the app group container."
        [^adr014-backup]: [[source:adr-014-storage-layout#"it gives one backup target"|ADR 014: One shared database for all wikis]] — Stated rationale, "it gives one backup target"
        [^adr014-queries]: [[source:adr-014-storage-layout#"cross-wiki queries join without leaving the database file"|ADR 014: One shared database for all wikis]] — Stated rationale, "cross-wiki queries join without leaving the database file"
        """
        let evaluation = evaluateStorage(body)
        // The "ADR 014's single shared database …" sentence inside the
        // CURRENT (ADR 021) section still carries its own sentence-local
        // qualifier — historical scope must not leak into current sections.
        #expect(
            evaluation.passed,
            "historical section + footnote quotes are not current assertions: \(evaluation.failedChecks.map(\.detail))")
    }

    /// The section-scope boundary: an earlier explicitly historical block
    /// must NOT excuse a later unqualified repetition of the superseded
    /// decision in a CURRENT section — the section-level analogue of
    /// `supersededRepetitionFails`. The `## Current operation` heading closes
    /// the historical scope (same level as `## ADR 014`), and its unqualified
    /// present-tense claim must fail — and be the only failure.
    @Test("a historical section does not excuse a later unqualified current-section claim")
    func historicalSectionDoesNotExcuseLaterUnqualifiedCurrentClaim() {
        let body = """
        # Storage architecture

        ## ADR 021: One database per wiki

        ADR 021 is accepted and supersedes ADR 014. The current architecture
        stores each wiki in its own SQLite database file, named by the wiki's
        ULID inside the app group container. Per-wiki databases let each wiki
        vacuum and migrate independently; the registry replaces cross-wiki
        joins, and the earlier design gave one backup target.

        ## ADR 014: One shared database for all wikis

        ADR 014 is recorded as accepted, but superseded by ADR 021. This page
        preserves ADR 014 as architectural history.

        ### Historical decision

        Self Driving Wiki stored every wiki in one shared SQLite database inside
        the app group container. The team selected a single shared database to
        provide one backup target.

        ## Current operation

        Self Driving Wiki stores every wiki in ONE shared SQLite database inside
        the app group container, and cross-wiki queries join without leaving the
        database file.
        """
        let evaluation = evaluateStorage(body)
        #expect(!evaluation.passed)
        #expect(
            failingCheckIDs(evaluation) == ["supersededInterpretation:Storage architecture"],
            "the unqualified current-section claim must be the only failure: \(evaluation.failedChecks.map(\.detail))")
    }

    /// Footnote definitions alone repeat superseded wording (verbatim source
    /// quotes, present tense, no qualifier anywhere in the line). They are
    /// citation evidence, so this page passes even without a historical
    /// section — under the old sentence scanner it failed.
    @Test("footnote source quotes alone are not current assertions")
    func footnoteSourceQuotesAloneAreNotCurrentAssertions() {
        let body = """
        # Storage architecture

        ## ADR 021: One database per wiki

        ADR 021 is accepted and supersedes ADR 014. The current architecture
        stores each wiki in its own SQLite database file, named by the wiki's
        ULID inside the app group container. Per-wiki databases let each wiki
        vacuum and migrate independently; the registry replaces cross-wiki
        joins, and ADR 014 chose its layout for one backup target.

        [^quote]: [[source:adr-014-storage-layout#"Self Driving Wiki stores every wiki in ONE shared SQLite database"|verbatim]] — "Self Driving Wiki stores every wiki in ONE shared SQLite database inside the app group container."
        """
        let evaluation = evaluateStorage(body)
        #expect(
            evaluation.passed,
            "footnote definitions are citation evidence, not assertions: \(evaluation.failedChecks.map(\.detail))")
    }

    @Test("wrong documentation strategy output fails the strategy-shape check")
    func wrongStrategyOutputFails() {
        let scenario = EvaluationFixtures.documentationStrategy
        // Leg 1 followed the how-to strategy. Leg 2 (the reference leg) is
        // wrong: it still numbers imperative steps.
        let leg1 = ObservedPage(
            id: PageID(rawValue: "01BM1"),
            title: "Bookmark sync",
            body: """
            How to sync bookmarks. Prerequisites: the wiki running. Steps:
            1. Run `bookmark sync --dry-run` to preview changes.
            2. Run `bookmark sync --prune` to apply them and delete vanished
            counterparts. Expected result: exit code 0
            ([[source:bookmark-sync-job.md]]).
            """,
            version: 1,
            updatedAt: Date(),
            historyDepth: 1,
            provenanceSourceNames: ["bookmark-sync-job.md"],
            citationNames: ["bookmark-sync-job.md"],
            sourceLinkNames: ["bookmark-sync-job.md"])
        let wrongLeg2 = ObservedPage(
            id: PageID(rawValue: "02BM2"),
            title: "Bookmark sync",
            body: """
            Step 1: run `bookmark sync --dry-run`. Step 2: run
            `bookmark sync --prune --config bookmarks.toml`. Exit codes 0 and 3
            are documented ([[source:bookmark-sync-job.md]]).
            """,
            version: 1,
            updatedAt: Date(),
            historyDepth: 1,
            provenanceSourceNames: ["bookmark-sync-job.md"],
            citationNames: ["bookmark-sync-job.md"],
            sourceLinkNames: ["bookmark-sync-job.md"])
        let evaluation = StructuralEvaluator().evaluate(
            scenario: scenario,
            input: EvaluationInput(before: WikiObservation(pages: [leg1], sources: []), after: WikiObservation(pages: [wrongLeg2], sources: [])))
        #expect(!evaluation.passed)
        #expect(failingCheckIDs(evaluation).contains("strategyShape:Bookmark sync"))
        // The wrong leg is still a different body, so the shape-difference
        // check itself passes — the failure names the strategy, not the
        // difference.
        #expect(!failingCheckIDs(evaluation).contains("differentOutputShape:Bookmark sync"))
    }

    // MARK: - Run-kind honesty

    @Test("canned results are never labeled live and never claim allPassed")
    func cannedResultsAreNeverLabeledLive() throws {
        let passing = evaluate(input(
            beforePage: beforePage(),
            afterPage: observedPage(body: conformingBody)))
        #expect(passing.passed)
        let cannedRecord = ScenarioResultRecord(
            metadata: ScenarioRunMetadata(
                runKind: .canned,
                scenarioID: .characterHistoryAcrossSources,
                startedAt: Date(),
                finishedAt: Date(),
                wikiID: "canned",
                databasePath: "/canned/fixture.sqlite"),
            evaluation: passing)
        let file = EvaluationResultsFile(runKind: .canned, generatedAt: Date(), results: [cannedRecord])
        #expect(file.runKind == .canned)
        // A canned run cannot earn the live all-passed verdict even when its
        // checks pass.
        #expect(!file.allPassed)

        let encoded = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(EvaluationResultsFile.self, from: encoded)
        #expect(decoded.runKind == .canned)
        let json = String(data: try JSONEncoder().encode(file), encoding: .utf8) ?? ""
        #expect(json.contains("\"runKind\":\"canned\""))
        #expect(!json.contains("\"runKind\":\"live\""))
    }

    @Test("all authored fixtures are well formed")
    func fixturesAreWellFormed() {
        for scenario in EvaluationFixtures.all {
            #expect(
                scenario.validationProblems.isEmpty,
                "\(scenario.id.rawValue): \(scenario.validationProblems.joined(separator: "; "))")
        }
    }

    // MARK: - Fixture/check key contract (drift guard)

    /// The recurring live-run failure: a check key drifted from the fixture
    /// file's actual name (`adr-014` vs `adr-014-storage-layout`) and the
    /// strict typed-id resolution failed only after the quota was spent.
    /// Every citation/provenance key must EQUAL an actual fixture filename
    /// stem — fix the fixture key, never loosen the evaluator's identity
    /// lookup.
    @Test("every citation/provenance key equals an actual fixture filename stem")
    func checkKeysEqualFixtureStemsExactly() {
        for scenario in EvaluationFixtures.all {
            let stems = scenario.batches.flatMap { $0 }
                .map { (($0.filename as NSString).deletingPathExtension).lowercased() }
            #expect(
                Set(stems).count == stems.count,
                "\(scenario.id.rawValue): duplicate filename stems make exact-key lookup ambiguous")
            for check in scenario.checks {
                let fragments: [String]
                switch check {
                case .citationsPresent(_, let sourceFragments): fragments = sourceFragments
                case .provenanceIncludes(_, let sourceFragments): fragments = sourceFragments
                default: continue
                }
                for fragment in fragments {
                    #expect(
                        stems.contains(fragment.lowercased()),
                        "\(scenario.id.rawValue): check key '\(fragment)' equals no fixture filename stem (stems: \(stems.joined(separator: ", ")))")
                }
            }
        }
    }

    @Test("both documentation strategies pin the stable page title")
    func documentationStrategiesPinStableTitle() {
        let scenario = EvaluationFixtures.documentationStrategy
        let strategies = [scenario.strategy, scenario.secondLegStrategy].compactMap { $0 }
        #expect(strategies.count == 2)
        for strategy in strategies {
            #expect(strategy.instructions.contains("Bookmark sync"))
            #expect(strategy.instructions.localizedCaseInsensitiveContains("stable page title"))
        }
    }

    // MARK: - boundedCancellation (plan AC.7)

    @Test("a body that runs past the budget is stopped and reported as timed out")
    func boundedCancellationTimesOut() async throws {
        let stopped = LockedFlag()
        let budget = EvaluationBudget(maxDuration: .milliseconds(150), maxTotalTokens: nil, maxCost: nil)
        do {
            _ = try await BoundedRunner.withBudget(
                budget,
                onTimeout: { stopped.set() }) {
                // A body that ignores cooperative cancellation up to the
                // force-stop: sleep far beyond the budget.
                try await Task.sleep(for: .seconds(30))
                return 1
            }
            Issue.record("expected a timeout error")
        } catch let limit as EvaluationRunLimit {
            guard case .timedOut = limit else {
                Issue.record("expected timedOut, got \(limit)")
                return
            }
            #expect(stopped.isSet())
        }
    }

    @Test("a body that finishes inside the budget returns normally")
    func boundedBodyCompletes() async throws {
        let stopped = LockedFlag()
        let value = try await BoundedRunner.withBudget(
            EvaluationBudget(maxDuration: .seconds(30), maxTotalTokens: nil, maxCost: nil),
            onTimeout: { stopped.set() }) {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }
        #expect(value == 42)
        #expect(!stopped.isSet())
    }

    @Test("a body error propagates unchanged")
    func bodyErrorPropagates() async throws {
        struct BodyFailure: Error, Equatable {}
        await #expect(throws: BodyFailure.self) {
            _ = try await BoundedRunner.withBudget(
                EvaluationBudget(maxDuration: .seconds(30), maxTotalTokens: nil, maxCost: nil)) {
                throw BodyFailure()
            }
        }
    }

    @Test("live gate stops on a crossing callback during a leg")
    func liveGateStopsDuringLeg() {
        let gate = LiveUsageBudgetGate(budget: EvaluationBudget(maxDuration: .seconds(30), maxTotalTokens: 1000, maxCost: nil))
        gate.beginLegUsage(UsageSnapshot(totalTokens: 0))
        #expect(gate.observe(UsageSnapshot(totalTokens: 900)) == nil)
        let failure = gate.observe(UsageSnapshot(totalTokens: 1100))
        #expect(failure == .tokenBudgetExceeded(limit: 1000, observed: 1100))
        gate.recordFailure(failure!)
        #expect(gate.failure() == failure)
    }

    @Test("live gate aggregates completed legs before checking current leg")
    func liveGateAggregatesPreviousLeg() {
        let gate = LiveUsageBudgetGate(budget: EvaluationBudget(maxDuration: .seconds(30), maxTotalTokens: 1000, maxCost: 5))
        gate.beginLegUsage(UsageSnapshot(totalTokens: 700, cost: 2))
        #expect(gate.observe(UsageSnapshot(totalTokens: 250, cost: 2)) == nil)
        let failure = gate.observe(UsageSnapshot(totalTokens: 400, cost: 4))
        #expect(failure == .tokenBudgetExceeded(limit: 1000, observed: 1100))
    }

    @Test("usage budget trips between runs")
    func usageBudgetTrips() async throws {
        let tracker = UsageBudgetTracker(budget: EvaluationBudget(
            maxDuration: .seconds(30), maxTotalTokens: 1000, maxCost: nil))
        try await tracker.observe(UsageSnapshot(totalTokens: 900))
        do {
            try await tracker.observe(UsageSnapshot(totalTokens: 1200))
            Issue.record("expected a token-budget error")
        } catch let limit as EvaluationRunLimit {
            guard case .tokenBudgetExceeded(let limitValue, let observed) = limit else {
                Issue.record("expected tokenBudgetExceeded, got \(limit)")
                return
            }
            #expect(limitValue == 1000)
            #expect(observed == 1200)
        }
    }
    // MARK: - Typed source identity (fixture stem → SourceID)

    /// Sources whose DISPLAY NAMES do not contain the check fragments — the
    /// live-run shape, where the agent cites by source id and display names
    /// are free-form ("Meridian — Chapter 3" never substring-matches
    /// "meridian-chapter-03"). Identity, not name matching, must satisfy the
    /// checks.
    private var typedSources: [ObservedSource] {
        [
            ObservedSource(id: SourceID(rawValue: "01S3"), name: "Meridian — Chapter 3", fixtureKey: "meridian-chapter-03"),
            ObservedSource(id: SourceID(rawValue: "01S7"), name: "Meridian — Chapter 7", fixtureKey: "meridian-chapter-07"),
        ]
    }

    private func typedInput(afterPage: ObservedPage) -> EvaluationInput {
        EvaluationInput(
            before: WikiObservation(pages: [beforePage(), homePage()], sources: typedSources),
            after: WikiObservation(pages: [afterPage, homePage()], sources: typedSources))
    }

    @Test("typed source ids satisfy citations and provenance without name-fragment matching")
    func typedSourceIdentityPasses() {
        let ch03 = SourceID(rawValue: "01S3")
        let ch07 = SourceID(rawValue: "01S7")
        let after = observedPage(
            body: conformingBody,
            provenance: [], sourceLinks: [],
            provenanceIDs: [ch03, ch07], sourceLinkIDs: [ch03, ch07])
        let evaluation = evaluate(typedInput(afterPage: after))
        #expect(failingCheckIDs(evaluation).filter { id in
            id.hasPrefix("citationsPresent") || id.hasPrefix("provenanceIncludes")
        }.isEmpty, "typed ids cover both distinct sources: \(evaluation.failedChecks.map(\.detail))")
        #expect(evaluation.passed)
    }

    @Test("a distinct source missing from the head provenance fails — no union with citations")
    func typedDistinctSourceOmissionFails() {
        let ch07 = SourceID(rawValue: "01S7")
        // The body still carries chapter-3 evidence (conformingBody), but the
        // database links and the head version's provenance record ONLY
        // chapter 7 — the real Mara failure shape. Neither the citation rows
        // nor the body may paper over the missing provenance edge.
        let after = observedPage(
            body: conformingBody,
            provenance: [], sourceLinks: [],
            provenanceIDs: [ch07], sourceLinkIDs: [ch07])
        let evaluation = evaluate(typedInput(afterPage: after))
        let failures = failingCheckIDs(evaluation)
        #expect(failures.contains("citationsPresent:Mara Voss"))
        #expect(failures.contains("provenanceIncludes:Mara Voss"))
        for checkID in ["citationsPresent:Mara Voss", "provenanceIncludes:Mara Voss"] {
            let detail = evaluation.failedChecks.first { $0.id == checkID }?.detail ?? ""
            #expect(detail.contains("meridian-chapter-03"), "\(checkID) must name the omitted source: \(detail)")
        }
    }

    @Test("a fragment with no typed id fails even when a display name contains it")
    func unresolvedTypedFragmentFailsDespiteNameMatch() {
        // Typed evidence exists, but NO fixture key equals the fragment. One
        // display name happens to CONTAIN the fragment — under the old
        // name-fallback this would silently pass; typed mode must fail and
        // name the mapping gap.
        let imposter = ObservedSource(
            id: SourceID(rawValue: "01IMPOSTER"),
            name: "meridian-chapter-03 (recovered copy)",
            fixtureKey: "unrelated-stem")
        let ch07 = ObservedSource(
            id: SourceID(rawValue: "01S7"),
            name: "Meridian — Chapter 7",
            fixtureKey: "meridian-chapter-07")
        let sources = [imposter, ch07]
        // The page links BOTH observed sources by typed id.
        let after = observedPage(
            body: conformingBody,
            provenance: [], sourceLinks: [],
            provenanceIDs: [imposter.id, ch07.id], sourceLinkIDs: [imposter.id, ch07.id])
        let evaluation = StructuralEvaluator().evaluate(
            scenario: EvaluationFixtures.characterHistory,
            input: EvaluationInput(
                before: WikiObservation(pages: [beforePage(), homePage()], sources: sources),
                after: WikiObservation(pages: [after, homePage()], sources: sources)))
        for checkID in ["citationsPresent:Mara Voss", "provenanceIncludes:Mara Voss"] {
            #expect(failingCheckIDs(evaluation).contains(checkID))
            let detail = evaluation.failedChecks.first { $0.id == checkID }?.detail ?? ""
            #expect(detail.contains("no typed source id for fixture key(s): meridian-chapter-03"),
                "\(checkID) must report the missing typed id: \(detail)")
        }
    }

    // MARK: - Character allow-set (legitimate run output)

    @Test("Ferrin and Ilya character pages are legitimate output, not unrelated edits")
    func characterPagesAreAllowedOutput() {
        func character(_ id: String, _ title: String) -> ObservedPage {
            ObservedPage(
                id: PageID(rawValue: id),
                title: title,
                body: "\(title) — fixture character page.",
                version: 1,
                updatedAt: Date(),
                historyDepth: 1,
                provenanceSourceNames: [],
                citationNames: [],
                sourceLinkNames: [])
        }
        let before = WikiObservation(
            pages: [beforePage(), homePage()],
            sources: typedSources.map { ObservedSource(id: $0.id, name: $0.name) })
        let after = WikiObservation(
            pages: [
                observedPage(body: conformingBody),
                character("01FERRIN", "Ferrin"),
                character("01ILYA", "Ilya Voss"),
                homePage(),
            ],
            sources: typedSources.map { ObservedSource(id: $0.id, name: $0.name) })
        let evaluation = StructuralEvaluator().evaluate(
            scenario: EvaluationFixtures.characterHistory,
            input: EvaluationInput(before: before, after: after))
        #expect(
            !failingCheckIDs(evaluation).contains("noUnrelatedPageEdits"),
            "the strategy's one-page-per-character rule makes Ferrin/Ilya pages expected output")
    }

    // MARK: - Codable compatibility (old canned JSON)

    @Test("old canned JSON without typed-id fields decodes with empty arrays")
    func legacyCannedJSONDecodes() throws {
        // The shape written before provenanceSourceIDs/sourceLinkIDs (and
        // before ObservedSource.fixtureKey) existed. The synthesized decoder
        // would throw keyNotFound for both arrays.
        let legacyJSON = """
        {"pages":[{"id":"01MARA","title":"Mara Voss","body":"body text","version":2,"updatedAt":0,"historyDepth":2,"provenanceSourceNames":["meridian-chapter-03.md"],"citationNames":["meridian-chapter-03.md"],"sourceLinkNames":["meridian-chapter-03.md"]}],"sources":[{"id":"01S3","name":"meridian-chapter-03.md"}]}
        """
        let observation = try JSONDecoder().decode(WikiObservation.self, from: Data(legacyJSON.utf8))
        let page = try #require(observation.pages.first)
        #expect(page.provenanceSourceIDs == [])
        #expect(page.sourceLinkIDs == [])
        let source = try #require(observation.sources.first)
        #expect(source.fixtureKey == nil)
        // Round-trip: the defaulted arrays re-encode explicitly and decode
        // back equal.
        let decoded = try JSONDecoder().decode(WikiObservation.self, from: JSONEncoder().encode(observation))
        #expect(decoded == observation)
    }

    // MARK: - Store-backed capture (current-head provenance)

    @Test("provenance is read from the store's current head, not history's final row")
    func provenanceFollowsActualHeadWhenHistoryBranches() throws {
        let store = try TestStoreFactory.inMemory()
        let ch03 = try store.addSource(
            filename: "meridian-chapter-03.md",
            data: Data("# Chapter 3\nMara is the chief cartographer.".utf8)).id
        let ch07 = try store.addSource(
            filename: "meridian-chapter-07.md",
            data: Data("# Chapter 7\nIlya confessed.".utf8)).id

        let pageID = try store.upsertPage(
            id: nil, title: "Mara Voss", rawBody: "v1 — accusation",
            expectation: .unrestricted, author: nil,
            provenance: [PageVersionSourceInput(sourceID: ch03, role: .primary)]).id
        let v1 = try #require(try store.pageHeadVersionID(pageID: pageID))
        _ = try store.upsertPage(
            id: pageID, title: "Mara Voss", rawBody: "v2 — correction",
            expectation: .expectedHead(v1), author: nil,
            provenance: [
                PageVersionSourceInput(sourceID: ch03, role: .primary),
                PageVersionSourceInput(sourceID: ch07, role: .supporting),
            ])
        let v2 = try #require(try store.pageHeadVersionID(pageID: pageID))
        _ = try store.upsertPage(
            id: pageID, title: "Mara Voss", rawBody: "v3 — rewrite that dropped chapter 3",
            expectation: .expectedHead(v2), author: nil,
            provenance: [PageVersionSourceInput(sourceID: ch07, role: .primary)])
        let v3 = try #require(try store.pageHeadVersionID(pageID: pageID))

        // Branch the history: `revertPage` repoints the head ref at v2
        // WITHOUT appending a version row, so the final history row (v3)
        // becomes a stale tip.
        try store.revertPage(pageID: pageID, to: v2)
        #expect(try store.pageHeadVersionID(pageID: pageID) == v2)
        let history = try store.pageVersionHistory(pageID: pageID)
        #expect(history.count == 3)
        #expect(try #require(history.last).id == v3)
        #expect(v2 != v3, "the premise: with branches possible, history's final row is not the head")

        let observation = try WikiObservationRecorder().capture(
            from: store,
            fixtureKeysBySourceID: [ch03: "meridian-chapter-03", ch07: "meridian-chapter-07"])
        let page = try #require(observation.page(titled: "Mara Voss").page)
        #expect(page.historyDepth == 3)
        #expect(
            Set(page.provenanceSourceIDs) == Set([ch03, ch07]),
            "provenance must come from the ACTUAL head (v2 cites both sources), not history.last (v3 cites only chapter 7)")
        // The fixture mapping is carried into the capture for identity checks.
        #expect(observation.sources.compactMap(\.fixtureKey).sorted()
            == ["meridian-chapter-03", "meridian-chapter-07"])
    }
}

/// Test-local thread-safe flag for the timeout hook.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func isSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
