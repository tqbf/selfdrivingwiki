import Foundation
import WikiFSLinks

/// How strongly a mechanical finding asserts its fact (REQ-40: findings
/// expose evidence, severity, and confidence without declaring author
/// intent).
public enum LintConfidence: String, Sendable {
    /// A deterministic fact (conflict marker, whole-body fence, unresolvable
    /// ULID target).
    case confirmed
    /// A candidate: the pattern matches but intent or identity needs
    /// judgment (suspicious indentation, ambiguous source name).
    case candidate
}

/// Finding severity — how badly the defect damages the page's validity.
public enum LintSeverity: String, Sendable, Comparable {
    /// Rendering is broken or content is being misread (fence damage,
    /// whole-body wrap).
    case critical
    /// A reference or structure is broken but surrounding text stays
    /// readable (missing target, duplicate footnotes).
    case major
    /// Localized damage that does not break the page (escaping residue,
    /// placeholder candidates).
    case minor

    public static func < (lhs: LintSeverity, rhs: LintSeverity) -> Bool {
        let order: [LintSeverity: Int] = [.critical: 0, .major: 1, .minor: 2]
        return (order[lhs] ?? 9) < (order[rhs] ?? 9)
    }
}

/// A candidate repair a mechanical finding may carry when exactly one safe
/// replacement exists (REQ-40). A proposal is NOT a declaration of intent
/// and never by itself authorizes a write — the patch write (Phase 3) and
/// the operation policy decide that.
public struct LintCandidateRepair: Equatable, Sendable {
    /// The replacement shape, expressed against the finding's authored range.
    public enum Change: Equatable, Sendable {
        /// Delete the finding's range.
        case deletion
        /// Replace the finding's range with exact text.
        case replacement(text: String)
        /// Insert text at a UTF-8 byte offset (e.g. a missing closing fence).
        case insertion(offset: Int, text: String)
    }

    public let change: Change
    /// The validity reason this repair would carry on its hunk (REQ-07).
    public let reason: String
    /// Source inputs a citation-adding repair must declare (REQ-17/REQ-54).
    public let additionalSourceInputs: [PageVersionSourceInput]

    public init(
        change: Change,
        reason: String,
        additionalSourceInputs: [PageVersionSourceInput] = []
    ) {
        self.change = change
        self.reason = reason
        self.additionalSourceInputs = additionalSourceInputs
    }
}

/// One mechanical finding (REQ-24): stable occurrence identity, class,
/// authored location, short evidence, detector scope, severity, confidence,
/// and an optional candidate repair.
public struct LintFinding: Equatable, Sendable {
    /// Stable within one detector revision for the same body bytes — the
    /// per-item audit contract (REQ-31) keys on this plus the inventory IDs.
    public let occurrenceID: String
    public let defectClass: LintDefectClass
    /// The report section the finding is published under (REQ-23 order).
    public let section: LintScanSection
    /// The finding's location in AUTHORED bytes (half-open), or nil when the
    /// finding spans the whole body.
    public let authoredRange: MarkdownSourceRange?
    /// Short observed evidence (a bounded excerpt, a target string).
    public let evidence: String
    /// What the detector observed, in one sentence.
    public let message: String
    public let severity: LintSeverity
    public let confidence: LintConfidence
    public let candidateRepair: LintCandidateRepair?

    public init(
        occurrenceID: String,
        defectClass: LintDefectClass,
        authoredRange: MarkdownSourceRange?,
        evidence: String,
        message: String,
        severity: LintSeverity,
        confidence: LintConfidence,
        candidateRepair: LintCandidateRepair? = nil
    ) {
        self.occurrenceID = occurrenceID
        self.defectClass = defectClass
        self.section = defectClass.section
        self.authoredRange = authoredRange
        self.evidence = evidence
        self.message = message
        self.severity = severity
        self.confidence = confidence
        self.candidateRepair = candidateRepair
    }
}
