import Foundation

/// The staged-proposal audit vocabulary (W5a tier 2): the trusted daemon's
/// `--kind lint` entry for a proposal it staged, and the `label=value`
/// segments host accounting folds into a run's per-page record.
///
/// The staged entry's title is `Lint proposal staged — <page title>` (the
/// same title-matching shape as the budget rejection's entry), and its note
/// carries the structured labels the apply/review paths need. Both wikid
/// (producer) and WikiFSEngine (host accounting + record facts) read this
/// one type, so the text shape cannot drift.
public enum LintProposalAudit {

    /// The title prefix of the trusted daemon's `--kind lint` entry for a
    /// staged proposal. Host accounting reads entries back by this title;
    /// it is never counted as the agent's log.
    public static let stagedAuditTitlePrefix = "Lint proposal staged — "

    /// The note's `label=value` labels, in order: the proposal id (the
    /// staged record reference), the head the hunks were composed against,
    /// the inspected body's fingerprint, and the hunk count.
    public static func stagedNote(
        proposalID: String, inspectedHead: PageVersionID,
        bodyFingerprint: String, hunkCount: Int
    ) -> String {
        [
            "proposal_id=\(proposalID)",
            "inspected_head=\(inspectedHead.rawValue)",
            "body_fingerprint=\(bodyFingerprint)",
            "hunks=\(hunkCount)",
        ].joined(separator: "; ")
    }

    /// One parsed staged-proposal audit note.
    public struct StagedNote: Equatable, Sendable {
        public let proposalID: String
        public let inspectedHead: PageVersionID?
        public let bodyFingerprint: String?
        public let hunkCount: Int?
    }

    /// Parse a staged entry's note back into its labels. Lenient: a missing
    /// or malformed label parses to nil — the entry still proves a proposal
    /// was staged, and the durable record (`DaemonLintStagedProposal`) is
    /// the authority for its fields.
    public static func parseStagedNote(_ note: String?) -> StagedNote? {
        guard let note else { return nil }
        var proposalID: String?
        var inspectedHead: PageVersionID?
        var fingerprint: String?
        var hunkCount: Int?
        for segment in note.components(separatedBy: "; ") {
            let parts = segment.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "proposal_id": proposalID = parts[1].isEmpty ? nil : parts[1]
            case "inspected_head":
                inspectedHead = parts[1].isEmpty ? nil : PageVersionID(rawValue: parts[1])
            case "body_fingerprint": fingerprint = parts[1].isEmpty ? nil : parts[1]
            case "hunks": hunkCount = Int(parts[1])
            default: break
            }
        }
        guard let id = proposalID else { return nil }
        return StagedNote(
            proposalID: id, inspectedHead: inspectedHead,
            bodyFingerprint: fingerprint, hunkCount: hunkCount)
    }

    /// The `label=value` segments host accounting appends to a tier-2 run's
    /// per-page detail: how many proposals the run staged and which record
    /// references it produced ("N proposed" in the review UI). Empty input
    /// yields an empty string — a run that staged nothing records nothing.
    public static func recordLabels(proposals: [StagedNote]) -> String {
        var labels: [String] = []
        if proposals.isEmpty == false {
            labels.append("proposals=\(proposals.count)")
        }
        for proposal in proposals {
            labels.append("staged_proposal=\(proposal.proposalID)")
        }
        return labels.joined(separator: "; ")
    }
}
