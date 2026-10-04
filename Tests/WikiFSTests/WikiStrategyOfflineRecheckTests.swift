import Foundation
import Testing
@testable import WikiFSCore
@testable import WikiStrategyEval

/// Bounded offline recheck of a recorded live scenario (independent review
/// finding F3): the after-only checks re-evaluate from the retained artifact
/// database with the current evaluator code, read-only; the before-dependent
/// checks carry their recorded outcomes forward unchanged with exact
/// provenance. These tests prove the happy path against a real file-backed
/// store opened read-only, and every refusal path: a non-live record, a
/// missing scenario record, an incomplete run, fixture drift, a missing
/// artifact database, and a fixture-mapping gap. No provider is contacted.
@Suite("Wiki strategy offline recheck", .serialized, .timeLimit(.minutes(2)))
struct WikiStrategyOfflineRecheckTests {

    private var scenario: EvaluationScenario { EvaluationFixtures.supersededDecision }

    // MARK: - Recorded-run builders

    /// The recorded outcomes of the 2026-10-03T002006Z repository run shape:
    /// everything PASS except `supersededInterpretation`, which the then-old
    /// heuristic failed. The before-dependent rows carry the recorded
    /// verbatim details the recheck must preserve.
    private func recordedOutcomes(oldHeuristicFailure: Bool = true) -> [CheckOutcome] {
        scenario.checks.map { check in
            let id = OfflineRecheckRunner.expectedCheckID(check)
            switch id {
            case "supersededInterpretation:Storage architecture":
                return CheckOutcome(
                    id: id,
                    passed: !oldHeuristicFailure,
                    detail: oldHeuristicFailure
                        ? "superseded interpretation presented as current truth without a qualifier: 'ONE shared SQLite database', 'single shared database'"
                        : "corrected account present; superseded phrasing kept out of current assertions")
            case "stablePageIdentity:Storage architecture":
                return CheckOutcome(id: id, passed: true, detail: "'Storage architecture' kept PageID 01M3ZJ5834PD64ZMM3M4PD025W")
            case "noUnrelatedPageEdits":
                return CheckOutcome(id: id, passed: true, detail: "no page outside Storage architecture, Index changed")
            default:
                return CheckOutcome(id: id, passed: true, detail: "recorded live outcome")
            }
        }
    }

    private func recordedResultsFile(
        outcomes: [CheckOutcome]? = nil,
        runKind: EvaluationRunKind = .live,
        scenarioError: String? = nil,
        strategyDelivered: Bool = true,
        includeScenario: Bool = true
    ) -> EvaluationResultsFile {
        let metadata = ScenarioRunMetadata(
            runKind: runKind,
            scenarioID: .supersededRepositoryDecision,
            startedAt: Date(timeIntervalSince1970: 1_759_479_666),
            finishedAt: Date(timeIntervalSince1970: 1_759_479_767),
            wikiID: "01M3ZJ3SF7D3PTZ5JY6HKBJXND",
            databasePath: "/recorded/supersededRepositoryDecision/run/01M3ZJ3SF7D3PTZ5JY6HKBJXND.sqlite",
            providerID: "codex-acp",
            providerLabel: "Codex",
            modelID: "gpt-5.6-luna[high]",
            stateMarkdown: "",
            error: scenarioError,
            strategyDelivered: strategyDelivered,
            legs: [
                EvaluationLegRecord(
                    label: "run",
                    strategyName: scenario.strategy.name,
                    wikiID: "01M3ZJ3SF7D3PTZ5JY6HKBJXND",
                    databasePath: "/recorded/supersededRepositoryDecision/run/01M3ZJ3SF7D3PTZ5JY6HKBJXND.sqlite",
                    batches: [
                        EvaluationBatchRecord(
                            index: 0, legLabel: "run",
                            sourceFilenames: ["adr-014-storage-layout.md"],
                            stateMarkdown: "",
                            startedAt: Date(timeIntervalSince1970: 1_759_479_666),
                            finishedAt: Date(timeIntervalSince1970: 1_759_479_700)),
                        EvaluationBatchRecord(
                            index: 1, legLabel: "run",
                            sourceFilenames: ["adr-021-per-wiki-databases.md"],
                            stateMarkdown: "",
                            startedAt: Date(timeIntervalSince1970: 1_759_479_701),
                            finishedAt: Date(timeIntervalSince1970: 1_759_479_767)),
                    ])
            ])
        let record = ScenarioResultRecord(
            metadata: metadata,
            evaluation: ScenarioEvaluation(scenarioID: .supersededRepositoryDecision, outcomes: outcomes ?? recordedOutcomes()))
        return EvaluationResultsFile(
            runKind: runKind,
            generatedAt: Date(timeIntervalSince1970: 1_759_479_789),
            results: includeScenario ? [record] : [])
    }

