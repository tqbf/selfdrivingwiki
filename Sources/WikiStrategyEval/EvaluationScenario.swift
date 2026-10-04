import Foundation
import WikiFSTypes

/// The identifier of one live semantic evaluation scenario. The raw values are
/// the scenario names the durable plan requires for AC.7.
public enum EvaluationScenarioID: String, CaseIterable, Sendable, Codable {
    /// Source A establishes a character fact plus an initial interpretation;
    /// source B retains the fact and corrects the interpretation. Measures
    /// evidence retention, contradiction reconciliation, and history.
    case characterHistoryAcrossSources
    /// Source A documents a repository decision with rationale; source B
    /// supersedes it. Measures stated-vs-superseded decision handling.
    case supersededRepositoryDecision
    /// Identical evidence ingested twice under two different wiki strategies
    /// (tutorial-shaped, then reference-shaped). Measures whether editorial
    /// instructions actually change the output's shape.
    case sameEvidenceDifferentDocumentationStrategy

    public var displayName: String {
        switch self {
        case .characterHistoryAcrossSources: "Character history across sources"
        case .supersededRepositoryDecision: "Superseded repository decision"
        case .sameEvidenceDifferentDocumentationStrategy:
            "Same evidence under different documentation strategies"
        }
    }
}

/// One authored Markdown source imported into the fixture wiki. The file name
/// is also the citation target the evaluator matches against.
public struct EvaluationSourceFixture: Sendable, Equatable, Codable {
    /// File name with extension, e.g. `mara-chapter-03.md`. The stem is a
    /// distinctive citation fragment.
    public let filename: String
    /// The authored Markdown body.
    public let markdown: String

    public init(filename: String, markdown: String) {
        self.filename = filename
        self.markdown = markdown
    }
}

/// One wiki strategy document applied before a run (plan Phase 1). This is the
/// editorial instruction text, not a permission or safety override.
public struct EvaluationStrategyFixture: Sendable, Equatable, Codable {
    public let name: String
    public let instructions: String

    public init(name: String, instructions: String) {
        self.name = name
        self.instructions = instructions
    }
}

/// One deterministic structural assertion. All phrase matching is
/// case-insensitive substring matching against the observed page body; source
/// fragments match citation or provenance names by substring too. Every case
/// is evaluated by ``StructuralEvaluator`` without a model.
public enum StructuralCheck: Sendable, Equatable, Codable {
    /// Fixture facts the final body must retain (evidence-drop detection).
    case retainedFact(pageTitle: String, phrases: [String])
    /// Phrases with no evidence in any fixture source; their presence is an
    /// unsupported claim. FIXTURE-SPECIFIC HEURISTIC, not a general
    /// unsupported-claims guarantee: it can only catch the invented phrases
    /// the fixture enumerates. The human rubric is the authoritative
    /// unsupported-claims review.
    case unsupportedClaim(pageTitle: String, phrases: [String])
    /// The corrected interpretation must be present. When a superseded phrase
    /// is retained, at least one qualifier word (previously, believed,
    /// earlier, initially, originally, superseded, formerly, mistakenly, or a
    /// chapter/ADR reference) must qualify it — otherwise the page asserts the
    /// superseded interpretation as current truth.
    case supersededInterpretation(
        pageTitle: String,
        correctedPhrases: [String],
        supersededPhrases: [String],
        qualifiers: [String])
    /// The page must cite every named fixture source: a `[[source:…]]` link
    /// whose target contains each fragment.
    case citationsPresent(pageTitle: String, sourceFragments: [String])
    /// Exactly one page resolves per run snapshot and its `PageID` never
    /// changes across the run's snapshots (stable identity; recreated pages
    /// fail).
    case stablePageIdentity(pageTitle: String)
    /// Pages outside `allowedTitles` (matched by title fragment) must be
    /// byte-identical across the compared snapshots. Index and log updates
    /// belong in `allowedTitles`.
    case noUnrelatedPageEdits(allowedTitleFragments: [String])
    /// The page's version history must record at least `minimumVersions`
    /// versions (A-then-B reconciliation should rewrite, not create anew).
    case historyDepth(pageTitle: String, minimumVersions: Int)
    /// The page's LATEST version provenance must include every fixture
    /// source whose evidence the body still carries.
    case provenanceIncludes(pageTitle: String, sourceFragments: [String])
    /// Strategy-shape markers: required phrases present, forbidden phrases
    /// absent (wrong-strategy detection for the documentation-strategy
    /// scenario). `firstLeg` evaluates against the FIRST snapshot (the
    /// how-to-guide leg) instead of the last (the reference leg).
    case strategyShape(
        pageTitle: String,
        requiredPhrases: [String],
        forbiddenPhrases: [String],
        firstLeg: Bool)
    /// The same-titled page must differ between two runs of the same evidence
    /// under different strategies (normalized whitespace/case compare) — a
    /// strategy that changed nothing observable.
    case differentOutputShape(pageTitle: String)

