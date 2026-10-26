import Foundation
import WikiFSLinks

/// One user-triggered per-finding repair request: the finding a person
/// clicked **Fix** on, as the queue payload carries it (the amended ladder's
/// per-finding tier — human-in-the-loop by construction, no rollout gate).
///
/// The target names WHICH finding and WHICH head the person saw; it carries
/// no authority of its own. The trusted coordinator re-scans the page's
/// current head before launch and refuses (no write, no agent) when the
/// head moved or the finding is no longer detected. A scoped child can never
/// enqueue a payload carrying one: the daemon's scope guard denies it before
/// the queue sees it.
///
/// Persisted as JSON inside `QueueItemPayload`, so the defect class crosses
/// the boundary as its raw label: a label this build does not know decodes
/// (the queue row stays readable) and the coordinator refuses it.
public struct LintRepairTarget: Codable, Hashable, Sendable {
    /// The finding's stable occurrence id (`LintFinding.occurrenceID`).
    public let findingID: String
    /// The finding's defect class label (`LintDefectClass.rawValue`).
    public let classLabel: String
    /// The head the finding was detected on — the head the person saw. A
    /// current head that differs refuses the run.
    public let expectedHead: PageVersionID
    /// The lint run whose Run Details offered the Fix — lets that run's rows
    /// find their fix runs in the queue. `nil` when the request came from
    /// somewhere without an origin run.
    public let originItemID: QueueItemID?

    public init(
        findingID: String,
        classLabel: String,
        expectedHead: PageVersionID,
        originItemID: QueueItemID?
    ) {
        self.findingID = findingID
        self.classLabel = classLabel
        self.expectedHead = expectedHead
        self.originItemID = originItemID
    }

    /// The typed defect class, or `nil` for a label this build does not know.
    public var defectClass: LintDefectClass? { LintDefectClass(rawValue: classLabel) }
}

/// The ONE finding a per-finding repair run is scoped to, resolved from the
/// trusted pre-run scan of the current head (never from the payload's
/// words): the occurrence id, class, authored range, evidence, and the
/// detector's message. The prompt renders it; the accounting's scope check
/// enforces it.
public struct LintRepairFocus: Equatable, Sendable {
    public let occurrenceID: String
    public let defectClass: LintDefectClass
    /// The finding's half-open byte range in the authored body, or `nil`
    /// when the finding spans the whole body.
    public let authoredRange: MarkdownSourceRange?
    public let evidence: String
    public let message: String

    public init(
        occurrenceID: String,
        defectClass: LintDefectClass,
        authoredRange: MarkdownSourceRange?,
        evidence: String,
        message: String
    ) {
        self.occurrenceID = occurrenceID
        self.defectClass = defectClass
        self.authoredRange = authoredRange
        self.evidence = evidence
        self.message = message
    }

    /// The focus for one detected finding.
    public init(_ finding: LintFinding) {
        self.init(
            occurrenceID: finding.occurrenceID,
            defectClass: finding.defectClass,
            authoredRange: finding.authoredRange,
            evidence: finding.evidence,
            message: finding.message)
    }

    /// The range as the prompt states it ("bytes 12..40", or the whole body).
    public var rangeDescription: String {
        guard let authoredRange else { return "the whole body" }
        return "bytes \(authoredRange.lowerBound)..<\(authoredRange.upperBound)"
    }
}
