import Foundation
import WikiFSCore

/// The typed facts W2b reads back out of ONE durable per-page lint record
/// (W2a §4's `QueueIngestionReporting.LintPageOutcome` as persisted in the
/// queue report's target rows).
///
/// The record's `detail` is plain text — the accounting's `label=value`
/// segments joined with `"; "` — because the report schema stores detail as
/// a column, not a blob. This parser is the single place that knows that
/// text shape: it turns the persisted segments back into the heads, the
/// authority, the auto-revert outcome, and the verification-failure reasons
/// the Undo affordance and the "What went wrong" disclosure need. Both
/// directions are pinned by tests: the producers' format (LintEnforcement
/// suites) and this parser.
///
/// Parsing is lenient by design: a segment it does not recognize is kept as
/// a verification-reason continuation only while a `verification failed:`
/// segment is open, and never crashes on legacy or empty details. A record
/// that is not a page record (`target` is not `.page`) parses to `nil`.
///
/// Findings (plan §5.13/§5.14): the accounting appends what the trusted
/// pre-flight scan DETECTED — `findings=<total>` plus one
/// `finding=<id> <class> <outcome>[ evidence=<text>]` segment per finding —
/// so a report-only run's detections survive in the durable record the Run
/// Details panel renders. The evidence text is sanitized at production time
/// (`;` and newlines flattened, bounded), so a `finding=` segment is always
/// exactly one `"; "`-joined segment. Legacy records without the labels
/// parse with `findingCount == nil` — absence stays distinguishable from an
/// honest zero.
public struct LintPageRecordFacts: Equatable, Sendable {

    /// One detected finding as the durable per-page record carries it.
    public struct RecordFinding: Equatable, Sendable {
        /// The finding's stable occurrence id (e.g. `D03|line-3#1`).
        public let occurrenceID: String
        /// The defect class label (`LintDefectClass.rawValue`, e.g. `D03`).
        public let classLabel: String
        /// The outcome the validated run report assigned: `repaired`,
        /// `valid`, `unresolved`, `outside-scope`, `blocked`, `pending`, or
        /// `unreported` (no report outcome reached the record).
        public let outcomeToken: String
        /// The scan's bounded evidence excerpt, sanitized at production
        /// time (no `;`, no newlines); empty when the finding carried none.
        public let evidence: String

        public init(
            occurrenceID: String, classLabel: String, outcomeToken: String,
            evidence: String
        ) {
            self.occurrenceID = occurrenceID
            self.classLabel = classLabel
            self.outcomeToken = outcomeToken
            self.evidence = evidence
        }
    }

    /// The page the record is about.
    public let pageID: PageID
    /// The display name recorded at staging time.
    public let title: String
    /// The recorded authority tier, if the record carries one.
    public let tier: LintAuthorityTier?
    /// The shipped approval row that authorized the run, if recorded.
    public let approvalID: LintApprovalID?
    /// The head the run inspected — the version an undo reverts TO.
    public let inspectedHead: PageVersionID?
    /// The head the run wrote — an undo's expected head.
    public let writtenHead: PageVersionID?
    /// Whether any `revert=` outcome was recorded: the run's write did not
    /// survive (auto-reverted, refused, or failed).
    public let wasAutoReverted: Bool
    /// Whether the revert outcome flags the page for manual review (the bad
    /// write may still be in place).
    public let isFlagged: Bool
    /// The verification-failure reasons as persisted (bounded by the
    /// producer's prefix).
    public let verificationFailureReasons: [String]
    /// How many proposals a tier-2 run staged for this page (W5a), if the
    /// record carries the label — the review UI's "N proposed".
    public let proposalCount: Int?
    /// The staged record references (`staged_proposal=<id>`) the review UI
    /// resolves against the daemon's staged records, in recorded order.
    public let stagedProposalIDs: [String]
    /// Why the run ran under its authority tier (`authority_reason=`), when
    /// recorded — the report-only line's honest reason. Only the first
    /// segment joins: a reason containing `"; "` renders truncated here
    /// (the full text stays in the record detail itself).
    public let authorityReason: String?
    /// How many findings the trusted pre-flight scan detected
    /// (`findings=<n>`). `nil` for legacy records written before the label
    /// existed — absence, never an invented zero.
    public let findingCount: Int?
    /// The detected findings with their assigned outcomes, in recorded
    /// order (one `finding=` segment each).
    public let findings: [RecordFinding]
    /// The finding a user-triggered per-finding repair run targeted
    /// (`per_finding=<id>`); `nil` for every autonomous record.
    public let perFindingID: String?
    /// Why a per-finding run refused before launching anything
    /// (`per_finding_outcome=`); `nil` when it launched (its verification
    /// and revert labels tell the rest) and for autonomous records.
    public let perFindingRefusal: LintPerFindingRefusal?
    /// The breaker configuration the run's outcome was recorded under
    /// (`breaker_key=`), when the record names one — the per-finding run's
    /// launch-time key. The undo records its user undo under it.
    public let recordedBreakerKey: LintRepairBreakerKey?

