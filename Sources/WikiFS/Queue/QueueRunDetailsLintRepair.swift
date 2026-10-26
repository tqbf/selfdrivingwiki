import Foundation
import WikiFSCore
import WikiFSEngine

/// The Run Details panel's lint repair section (W2b) — the value model the
/// panel renders: the run's surviving written repairs with their one-click
/// **Undo lint fixes** affordance, and the "What went wrong" disclosure for
/// runs whose repairs failed verification or were undone.
///
/// Everything here derives from ALREADY-PERSISTED data: the durable queue
/// report's per-page records (`LintPageRecordFacts` re-parses the accounting
/// text the host wrote), the undo batch result the caller executed, and the
/// breaker's read-only window status. Nothing in this model sends feedback
/// anywhere or mutates state — the undo action itself lives with the caller
/// (the Activity window), which owns the store path and the breaker.
///
/// Visibility rules (the spec's): the section renders only for selected-page
/// lint runs; the Undo button renders only while the run has surviving
/// written repairs and no undo has run yet — hidden, never merely disabled,
/// for report-only runs, budget-rejected runs, already auto-reverted runs,
/// and whole-wiki report-only runs.
struct QueueRunDetailsLintRepair: Sendable, Equatable {

    /// One surviving written repair: the page plus the two heads the CAS
    /// revert needs (revert TO the inspected head, only while the head is
    /// still the written head).
    struct RepairPage: Identifiable, Sendable, Equatable {
        let pageID: PageID
        let title: String
        let inspectedHead: PageVersionID
        let writtenHead: PageVersionID

        var id: PageID { pageID }
    }

    /// One page whose run failed verification (auto-reverted, refused, or
    /// flagged) or that the undo could not revert — the disclosure's
    /// material. The version anchors let the panel render the reverted diff
    /// from page version history (both versions are durable).
    struct FailurePage: Identifiable, Sendable, Equatable {
        let pageID: PageID
        let title: String
        /// The persisted verification-failure reasons (already bounded by
        /// the producer's prefix).
        let reasons: [String]
        /// The run's written version (diff "after") — nil when unknown.
        let writtenHead: PageVersionID?
        /// The version the run inspected / was reverted to (diff "before").
        let inspectedHead: PageVersionID?

        var id: PageID { pageID }
    }

    /// The surviving written repairs — the undo batch's input and the count
    /// behind "N fixes applied".
    let repairPages: [RepairPage]
    /// Pages with recorded verification failures (the disclosure's content).
    let failurePages: [FailurePage]
    /// The approval row that authorized the run, when its records name one —
    /// resolves the undo's breaker configuration.
    let approvalID: LintApprovalID?
    /// The breaker configuration the run's records name directly
    /// (`breaker_key=`) — a per-finding repair's launch-time key, which no
    /// approval row names. Preferred over the approval row when present.
    var recordedBreakerKey: LintRepairBreakerKey?
    /// The wiki whose pages the run repaired (drives page-history links).
    let wikiID: WikiID

    /// The in-flight undo flag and the completed batch, owned by the caller.
    var undoInFlight: Bool = false
    var undoResult: LintUndoService.BatchResult?
    /// The breaker's read-only window status, resolved by the caller when it
    /// can name the run's configuration ("2 of 2 allowed … used" context).
    var breakerContext: String?
    /// The breaker's plain-language trip message after this undo, when the
    /// undo tripped it.
    var breakerNotice: String?

    /// The "N fixes applied" row's count.
    var appliedFixCount: Int { repairPages.count }

    /// Whether the Undo button renders at all: only while repairs survive
    /// AND no undo has run (one click per run — the result stays on screen).
    var showsUndoButton: Bool { repairPages.isEmpty == false && undoResult == nil }

    /// Whether the "What went wrong" disclosure renders: runs that failed
    /// verification, and runs this panel undid.
    var showsDisclosure: Bool {
        failurePages.isEmpty == false || undoResult != nil
    }

    /// The undo's honest aggregate line ("3 reverted, 1 changed since").
    var undoSummary: String? {
        guard let undoResult else { return nil }
        var parts: [String] = []
        let reverted = undoResult.revertedCount
        if reverted > 0 { parts.append("\(reverted) reverted") }
        let moved = undoResult.headMovedCount
        if moved > 0 { parts.append("\(moved) changed since this run") }
        let failed = undoResult.pages.count - reverted - moved
        if failed > 0 { parts.append("\(failed) failed") }
        guard parts.isEmpty == false else { return nil }
        return "Undo: " + parts.joined(separator: ", ") + "."
    }

    /// The head-moved pages' per-page results, for the manual-revert rows.
    var headMovedResults: [LintUndoService.PageResult] {
        undoResult?.pages.filter {
            if case .headMoved = $0.outcome { return true }
            return false
        } ?? []
    }

    // MARK: - Mapping from the durable report

    /// Map a lint attempt's durable report into the panel section, or nil
    /// when nothing here applies (a non-lint run, a whole-wiki report-only
    /// run, or a selected-page run with neither surviving repairs nor
    /// failure records). `wikiID` scopes the page-history links; the undo
    /// presentation state arrives from the caller.
    static func make(
        report: QueueAttemptReport,
        wikiID: WikiID,
        undoInFlight: Bool = false,
        undoResult: LintUndoService.BatchResult? = nil,
        breakerContext: String? = nil,
        breakerNotice: String? = nil
    ) -> QueueRunDetailsLintRepair? {
        guard report.operation == .lint else { return nil }
        // A whole-wiki lint run is the report-only marker — it wrote nothing
        // and its records carry no per-page accounting.
        guard case .targets(let records) = report.scope else { return nil }

        var repairPages: [RepairPage] = []
        var failurePages: [FailurePage] = []
        var approvalID: LintApprovalID?
        var recordedBreakerKey: LintRepairBreakerKey?
        for record in records {
            guard let facts = LintPageRecordFacts.parse(record: record) else { continue }
            if approvalID == nil { approvalID = facts.approvalID }
            if recordedBreakerKey == nil { recordedBreakerKey = facts.recordedBreakerKey }
            if facts.wroteSurvivingRepair, let inspected = facts.inspectedHead,
               let written = facts.writtenHead {
                repairPages.append(RepairPage(
                    pageID: facts.pageID, title: facts.title,
                    inspectedHead: inspected, writtenHead: written))
            }
            let needsDisclosure = facts.verificationFailureReasons.isEmpty == false
                || facts.wasAutoReverted
            if needsDisclosure {
                failurePages.append(FailurePage(
                    pageID: facts.pageID, title: facts.title,
                    reasons: facts.verificationFailureReasons,
                    writtenHead: facts.writtenHead,
                    inspectedHead: facts.inspectedHead))
            }
        }
        guard repairPages.isEmpty == false || failurePages.isEmpty == false else { return nil }
        return QueueRunDetailsLintRepair(
            repairPages: repairPages, failurePages: failurePages,
            approvalID: approvalID, recordedBreakerKey: recordedBreakerKey, wikiID: wikiID,
            undoInFlight: undoInFlight, undoResult: undoResult,
            breakerContext: breakerContext, breakerNotice: breakerNotice)
    }
}
