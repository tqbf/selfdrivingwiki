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
public struct LintPageRecordFacts: Equatable, Sendable {

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

    init(
        pageID: PageID, title: String, tier: LintAuthorityTier?,
        approvalID: LintApprovalID?, inspectedHead: PageVersionID?,
        writtenHead: PageVersionID?, wasAutoReverted: Bool, isFlagged: Bool,
        verificationFailureReasons: [String], proposalCount: Int? = nil,
        stagedProposalIDs: [String] = []
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
        var failureSegmentOpen = false

        for segment in segments {
            if let value = Self.labeledValue("authority_tier", in: segment) {
                tier = tier ?? LintAuthorityTier(rawValue: value)
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
            proposalCount: proposalCount, stagedProposalIDs: stagedProposalIDs)
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
    static let revertLabelPrefix = "revert="
    static let failurePrefix = "verification failed: "
    /// The audit label's manual-review marker (`LintRevertOutcome.auditLabel`).
    static let flaggedMarker = "FLAGGED"

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
            "approval_id=", "proposals=", "staged_proposal=",
            "AGENT LOG", "HOST LOG", "write phase",
            "no run scratch",
        ]
        return prefixes.contains { segment.hasPrefix($0) }
    }
}