    // MARK: - Artifact builders

    /// A real file-backed store holding the repository scenario's final
    /// state: both fixture sources (recorded by filename, exactly like the
    /// live artifact) and a two-version "Storage architecture" page whose
    /// head records both sources and whose superseded phrasing sits inside a
    /// qualified historical section. The body cites by `SourceID`, like the
    /// live artifacts.
    private func seedRepositoryArtifact(includeADR021: Bool = true) throws -> (store: GRDBWikiStore, url: URL) {
        let seeded = try TestStoreFactory.fileBacked(prefix: "recheck-artifact")
        let store = seeded.store
        let adr014 = try store.addSource(
            filename: "adr-014-storage-layout.md",
            data: Data(scenario.batches[0][0].markdown.utf8)).id
        var adr021: SourceID?
        if includeADR021 {
            adr021 = try store.addSource(
                filename: "adr-021-per-wiki-databases.md",
                data: Data(scenario.batches[1][0].markdown.utf8)).id
        }

        // Version 1: the ADR 014 world, as batch A left it.
        _ = try store.upsertPage(
            id: nil,
            title: "Storage architecture",
            rawBody: """
            # Storage architecture

            Self Driving Wiki stores every wiki in one shared SQLite database
            inside the app group container. [[source:\(adr014.rawValue)]]
            """,
            expectation: .unrestricted,
            author: nil,
            provenance: [PageVersionSourceInput(sourceID: adr014, role: .primary)])

        guard let adr021 else { return (store, seeded.url) }

        // Version 2 (head): ADR 021 current, ADR 014 kept as a qualified
        // historical section — the shape the corrected heuristic accepts.
        _ = try store.upsertPage(
            id: nil,
            title: "Storage architecture",
            rawBody: """
            # Storage architecture

            ADR 021 supersedes ADR 014. Self Driving Wiki stores each wiki in its OWN SQLite database file.
            [[source:\(adr021.rawValue)]] The file is named by the wiki's ULID inside the app
            group container. Per-wiki databases let each wiki vacuum and migrate independently.

            ## ADR 014: One shared database for all wikis

            ADR 014 is superseded history. Self Driving Wiki previously stored every
            wiki in one shared SQLite database inside the app group container.
            [[source:\(adr014.rawValue)]] Its rationale: one backup target, and
            cross-wiki queries without leaving the database file.
            """,
            expectation: .unrestricted,
            author: nil,
            provenance: [
                PageVersionSourceInput(sourceID: adr014, role: .supporting),
                PageVersionSourceInput(sourceID: adr021, role: .primary),
            ])
        return (store, seeded.url)
    }

    @discardableResult
    private func runRecheck(
        results: EvaluationResultsFile,
        includeADR021: Bool = true,
        artifactURL: URL? = nil
    ) throws -> OfflineRecheckRecord {
        let seeded = try seedRepositoryArtifact(includeADR021: includeADR021)
        let url = artifactURL ?? seeded.url
        return try OfflineRecheckRunner().recheck(
            scenario: scenario,
            recordedResults: results,
            recordedResultsPath: "/recorded/results.json",
            artifactDatabaseURL: url,
            openStore: { _ in try GRDBWikiStore(readOnlyURL: seeded.url) })
    }

    // MARK: - Happy path

    @Test("re-evaluates after-only checks read-only and carries before-dependent checks unchanged")
    func reevaluatesAndCarriesForward() throws {
        let results = recordedResultsFile()
        let recheck = try runRecheck(results: results)

        // Combined verdict: the corrected heuristic passes the re-evaluated
        // superseded check; the carried rows were already PASS.
        #expect(recheck.passed)
        #expect(recheck.reevaluatedCount == 7)
        #expect(recheck.carriedForwardCount == 2)

        let superseded = try #require(
            recheck.outcomes.first { $0.checkID == "supersededInterpretation:Storage architecture" })
        #expect(superseded.disposition == .reevaluated)
        #expect(superseded.passed)
        #expect(superseded.outcome.detail.contains("kept out of current assertions"))

