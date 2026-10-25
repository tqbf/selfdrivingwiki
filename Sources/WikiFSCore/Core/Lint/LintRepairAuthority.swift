import Foundation

/// The shipped approval row that authorized a repair run (the manifest's
/// `Approval.id`). Wrapped so an approval id never compares equal to a page,
/// run, or receipt id by accident.
public struct LintApprovalID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// What allowed (or refused) a selected-page lint run's repairs. A closed
/// set, so every recorded outcome traces back to exactly one authority.
public enum LintAuthorityTier: String, CaseIterable, Sendable, Codable {
    /// A shipped manifest approval row matched and the breaker was clean.
    case shippedApproval
    /// The evaluation harness's restricted admission for a disposable wiki.
    case evaluationAdmission
    /// The rollout gate selected report-only.
    case reportOnly
    /// The gate selected staged-proposal review (W5a tier 2): the run lints
    /// and FIXES, but its hunks are staged for human approval — never
    /// written directly by the run.
    case stagedProposal
    /// The gate authorized repairs, but the local circuit breaker demoted
    /// the run to report-only.
    case breakerDemoted
    /// The run's patch exceeded the per-run patch budget and was rejected
    /// whole; the write phase did not happen.
    case budgetExceeded

    /// Whether this tier grants a repair-capable lease.
    public var isRepairCapable: Bool {
        switch self {
        case .shippedApproval, .evaluationAdmission:
            return true
        case .reportOnly, .breakerDemoted, .budgetExceeded, .stagedProposal:
            return false
        }
    }

    /// Whether this tier may stage repair proposals (tier 2).
    public var isProposalCapable: Bool {
        self == .stagedProposal
    }
}

/// The authority a selected-page lint run ran under: its tier, the approval
/// row that matched (kept on demotions for traceability), and the plain
/// reason for any report-only outcome.
public struct LintRepairAuthority: Equatable, Sendable {
    public let tier: LintAuthorityTier
    public let approvalID: LintApprovalID?
    public let reason: String?

    public init(tier: LintAuthorityTier, approvalID: LintApprovalID?, reason: String?) {
        self.tier = tier
        self.approvalID = approvalID
        self.reason = reason
    }

    /// The gate selected report-only.
    public static func reportOnly(reason: String) -> LintRepairAuthority {
        LintRepairAuthority(tier: .reportOnly, approvalID: nil, reason: reason)
    }

    /// The gate selected staged-proposal review (tier 2).
    public static func stagedProposal(reason: String) -> LintRepairAuthority {
        LintRepairAuthority(tier: .stagedProposal, approvalID: nil, reason: reason)
    }

    /// A shipped approval row authorized repairs.
    public static func shippedApproval(_ approvalID: LintApprovalID) -> LintRepairAuthority {
        LintRepairAuthority(tier: .shippedApproval, approvalID: approvalID, reason: nil)
    }

    public var isRepairCapable: Bool { tier.isRepairCapable }

    /// The same run under a lower tier. The approval id stays so a demoted
    /// run still names the row it would have used.
    public func demoted(to tier: LintAuthorityTier, reason: String) -> LintRepairAuthority {
        LintRepairAuthority(tier: tier, approvalID: approvalID, reason: reason)
    }

    /// The structured labels the host `--kind lint` audit line and the queue
    /// report carry, in the existing `label=value` plain-text format.
    public var auditLabels: String {
        var labels = ["authority_tier=\(tier.rawValue)"]
        if let approvalID {
            labels.append("approval_id=\(approvalID.rawValue)")
        }
        if let reason {
            labels.append("authority_reason=\(reason)")
        }
        return labels.joined(separator: "; ")
    }
}

/// What happened when post-write verification failed and the host tried to
/// put the inspected head back. The run stays a verification failure in
/// every case; this is a separate fact, never a success.
public enum LintRevertOutcome: Equatable, Sendable {
    /// The page head moved back from the run's written head to the
    /// inspected head.
    case reverted(to: PageVersionID, from: PageVersionID)
    /// A concurrent writer advanced the page after the run's write. The
    /// host did not revert, so the concurrent edit survives; the page is
    /// flagged for review.
    case refusedHeadDiverged(written: PageVersionID, current: PageVersionID?)
    /// No revert was attempted (for example, the run wrote nothing).
    case notAttempted(reason: String)
    /// The revert was attempted and the store refused it.
    case failed(reason: String)

    /// Whether the page needs a human look: the bad write may still be in
    /// place.
    public var isFlagged: Bool {
        switch self {
        case .reverted, .notAttempted:
            return false
        case .refusedHeadDiverged, .failed:
            return true
        }
    }

    /// The structured `revert=` label for audit lines and reports.
    public var auditLabel: String {
        switch self {
        case .reverted(let to, let from):
            return "revert=reverted to \(to.rawValue) from \(from.rawValue)"
        case .refusedHeadDiverged(let written, let current):
            return "revert=refused (current head \(current?.rawValue ?? "none") diverged from written head \(written.rawValue)); FLAGGED for review"
        case .notAttempted(let reason):
            return "revert=not attempted (\(reason))"
        case .failed(let reason):
            return "revert=failed (\(reason)); FLAGGED for review"
        }
    }
}
