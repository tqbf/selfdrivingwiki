import Foundation

/// The typed operation policy of one managed daemon run — minted ONLY by the
/// trusted run host at launch intent and carried immutably through the lease
/// and every grant (plan Phase 2). The child can neither select nor expand
/// it: it arrives nowhere on the wire, in argv, or in the environment.
///
/// Policies distinguish ordinary managed operations from the lint shapes;
/// selected-page lint policies pin EXACTLY ONE authorized `PageID`.
public enum ManagedRunPolicy: Hashable, Codable, Sendable {

    /// The ordinary managed wiki run: reads, CAS edits, and source
    /// acquisition for its one assigned wiki (the initial scoped policy).
    case ordinaryManaged

    /// Selected-page lint with patch authority: reads the assigned wiki,
    /// patches EXACTLY the selected existing page under CAS, and appends
    /// lint logs. Nothing else mutates.
    case lintSelectedPageRepair(pageID: PageID)

    /// Selected-page lint in report-only form — the policy configurations
    /// run while no accepted rollout evidence exists (AC.14). Same identity
    /// pinning, no patch authority at all.
    case lintSelectedPageReportOnly(pageID: PageID)

    /// Selected-page lint in staged-proposal form (W5a tier 2): reads the
    /// assigned wiki, appends lint logs, and STAGES exact hunks against the
    /// selected page via `page propose-patch` — never writes them. Every
    /// other mutation, `page patch` included, denies.
    case lintSelectedPageProposal(pageID: PageID)

    /// User-triggered per-finding repair: reads the assigned wiki, patches
    /// EXACTLY the selected page under CAS, and appends lint logs — the same
    /// allowances as `lintSelectedPageRepair`, under its own identity so
    /// the lease, the audit trail, and the per-run patch budget (one
    /// finding's worth) all name the tier. Staging and every other mutation
    /// deny. Minted only for a person's Fix click, never by the rollout gate.
    case lintPerFindingRepair(pageID: PageID)

    /// Whole-wiki lint: reads the assigned wiki and appends lint logs.
    /// Every content mutation is denied, including patches (REQ-49).
    case lintWholeWikiReportOnly

    /// `true` when this policy is one of the lint shapes.
    public var isLint: Bool {
        switch self {
        case .ordinaryManaged: return false
        case .lintSelectedPageRepair, .lintSelectedPageReportOnly,
             .lintSelectedPageProposal, .lintPerFindingRepair, .lintWholeWikiReportOnly:
            return true
        }
    }

    /// The selected page a selected-page lint policy may patch or stage
    /// proposals against; `nil` for every other policy (whole-wiki lint has
    /// no selected page).
    public var selectedPageID: PageID? {
        switch self {
        case .ordinaryManaged, .lintWholeWikiReportOnly: return nil
        case .lintSelectedPageRepair(let pageID), .lintSelectedPageReportOnly(let pageID),
             .lintSelectedPageProposal(let pageID), .lintPerFindingRepair(let pageID):
            return pageID
        }
    }
}
