import Foundation
import WikiFSCore
import WikiFSTypes

/// Why a bounded offline recheck refused to run. Every case names the exact
/// gap, so the operator sees what is missing instead of guessing.
public enum OfflineRecheckError: Error, Equatable, Sendable {
    /// Only a recorded LIVE run is recheckable. A canned or dry-run record
    /// never becomes offline recheck evidence.
    case recordedRunNotLive(runKind: String)
    /// The scenario has no record in the recorded results file.
    case scenarioRecordMissing(EvaluationScenarioID)
    /// The recorded run failed or did not deliver its strategy. Its artifact
    /// state does not support an honest recheck.
    case recordedScenarioIncomplete(String)
    /// The recorded artifact does not match the current fixture code: check
    /// ids or source filenames drifted. Re-evaluating a drifted fixture
    /// against old data would mislead, so the recheck refuses.
    case recordedFixtureMismatch(String)
    /// The artifact database does not exist at any recorded path.
    case artifactDatabaseMissing([String])
    /// The artifact's recorded source filenames do not map one-to-one onto
    /// the scenario's fixture filename stems (missing, extra, or ambiguous).
    case fixtureMappingIncomplete(String)

    public var localizedDescription: String {
        switch self {
        case .recordedRunNotLive(let runKind):
            "recorded run kind is \(runKind), not live — only a recorded live run supports an offline recheck"
        case .scenarioRecordMissing(let id):
            "no record for scenario \(id.rawValue) in the recorded results file"
        case .recordedScenarioIncomplete(let detail):
            "recorded run is incomplete: \(detail)"
        case .recordedFixtureMismatch(let detail):
            "recorded artifact does not match the current fixture: \(detail)"
        case .artifactDatabaseMissing(let paths):
            "no artifact database exists at any recorded path: \(paths.joined(separator: "; "))"
        case .fixtureMappingIncomplete(let detail):
            "fixture keys do not map onto the artifact database: \(detail)"
        }
    }
}

/// How one structural check was handled by the offline recheck.
public enum RecheckDisposition: Sendable, Equatable, Codable {
    /// After-only check: re-evaluated now, from the artifact database, with
    /// the CURRENT evaluator and fixture code.
    case reevaluated
    /// Before-dependent check. The recorded run's before snapshot is not
    /// persisted, so the recorded live outcome carries forward UNCHANGED,
    /// with the recorded run as its provenance.
    case carriedForward

    public var label: String {
        switch self {
        case .reevaluated: "re-evaluated offline"
        case .carriedForward: "carried from recorded live run"
        }
    }
}

/// One check's offline-recheck result.
public struct RecheckCheckOutcome: Sendable, Equatable, Codable {
    public let checkID: String
    public let disposition: RecheckDisposition
    public let outcome: CheckOutcome

    public init(checkID: String, disposition: RecheckDisposition, outcome: CheckOutcome) {
        self.checkID = checkID
        self.disposition = disposition
        self.outcome = outcome
    }

    public var passed: Bool { outcome.passed }
}

/// Every fact the recheck relied on. Each field is a recorded fact or a
/// read-only observation, never a re-derivation.
public struct OfflineRecheckProvenance: Sendable, Equatable, Codable {
    /// The results.json the recorded outcomes came from.
    public let recordedResultsPath: String
    /// Always "live": the recheck validates this before running.
    public let recordedRunKind: String
    public let recordedGeneratedAt: Date
    public let recordedScenarioStartedAt: Date
    public let recordedScenarioFinishedAt: Date
    public let recordedProviderLabel: String?
    public let recordedModelID: String?
    public let recordedWikiID: String
    /// The artifact database the re-evaluated checks read (read-only).
    public let artifactDatabasePath: String
    /// How fixture keys were derived for the identity-based checks.
    public let fixtureKeyDerivation: String

    public init(
        recordedResultsPath: String,
        recordedRunKind: String,
        recordedGeneratedAt: Date,
        recordedScenarioStartedAt: Date,
        recordedScenarioFinishedAt: Date,
        recordedProviderLabel: String?,
        recordedModelID: String?,
        recordedWikiID: String,
        artifactDatabasePath: String,
        fixtureKeyDerivation: String
    ) {
        self.recordedResultsPath = recordedResultsPath
        self.recordedRunKind = recordedRunKind
        self.recordedGeneratedAt = recordedGeneratedAt
        self.recordedScenarioStartedAt = recordedScenarioStartedAt
        self.recordedScenarioFinishedAt = recordedScenarioFinishedAt
        self.recordedProviderLabel = recordedProviderLabel
        self.recordedModelID = recordedModelID
        self.recordedWikiID = recordedWikiID
        self.artifactDatabasePath = artifactDatabasePath
        self.fixtureKeyDerivation = fixtureKeyDerivation
    }
}