    init(
        pageID: PageID, title: String, tier: LintAuthorityTier?,
        approvalID: LintApprovalID?, inspectedHead: PageVersionID?,
        writtenHead: PageVersionID?, wasAutoReverted: Bool, isFlagged: Bool,
        verificationFailureReasons: [String], proposalCount: Int? = nil,
        stagedProposalIDs: [String] = [], authorityReason: String? = nil,
        findingCount: Int? = nil, findings: [RecordFinding] = [],
        perFindingID: String? = nil, perFindingRefusal: LintPerFindingRefusal? = nil,
        recordedBreakerKey: LintRepairBreakerKey? = nil
    ) {
        self.pageID = pageID
        self.title = title
        self.tier = tier
        self.approvalID = approvalID
        self.inspectedHead = inspectedHead
        self.writtenHead = writtenHead
        self.wasAutoReverted = wasAutoReverted
        self.isFlagged = isFlagged
        self.verificationFailureReasons = verificationFailureReasons
        self.proposalCount = proposalCount
        self.stagedProposalIDs = stagedProposalIDs
        self.authorityReason = authorityReason
        self.findingCount = findingCount
        self.findings = findings
        self.perFindingID = perFindingID
        self.perFindingRefusal = perFindingRefusal
        self.recordedBreakerKey = recordedBreakerKey
    }

    /// Parse one durable target record. Returns `nil` for records that are
    /// not about a page (source records carry no lint accounting).
    public static func parse(record: QueueReportTargetRecord) -> LintPageRecordFacts? {
        guard case .page(let pageID) = record.target else { return nil }
        let segments = (record.detail ?? "")
            .components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }

        var tier: LintAuthorityTier?
        var approvalID: LintApprovalID?
        var inspectedHead: PageVersionID?
        var writtenHead: PageVersionID?
        var wasAutoReverted = false
        var isFlagged = false
        var reasons: [String] = []
        var proposalCount: Int?
        var stagedProposalIDs: [String] = []
        var authorityReason: String?
        var findingCount: Int?
        var findings: [RecordFinding] = []
        var perFindingID: String?
        var perFindingRefusal: LintPerFindingRefusal?
        var recordedBreakerKey: LintRepairBreakerKey?
        var failureSegmentOpen = false