        let identity = try #require(
            recheck.outcomes.first { $0.checkID == "stablePageIdentity:Storage architecture" })
        #expect(identity.disposition == .carriedForward)
        #expect(identity.passed)
        // The recorded outcome is carried forward VERBATIM.
        #expect(identity.outcome.detail == "'Storage architecture' kept PageID 01M3ZJ5834PD64ZMM3M4PD025W")

        let unrelated = try #require(recheck.outcomes.first { $0.checkID == "noUnrelatedPageEdits" })
        #expect(unrelated.disposition == .carriedForward)
        #expect(unrelated.outcome.detail == "no page outside Storage architecture, Index changed")

        // Provenance names the recorded run and the read-only artifact.
        #expect(recheck.provenance.recordedResultsPath == "/recorded/results.json")
        #expect(recheck.provenance.recordedRunKind == "live")
        #expect(recheck.provenance.recordedProviderLabel == "Codex")
        #expect(recheck.provenance.recordedModelID == "gpt-5.6-luna[high]")

        // The report states what it is and what it refuses to claim.
        let markdown = try recheck.markdownReport()
        #expect(markdown.contains("offlineRecheck (post-hoc)"))
        #expect(markdown.contains("NOT a live run"))
        #expect(markdown.contains("carried from recorded live run"))
        #expect(markdown.contains("No before snapshot was invented"))
    }

    // MARK: - Refusals

    @Test("refuses a canned or dry-run record")
    func refusesNonLiveRecord() {
        for kind in [EvaluationRunKind.canned, .dryRun] {
            #expect(throws: OfflineRecheckError.recordedRunNotLive(runKind: kind.rawValue)) {
                _ = try runRecheck(results: recordedResultsFile(runKind: kind))
            }
        }
    }

    @Test("refuses when the scenario has no record")
    func refusesMissingScenarioRecord() {
        #expect(throws: OfflineRecheckError.scenarioRecordMissing(.supersededRepositoryDecision)) {
            _ = try runRecheck(results: recordedResultsFile(includeScenario: false))
        }
    }

    @Test("refuses an incomplete recorded run")
    func refusesIncompleteRecord() throws {
        for variant in 0..<2 {
            let results = variant == 0
                ? recordedResultsFile(scenarioError: "agent turn failed")
                : recordedResultsFile(strategyDelivered: false)
            do {
                _ = try runRecheck(results: results)
                Issue.record("variant \(variant): recheck should have refused")
            } catch let error as OfflineRecheckError {
                guard case .recordedScenarioIncomplete = error else {
                    Issue.record("variant \(variant): expected recordedScenarioIncomplete, got \(error)")
                    continue
                }
            }
        }
    }

    @Test("refuses fixture drift between the record and the current fixture code")
    func refusesFixtureDrift() throws {
        // One recorded outcome short of the current fixture's check list.
        let drifted = Array(recordedOutcomes().dropLast())
        do {
            _ = try runRecheck(results: recordedResultsFile(outcomes: drifted))
            Issue.record("recheck should have refused drifted outcomes")
        } catch let error as OfflineRecheckError {
            guard case .recordedFixtureMismatch = error else {
                Issue.record("expected recordedFixtureMismatch, got \(error)")
                return
            }
        }
    }

    @Test("refuses a missing artifact database")
    func refusesMissingArtifactDatabase() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/recheck-artifact.sqlite")
        do {
            _ = try runRecheck(
                results: recordedResultsFile(),
                artifactURL: missing)
            Issue.record("recheck should have refused a missing artifact database")
        } catch let error as OfflineRecheckError {
            guard case .artifactDatabaseMissing = error else {
                Issue.record("expected artifactDatabaseMissing, got \(error)")
                return
            }
        }
    }

    @Test("refuses when the artifact's sources do not map onto the fixture stems")
    func refusesFixtureMappingGap() throws {
        // The artifact holds only one of the two fixture sources.
        do {
            _ = try runRecheck(results: recordedResultsFile(), includeADR021: false)
            Issue.record("recheck should have refused the mapping gap")
        } catch let error as OfflineRecheckError {
            guard case .fixtureMappingIncomplete = error else {
                Issue.record("expected fixtureMappingIncomplete, got \(error)")
                return
            }
        }
    }
}