/// The offline recheck of one recorded live scenario: one result per check,
/// the combined verdict, and the full provenance.
public struct OfflineRecheckRecord: Sendable, Codable {
    public let scenarioID: EvaluationScenarioID
    public let generatedAt: Date
    public let provenance: OfflineRecheckProvenance
    public let outcomes: [RecheckCheckOutcome]

    public init(
        scenarioID: EvaluationScenarioID,
        generatedAt: Date,
        provenance: OfflineRecheckProvenance,
        outcomes: [RecheckCheckOutcome]
    ) {
        self.scenarioID = scenarioID
        self.generatedAt = generatedAt
        self.provenance = provenance
        self.outcomes = outcomes
    }

    public var passed: Bool { outcomes.allSatisfy(\.passed) }

    public var reevaluatedCount: Int {
        outcomes.filter { $0.disposition == .reevaluated }.count
    }

    public var carriedForwardCount: Int {
        outcomes.filter { $0.disposition == .carriedForward }.count
    }

    // MARK: - Output

    /// Writes `recheck.report.md` and `recheck-results.json` into
    /// `directory`. The directory must be distinct from the recorded run's
    /// directory: the recheck never touches the recorded artifact.
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(self)
        try json.write(
            to: directory.appendingPathComponent("recheck-results.json"),
            options: [.atomic])

        let markdown = try markdownReport()
        guard let data = markdown.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(
            to: directory.appendingPathComponent("recheck.report.md"),
            options: [.atomic])
    }

    public func markdownReport() throws -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("# Offline recheck — \(scenarioID.displayName)")
        lines.append("")
        lines.append("- Recheck kind: **offlineRecheck (post-hoc)**. This is NOT a live run. No provider was contacted, no model ran, and no artifact row changed.")
        lines.append("- Combined verdict (structural): **\(passed ? "PASS" : "FAIL")**")
        lines.append("")
        lines.append("## Recorded run this recheck reads")
        lines.append("")
        lines.append("- Run kind: \(provenance.recordedRunKind)")
        lines.append("- Results file: `\(provenance.recordedResultsPath)`")
        lines.append("- Results generated: \(formatter.string(from: provenance.recordedGeneratedAt))")
        lines.append("- Scenario window: \(formatter.string(from: provenance.recordedScenarioStartedAt)) → \(formatter.string(from: provenance.recordedScenarioFinishedAt))")
        if let provider = provenance.recordedProviderLabel {
            lines.append("- Provider: \(provider)\(provenance.recordedModelID.map { " — model \($0)" } ?? "")")
        }
        lines.append("- Wiki: \(provenance.recordedWikiID)")
        lines.append("- Artifact database (opened read-only): `\(provenance.artifactDatabasePath)`")
        lines.append("- Fixture keys: \(provenance.fixtureKeyDerivation)")
        lines.append("")
        lines.append("## Checks")
        lines.append("")
        lines.append("| Check | Handled | Result | Detail |")
        lines.append("| --- | --- | --- | --- |")
        for result in outcomes {
            let detail = result.outcome.detail.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| `\(result.checkID)` | \(result.disposition.label) | \(result.passed ? "PASS" : "FAIL") | \(detail) |")
        }
        lines.append("")
        lines.append("## What this recheck claims, and what it does not")
        lines.append("")
        lines.append("- Re-evaluated rows use the CURRENT evaluator code against the recorded artifact database, opened read-only.")
        lines.append("- Carried rows are the recorded live outcomes, unchanged. The recorded run did not persist its before snapshot, so a check that compares snapshots cannot be re-derived. No before snapshot was invented.")
        lines.append("- The check-id and source-filename guards verified the recorded artifact matches the current fixture code before any check ran.")
        lines.append("- A structural pass is not a semantic pass. The plan's human rubric stays a human decision; this recheck answers no rubric question.")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