    /// Whether this check compares the run's before and after snapshots.
    /// After-only checks re-derive from one final-state snapshot. A check
    /// that needs both cannot be re-derived from a final-state artifact:
    /// the recorded runs do not persist their before snapshots, so an
    /// offline recheck carries the recorded outcome forward instead of
    /// inventing a before snapshot.
    public var requiresBeforeSnapshot: Bool {
        switch self {
        case .retainedFact, .unsupportedClaim, .supersededInterpretation,
             .citationsPresent, .historyDepth, .provenanceIncludes:
            false
        case .stablePageIdentity, .noUnrelatedPageEdits, .differentOutputShape:
            true
        case .strategyShape(_, _, _, let firstLeg):
            firstLeg
        }
    }
}

/// A question a human answers against the produced page; machine results never
/// answer it. Recorded in the readable report beside the structural results.
public struct RubricQuestion: Sendable, Equatable, Codable {
    public let question: String
    public let lookFor: String

    public init(question: String, lookFor: String) {
        self.question = question
        self.lookFor = lookFor
    }
}

/// One complete, self-contained scenario: sources imported in order, the
/// strategy applied before the first import, the deterministic assertions, and
/// the human rubric. Two-source scenarios ingest A, run, ingest B, run again
/// (`successiveSources`); the strategy scenario runs the SAME single source
/// twice in two fresh wikis with different strategies.
public struct EvaluationScenario: Sendable, Equatable, Codable {
    public let id: EvaluationScenarioID
    public let strategy: EvaluationStrategyFixture
    /// Import batches in order. `characterHistoryAcrossSources` and
    /// `supersededRepositoryDecision` carry two one-source batches;
    /// `sameEvidenceDifferentDocumentationStrategy` carries one source used
    /// by both legs plus a `secondLegStrategy`.
    public let batches: [[EvaluationSourceFixture]]
    /// The second leg's strategy (documentation-strategy scenario only).
    public let secondLegStrategy: EvaluationStrategyFixture?
    public let checks: [StructuralCheck]
    public let rubric: [RubricQuestion]

    public init(
        id: EvaluationScenarioID,
        strategy: EvaluationStrategyFixture,
        batches: [[EvaluationSourceFixture]],
        secondLegStrategy: EvaluationStrategyFixture? = nil,
        checks: [StructuralCheck],
        rubric: [RubricQuestion]
    ) {
        self.id = id
        self.strategy = strategy
        self.batches = batches
        self.secondLegStrategy = secondLegStrategy
        self.checks = checks
        self.rubric = rubric
    }

    /// Well-formed for live execution: every batch non-empty, every source
    /// non-blank with a distinctive filename stem, at least one check, and a
    /// non-empty rubric. The runner refuses to execute a malformed fixture
    /// rather than producing a meaningless report.
    public var validationProblems: [String] {
        var problems: [String] = []
        if batches.isEmpty { problems.append("no import batches") }
        for (index, batch) in batches.enumerated() where batch.isEmpty {
            problems.append("batch \(index) is empty")
        }
        for batch in batches {
            for source in batch {
                if source.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    problems.append("\(source.filename): empty markdown body")
                }
                let stem = (source.filename as NSString).deletingPathExtension
                if stem.isEmpty || stem.count < 4 {
                    problems.append("\(source.filename): filename stem too short to be a distinctive citation fragment")
                }
            }
        }
        if strategy.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("strategy instructions are empty")
        }
        if checks.isEmpty { problems.append("no structural checks") }
        if rubric.isEmpty { problems.append("no rubric questions") }
        if id == .sameEvidenceDifferentDocumentationStrategy && secondLegStrategy == nil {
            problems.append("documentation-strategy scenario requires a second leg strategy")
        }
        return problems
    }
}