        for segment in segments {
            if let value = Self.labeledValue(Self.perFindingLabel, in: segment) {
                perFindingID = perFindingID ?? value
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue(Self.perFindingOutcomeLabel, in: segment) {
                perFindingRefusal = perFindingRefusal ?? LintPerFindingRefusal(rawValue: value)
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue(LintRepairBreakerKey.recordLabelName, in: segment) {
                recordedBreakerKey = recordedBreakerKey
                    ?? LintRepairBreakerKey(recordLabelValue: value)
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("authority_tier", in: segment) {
                tier = tier ?? LintAuthorityTier(rawValue: value)
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("authority_reason", in: segment) {
                authorityReason = authorityReason ?? value
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("findings", in: segment) {
                findingCount = findingCount ?? Int(value)
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("finding", in: segment) {
                if let finding = Self.parseFinding(value) {
                    findings.append(finding)
                }
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("approval_id", in: segment) {
                approvalID = approvalID ?? LintApprovalID(rawValue: value)
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("proposals", in: segment) {
                proposalCount = proposalCount ?? Int(value)
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("staged_proposal", in: segment) {
                stagedProposalIDs.append(value)
                failureSegmentOpen = false
                continue
            }
            if segment.hasPrefix(Self.inspectedHeadPrefix) {
                let raw = String(segment.dropFirst(Self.inspectedHeadPrefix.count))
                inspectedHead = inspectedHead ?? Self.versionID(raw)
                failureSegmentOpen = false
                continue
            }
            if let value = Self.labeledValue("written_head", in: segment) {
                writtenHead = writtenHead ?? Self.versionID(value)
                failureSegmentOpen = false
                continue
            }
            if segment.hasPrefix(Self.revertLabelPrefix) {
                wasAutoReverted = true
                // The audit label appends "; FLAGGED for review" on a refused
                // or failed revert — the write may still be in place.
                isFlagged = segment.contains(Self.flaggedMarker)
                failureSegmentOpen = false
                continue
            }
            if segment.hasPrefix(Self.flaggedMarker) {
                // The audit label's "; FLAGGED for review" tail is its own
                // segment (the label joins with "; ").
                isFlagged = true
                failureSegmentOpen = false
                continue
            }
            if segment.hasPrefix(Self.failurePrefix) {
                let first = String(segment.dropFirst(Self.failurePrefix.count))
                if first.isEmpty == false { reasons.append(first) }
                failureSegmentOpen = true
                continue
            }
            if failureSegmentOpen, Self.opensStructuralSegment(segment) == false {
                // A continuation of the `"; "`-joined failure reasons.
                reasons.append(segment)
                continue
            }
            failureSegmentOpen = false
        }

        return LintPageRecordFacts(
            pageID: pageID, title: record.displayName, tier: tier,
            approvalID: approvalID, inspectedHead: inspectedHead,
            writtenHead: writtenHead, wasAutoReverted: wasAutoReverted,
            isFlagged: isFlagged, verificationFailureReasons: reasons,
            proposalCount: proposalCount, stagedProposalIDs: stagedProposalIDs,
            authorityReason: authorityReason, findingCount: findingCount,
            findings: findings, perFindingID: perFindingID,
            perFindingRefusal: perFindingRefusal, recordedBreakerKey: recordedBreakerKey)
    }

    /// Whether the run left a SURVIVING written repair an undo can revert:
    /// the page's accounting succeeded, the authority was repair-capable,
    /// no revert outcome was recorded, and both heads the CAS revert needs
    /// are known and distinct (a run that wrote nothing has nothing to undo).
    public var wroteSurvivingRepair: Bool {
        guard tier?.isRepairCapable == true else { return false }
        guard wasAutoReverted == false else { return false }
        guard let inspectedHead, let writtenHead else { return false }
        return inspectedHead != writtenHead
    }

    // MARK: - Segment shapes (must stay in sync with the producers)

    static let inspectedHeadPrefix = "audited head "
    /// The per-finding run's target label (`per_finding=<occurrence id>`).
    public static let perFindingLabel = "per_finding"
    /// The per-finding run's pre-launch refusal label.
    public static let perFindingOutcomeLabel = "per_finding_outcome"
    static let revertLabelPrefix = "revert="
    static let failurePrefix = "verification failed: "
    /// The audit label's manual-review marker (`LintRevertOutcome.auditLabel`).
    static let flaggedMarker = "FLAGGED"

    // MARK: - Findings labels (producer)

    /// The findings detail the host accounting appends to one page's
    /// record: `findings=<total>` plus one `finding=` segment per finding
    /// the trusted pre-flight scan detected, each carrying the scan's class
    /// label and evidence and the outcome the validated run report assigned
    /// (`unreported` when no report outcome reached the record). This is
    /// the report-only path's durable findings data — a run that may not
    /// write still detects, and its record says what it detected.
    ///
    /// Evidence is sanitized (no `;`, no newlines, bounded) so every
    /// `finding=` segment stays exactly one `"; "`-joined segment.
    public static func findingsDetail(
        preflight: LintPreflightReport,
        report: ParsedLintRunReport?
    ) -> String {
        let detected = preflight.sections.flatMap(\.findings)
        var segments = ["findings=\(detected.count)"]
        guard detected.isEmpty == false else { return segments.joined(separator: "; ") }
        var outcomes: [String: LintFindingOutcome] = [:]
        for entry in report?.entries ?? [] {
            guard case .finding(let id) = entry.kind else { continue }
            outcomes[id] = entry.outcome
        }
        for finding in detected {
            let token = outcomes[finding.occurrenceID].map(outcomeToken) ?? "unreported"
            var segment = "finding=\(finding.occurrenceID) "
                + "\(finding.defectClass.rawValue) \(token)"
            let evidence = sanitizedEvidence(finding.evidence)
            if evidence.isEmpty == false {
                segment += " evidence=\(evidence)"
            }
            segments.append(segment)
        }
        return segments.joined(separator: "; ")
    }

    /// The record's compact outcome token for a report outcome.
    static func outcomeToken(_ outcome: LintFindingOutcome) -> String {
        switch outcome {
        case .repaired: return "repaired"
        case .validAsWritten: return "valid"
        case .unresolved: return "unresolved"
        case .outsideLintScope: return "outside-scope"
        case .checkBlocked: return "blocked"
        case .pending: return "pending"
        }
    }

    /// Flatten one evidence excerpt into a single bounded segment value:
    /// `;` (the segment separator) becomes `,`, newlines become spaces, and
    /// the text stays within the scan's evidence-character bound.
    static func sanitizedEvidence(_ raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let collapsed = flattened
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard collapsed.count > LintPreflightReport.Limits.evidenceCharacters else {
            return collapsed
        }
        return String(collapsed.prefix(LintPreflightReport.Limits.evidenceCharacters))
    }

    /// Parse one `finding=` segment's value back into a record finding.
    /// Grammar: `<id> <class> <outcome>[ evidence=<text>]`. A malformed
    /// value parses to `nil` (lenient by design, like the rest of the
    /// parser).
    static func parseFinding(_ value: String) -> RecordFinding? {
        let tokens = value.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard tokens.count >= 3 else { return nil }
        var evidence = ""
        if tokens.count > 3, tokens[3].hasPrefix("evidence=") {
            evidence = ([String(tokens[3].dropFirst("evidence=".count))]
                + tokens.dropFirst(4)).joined(separator: " ")
        }
        return RecordFinding(
            occurrenceID: tokens[0], classLabel: tokens[1],
            outcomeToken: tokens[2], evidence: evidence)
    }

    /// The value of a `label=value` segment, or nil when the segment is not
    /// that label.
    private static func labeledValue(_ label: String, in segment: String) -> String? {
        let prefix = "\(label)="
        guard segment.hasPrefix(prefix) else { return nil }
        let value = String(segment.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    /// A recorded version id, or nil for the accounting's "none" placeholder.
    private static func versionID(_ raw: String) -> PageVersionID? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false, trimmed != "none" else { return nil }
        return PageVersionID(rawValue: trimmed)
    }

    /// Whether a segment starts a known structural label — a boundary for
    /// verification-reason continuations. Reason text never starts one of
    /// these (the reasons are occurrence-id sentences from
    /// `LintVerification` and coverage-validation phrasing).
    static func opensStructuralSegment(_ segment: String) -> Bool {
        let prefixes = [
            inspectedHeadPrefix, revertLabelPrefix, "verification ",
            "run-report ", "unresolved:", "written_head=", "authority_tier=",
            "authority_reason=", "approval_id=", "proposals=", "staged_proposal=",
            "findings=", "finding=", "per_finding=", "per_finding_outcome=",
            "breaker_key=",
            "AGENT LOG", "HOST LOG", "write phase",
            "no run scratch",
        ]
        return prefixes.contains { segment.hasPrefix($0) }
    }
}