/// Runs a bounded offline recheck of one recorded live scenario against its
/// retained artifact database. Deterministic and free: no provider, no
/// model, no network, and no write to the artifact or to any live wiki. The
/// store opens read-only through the store factory seam
/// (``StoreBackend/makeReadOnlyStore(readOnlyURL:)``), so this file never
/// constructs the concrete store.
///
/// What a recheck is FOR: a corrected evaluator must be able to re-derive
/// the after-only checks from the recorded artifact without a fresh paid
/// run, while the before-dependent checks carry their recorded outcomes
/// forward with exact provenance. Historical outcomes are preserved: the
/// recheck writes only new outputs, never into the recorded run directory.
public struct OfflineRecheckRunner: Sendable {

    public init() {}

    /// - Parameters:
    ///   - scenario: The CURRENT fixture code for the scenario.
    ///   - recordedResults: The decoded results.json of the recorded run.
    ///   - recordedResultsPath: Path of that file, recorded as provenance.
    ///   - artifactDatabaseURL: The recorded run's final-leg wiki database,
    ///     opened read-only.
    ///   - openStore: Opens the artifact database. The default opens a
    ///     read-only GRDB store; tests inject an in-memory store.
    public func recheck(
        scenario: EvaluationScenario,
        recordedResults: EvaluationResultsFile,
        recordedResultsPath: String,
        artifactDatabaseURL: URL,
        openStore: (URL) throws -> any WikiStore = { url in
            try StoreBackend.current.makeReadOnlyStore(readOnlyURL: url)
        }
    ) throws -> OfflineRecheckRecord {
        // 1. The recorded file must be a live run.
        guard recordedResults.runKind == .live else {
            throw OfflineRecheckError.recordedRunNotLive(runKind: recordedResults.runKind.rawValue)
        }

        // 2. The scenario must have a complete record.
        guard let record = recordedResults.results.first(where: { $0.metadata.scenarioID == scenario.id })
        else {
            throw OfflineRecheckError.scenarioRecordMissing(scenario.id)
        }
        let meta = record.metadata
        guard meta.runKind == .live else {
            throw OfflineRecheckError.recordedRunNotLive(runKind: meta.runKind.rawValue)
        }
        if let error = meta.error {
            throw OfflineRecheckError.recordedScenarioIncomplete("recorded error: \(error)")
        }
        guard meta.strategyDelivered else {
            throw OfflineRecheckError.recordedScenarioIncomplete("recorded run did not deliver its strategy")
        }

        // 3. The recorded artifact must match the current fixture code.
        //    Outcomes pair positionally with the scenario's checks, so the
        //    counts and ids must line up exactly.
        let recordedOutcomes = record.evaluation.outcomes
        guard recordedOutcomes.count == scenario.checks.count else {
            throw OfflineRecheckError.recordedFixtureMismatch(
                "recorded \(recordedOutcomes.count) outcome(s), the current fixture declares \(scenario.checks.count) check(s)")
        }
        for (index, check) in scenario.checks.enumerated() {
            let expected = Self.expectedCheckID(check)
            let recorded = recordedOutcomes[index].id
            guard recorded == expected else {
                throw OfflineRecheckError.recordedFixtureMismatch(
                    "check \(index) recorded id '\(recorded)' but the current fixture expects '\(expected)'")
            }
        }
        //    The recorded leg evidence must name exactly the fixture's source
        //    filenames — an artifact from a different fixture refuses.
        guard let legs = meta.legs, !legs.isEmpty else {
            throw OfflineRecheckError.recordedFixtureMismatch(
                "the recorded run carries no leg evidence, so its source filenames cannot be verified against the fixture")
        }
        let recordedFilenames = Set(legs.flatMap { leg in leg.batches.flatMap(\.sourceFilenames) })
        let fixtureFilenames = Set(scenario.batches.flatMap { batch in batch.map(\.filename) })
        guard recordedFilenames == fixtureFilenames else {
            throw OfflineRecheckError.recordedFixtureMismatch(
                "recorded source filenames \(recordedFilenames.sorted()) differ from fixture filenames \(fixtureFilenames.sorted())")
        }

        // 4. The artifact database must exist.
        guard FileManager.default.fileExists(atPath: artifactDatabaseURL.path) else {
            throw OfflineRecheckError.artifactDatabaseMissing([artifactDatabaseURL.path])
        }

        // 5. Fixture keys come from the artifact's own recorded source
        //    filenames (stems), the same derivation the live runner used at
        //    import time. Every fixture stem must resolve to exactly one
        //    observed source; anything else refuses.
        let store = try openStore(artifactDatabaseURL)
        let summaries = try store.listSources()
        var sourcesByStem: [String: [SourceID]] = [:]
        for summary in summaries {
            let stem = (summary.filename as NSString).deletingPathExtension
            sourcesByStem[stem, default: []].append(summary.id)
        }
        var fixtureKeysBySourceID: [SourceID: String] = [:]
        let fixtureStems = Set(fixtureFilenames.map { ($0 as NSString).deletingPathExtension })
        for stem in fixtureStems.sorted() {
            guard let ids = sourcesByStem[stem], ids.count == 1 else {
                let observed = summaries.map(\.filename).sorted()
                throw OfflineRecheckError.fixtureMappingIncomplete(
                    "fixture stem \(stem) resolves to no unique source in the artifact database — observed filenames: \(observed.joined(separator: ", "))")
            }
            fixtureKeysBySourceID[ids[0]] = stem
        }
        let observedStems = Set(sourcesByStem.keys)
        guard observedStems == fixtureStems else {
            throw OfflineRecheckError.fixtureMappingIncomplete(
                "artifact sources \(observedStems.sorted()) do not match fixture stems \(fixtureStems.sorted())")
        }

        // 6. Capture the final state and re-evaluate.
        let after = try WikiObservationRecorder().capture(
            from: store, fixtureKeysBySourceID: fixtureKeysBySourceID)
        let evaluator = StructuralEvaluator()
        var outcomes: [RecheckCheckOutcome] = []
        for (index, check) in scenario.checks.enumerated() {
            let recorded = recordedOutcomes[index]
            if check.requiresBeforeSnapshot {
                outcomes.append(RecheckCheckOutcome(
                    checkID: recorded.id, disposition: .carriedForward, outcome: recorded))
            } else if let reevaluated = evaluator.evaluate(check: check, after: after) {
                outcomes.append(RecheckCheckOutcome(
                    checkID: reevaluated.id, disposition: .reevaluated, outcome: reevaluated))
            } else {
                // Unreachable: requiresBeforeSnapshot is the exact inverse of
                // evaluate(check:after:)'s nil contract. Fail loudly rather
                // than silently pairing a check with the wrong disposition.
                throw OfflineRecheckError.recordedFixtureMismatch(
                    "check \(recorded.id) is after-only per the fixture but the evaluator classified it before-dependent")
            }
        }

        return OfflineRecheckRecord(
            scenarioID: scenario.id,
            generatedAt: Date(),
            provenance: OfflineRecheckProvenance(
                recordedResultsPath: recordedResultsPath,
                recordedRunKind: recordedResults.runKind.rawValue,
                recordedGeneratedAt: recordedResults.generatedAt,
                recordedScenarioStartedAt: meta.startedAt,
                recordedScenarioFinishedAt: meta.finishedAt,
                recordedProviderLabel: meta.providerLabel,
                recordedModelID: meta.modelID,
                recordedWikiID: meta.wikiID,
                artifactDatabasePath: artifactDatabaseURL.path,
                fixtureKeyDerivation: "derived from the sources.filename rows recorded in the artifact database (stems, one source per stem)"),
            outcomes: outcomes)
    }

    /// The evaluator's own id convention (see `StructuralEvaluator`'s check
    /// implementations), including the `:leg1` suffix the evaluator uses for
    /// a first-leg strategy-shape check.
    static func expectedCheckID(_ check: StructuralCheck) -> String {
        switch check {
        case .retainedFact(let title, _): "retainedFact:\(title)"
        case .unsupportedClaim(let title, _): "unsupportedClaim:\(title)"
        case .supersededInterpretation(let title, _, _, _): "supersededInterpretation:\(title)"
        case .citationsPresent(let title, _): "citationsPresent:\(title)"
        case .stablePageIdentity(let title): "stablePageIdentity:\(title)"
        case .noUnrelatedPageEdits: "noUnrelatedPageEdits"
        case .historyDepth(let title, _): "historyDepth:\(title)"
        case .provenanceIncludes(let title, _): "provenanceIncludes:\(title)"
        case .strategyShape(let title, _, _, let firstLeg):
            "strategyShape:\(title)\(firstLeg ? ":leg1" : "")"
        case .differentOutputShape(let title): "differentOutputShape:\(title)"
        }
    }
}
