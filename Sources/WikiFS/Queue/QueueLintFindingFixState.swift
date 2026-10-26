import Foundation
import WikiFSCore
import WikiFSEngine

/// One finding row's per-finding repair state in Run Details — the finite
/// state machine behind the row's **Fix** / **Edit manually** controls and
/// its status line. Derived, never stored: the Activity window recomputes
/// it from the queue snapshot (the fix runs this run spawned), their
/// durable reports, and its own click-local enqueue state.
///
/// Honest at every step: the row never claims a repair the fix run's own
/// durable record does not show.
enum QueueLintFindingFixState: Equatable, Sendable {
    /// Fix is offered: a repairable class, not already repaired, a known
    /// inspected head, and no fix in flight for this page.
    case available
    /// Fix is not offered for this finding (the reason names why); Edit
    /// manually stays.
    case unavailable(reason: String)
    /// Another finding's fix is in flight for this page (one fix run at a
    /// time per page in v1) — Fix renders disabled.
    case pageBusy
    /// The Fix click is being enqueued, or the fix run is queued/running.
    case inFlight(itemID: QueueItem.ID?)
    /// The fix run's write verified and survives; the fix run's Run
    /// Details carry the one-click Undo.
    case applied(itemID: QueueItem.ID)
    /// The fix run's write failed verification and was reverted; the
    /// reasons are what verification caught.
    case reverted(itemID: QueueItem.ID, reasons: [String])
    /// The page changed since this finding (head moved or the finding is no
    /// longer detected) — nothing was written.
    case pageChanged(itemID: QueueItem.ID)
    /// The fix run finished without writing (the agent could not repair the
    /// finding from verified evidence).
    case noChange(itemID: QueueItem.ID)
    /// The fix could not run or failed; the reason is the recorded one.
    case failed(itemID: QueueItem.ID?, reason: String)

    /// Whether the row renders the Fix button at all.
    var showsFixButton: Bool {
        switch self {
        case .available, .pageBusy, .inFlight: return true
        case .unavailable, .applied, .reverted, .pageChanged, .noChange, .failed: return false
        }
    }

    /// Whether the Fix button is enabled.
    var fixEnabled: Bool { self == .available }

    /// The fix run the row can open, when one exists.
    var fixRunItemID: QueueItem.ID? {
        switch self {
        case .inFlight(let itemID), .failed(let itemID, _): return itemID
        case .applied(let itemID), .reverted(let itemID, _), .pageChanged(let itemID),
             .noChange(let itemID):
            return itemID
        case .available, .unavailable, .pageBusy: return nil
        }
    }

    /// The row's status line, or nil when the controls say enough.
    var statusLine: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason):
            return reason
        case .pageBusy:
            return "Another fix is running for this page."
        case .inFlight:
            return "Fixing…"
        case .applied:
            return "Repaired. Undo it from the fix run's Run Details."
        case .reverted(_, let reasons):
            let caught = reasons.isEmpty ? "" : ": " + reasons.joined(separator: "; ")
            return "The fix failed verification and was reverted\(caught)."
        case .pageChanged:
            return LintPerFindingRefusal.pageChanged.message
        case .noChange:
            return "The fix run made no change — the finding stays. Edit the page manually."
        case .failed(_, let reason):
            return "The fix did not run: \(reason)"
        }
    }

    // MARK: - Derivation

    /// One fix run this lint run spawned for one finding, as the Activity
    /// window sees it: the queue item's lifecycle plus, once terminal, its
    /// durable page record.
    struct FixRun: Equatable, Sendable {
        let itemID: QueueItem.ID
        let pageID: PageID
        let findingID: String
        let state: QueueItemState
        let error: String?
        /// The fix run's durable page record, when its report loaded.
        let record: LintPageRecordFacts?

        var isActive: Bool { state == .queued || state == .running }
    }

    /// The state for one finding row.
    ///
    /// - `inspectedHead`: the head the finding was detected on (the origin
    ///   record's audited head) — `nil` means a Fix cannot name its target.
    /// - `fixRuns`: every fix run of the origin run, newest LAST.
    /// - `enqueueing` / `enqueueProblem`: the click-local enqueue state of
    ///   THIS finding; `pageEnqueueing`: whether any finding on the page has
    ///   a Fix click still enqueueing (the page is busy before the queue
    ///   snapshot shows the fix run — one fix per page holds from the click).
    static func derive(
        finding: LintPageRecordFacts.RecordFinding,
        pageID: PageID,
        inspectedHead: PageVersionID?,
        fixRuns: [FixRun],
        enqueueing: Bool,
        enqueueProblem: String?,
        pageEnqueueing: Bool = false
    ) -> QueueLintFindingFixState {
        if let run = fixRuns.last(where: {
            $0.pageID == pageID && $0.findingID == finding.occurrenceID
        }) {
            return state(for: run)
        }
        if enqueueing { return .inFlight(itemID: nil) }
        if let enqueueProblem { return .failed(itemID: nil, reason: enqueueProblem) }
        guard let defectClass = LintDefectClass(rawValue: finding.classLabel),
              defectClass.repairPolicy == .repairable else {
            return .unavailable(reason: "Report-only class — edit the page manually.")
        }
        guard finding.outcomeToken != "repaired" else {
            return .unavailable(reason: "Repaired by this run.")
        }
        guard inspectedHead != nil else {
            return .unavailable(reason: "The run recorded no inspected head — re-run lint to fix.")
        }
        if pageEnqueueing || fixRuns.contains(where: { $0.pageID == pageID && $0.isActive }) {
            return .pageBusy
        }
        return .available
    }

    /// The state one fix run's lifecycle and durable record support.
    static func state(for run: FixRun) -> QueueLintFindingFixState {
        if run.isActive { return .inFlight(itemID: run.itemID) }
        guard let record = run.record else {
            switch run.state {
            case .failed:
                return .failed(itemID: run.itemID, reason: run.error ?? "the fix run failed")
            case .cancelled:
                return .failed(itemID: run.itemID, reason: "the fix run was cancelled")
            case .completed, .queued, .running:
                // Terminal but the report has not loaded yet.
                return .inFlight(itemID: run.itemID)
            }
        }
        switch record.perFindingRefusal {
        case .pageChanged:
            return .pageChanged(itemID: run.itemID)
        case .some(let refusal):
            return .failed(itemID: run.itemID, reason: refusal.message)
        case nil:
            break
        }
        if record.wroteSurvivingRepair { return .applied(itemID: run.itemID) }
        if record.isFlagged {
            // The revert was refused or failed: the bad write may still be
            // in place, so the row must not say "reverted".
            return .failed(
                itemID: run.itemID,
                reason: "verification failed and the write could not be reverted — review the page from the fix run")
        }
        if record.wasAutoReverted {
            return .reverted(itemID: run.itemID, reasons: record.verificationFailureReasons)
        }
        if run.state == .failed {
            return .failed(itemID: run.itemID, reason: run.error ?? "the fix run failed")
        }
        return .noChange(itemID: run.itemID)
    }
}
