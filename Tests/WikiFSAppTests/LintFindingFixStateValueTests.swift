import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// The per-finding repair row's state machine — the value half of the
/// W2b/W5b split (the hosted half lives in `LintRunDetailsScenarioTests`).
/// Every fix-run record here is the durable shape the accounting writes,
/// re-parsed by `LintPageRecordFacts`, so the rows read the same facts
/// production persists.
struct LintFindingFixStateValueTests {

    private let pageID = PageID(rawValue: "01HZFIXPAGE000000000000000A")
    private let inspected = PageVersionID(rawValue: "01HZHEADINSPECTED000000000A")
    private let written = PageVersionID(rawValue: "01HZHEADWRITTEN00000000000A")

    private func finding(
        _ id: String = "D06-1", classLabel: String = "D06", outcome: String = "unresolved"
    ) -> LintPageRecordFacts.RecordFinding {
        LintPageRecordFacts.RecordFinding(
            occurrenceID: id, classLabel: classLabel, outcomeToken: outcome, evidence: "[[x")
    }

    private func facts(_ detail: String) throws -> LintPageRecordFacts {
        try #require(LintPageRecordFacts.parse(record: QueueReportTargetRecord(
            target: .page(pageID), displayName: "Fix page", state: .succeeded, detail: detail)))
    }

    private func run(
        _ state: QueueItemState, record: LintPageRecordFacts? = nil,
        findingID: String = "D06-1", error: String? = nil
    ) -> QueueLintFindingFixState.FixRun {
        QueueLintFindingFixState.FixRun(
            itemID: QueueItem.ID(rawValue: "fix-item"), pageID: pageID,
            findingID: findingID, state: state, error: error, record: record)
    }

    private func derive(
        _ finding: LintPageRecordFacts.RecordFinding,
        inspectedHead: PageVersionID? = PageVersionID(rawValue: "01HZHEADINSPECTED000000000A"),
        runs: [QueueLintFindingFixState.FixRun] = [],
        enqueueing: Bool = false, problem: String? = nil
    ) -> QueueLintFindingFixState {
        QueueLintFindingFixState.derive(
            finding: finding, pageID: pageID, inspectedHead: inspectedHead,
            fixRuns: runs, enqueueing: enqueueing, enqueueProblem: problem)
    }

    // MARK: - Before any fix run

    @Test func availabilityTruthTable() {
        #expect(derive(finding()) == .available)
        #expect(derive(finding()).fixEnabled)
        // Report-only and out-of-scope classes: Edit only, with the reason.
        #expect(derive(finding("D02-1", classLabel: "D02"))
            == .unavailable(reason: "Report-only class — edit the page manually."))
        #expect(derive(finding("D21-1", classLabel: "D21")).showsFixButton == false)
        #expect(derive(finding("X-1", classLabel: "D99")).showsFixButton == false)
        // Already repaired by the run itself.
        #expect(derive(finding(outcome: "repaired")) == .unavailable(reason: "Repaired by this run."))
        // No inspected head: the Fix could not name its target.
        #expect(derive(finding(), inspectedHead: nil).showsFixButton == false)
        // The click is enqueueing: in flight, disabled.
        let enqueueing = derive(finding(), enqueueing: true)
        #expect(enqueueing == .inFlight(itemID: nil))
        #expect(enqueueing.showsFixButton && enqueueing.fixEnabled == false)
        #expect(enqueueing.statusLine == "Fixing…")
        // The enqueue failed: the honest reason.
        #expect(derive(finding(), problem: "daemon unavailable")
            == .failed(itemID: nil, reason: "daemon unavailable"))
    }

    /// One fix run at a time per page: another finding's ACTIVE fix run on
    /// the same page disables Fix here.
    @Test func anotherFindingsActiveFixMakesThePageBusy() {
        let other = run(.running, findingID: "D26-1")
        let state = derive(finding(), runs: [other])
        #expect(state == .pageBusy)
        #expect(state.showsFixButton && state.fixEnabled == false)
        #expect(state.statusLine == "Another fix is running for this page.")
        // Busy from the CLICK: another finding's Fix still enqueueing (not
        // yet in the queue snapshot) already blocks this one.
        #expect(QueueLintFindingFixState.derive(
            finding: finding(), pageID: pageID, inspectedHead: inspected,
            fixRuns: [], enqueueing: false, enqueueProblem: nil, pageEnqueueing: true) == .pageBusy)
        // A SETTLED fix of another finding does not block this one.
        #expect(derive(finding(), runs: [run(.completed, findingID: "D26-1")]) == .available)
    }

    // MARK: - From the fix run's durable record

    @Test func appliedVerifiedRunSaysRepairedAndPointsAtItsUndo() throws {
        let record = try facts(
            "audited head \(inspected.rawValue); verification verified on the written head; "
                + "per_finding=D06-1; written_head=\(written.rawValue); authority_tier=perFindingRepair")
        #expect(record.wroteSurvivingRepair)
        let state = derive(finding(), runs: [run(.completed, record: record)])
        #expect(state == .applied(itemID: QueueItem.ID(rawValue: "fix-item")))
        #expect(state.showsFixButton == false)
        #expect(state.statusLine == "Repaired. Undo it from the fix run's Run Details.")
        #expect(state.fixRunItemID == QueueItem.ID(rawValue: "fix-item"))
    }

    @Test func revertedRunShowsWhatVerificationCaught() throws {
        let record = try facts(
            "audited head \(inspected.rawValue); verification failed: "
                + "per-finding repair changed finding D26-1 — only D06-1 was in scope; "
                + "revert=reverted to \(inspected.rawValue) from \(written.rawValue); "
                + "per_finding=D06-1; written_head=\(inspected.rawValue); authority_tier=perFindingRepair")
        let state = derive(finding(), runs: [run(.failed, record: record)])
        guard case .reverted(_, let reasons) = state else {
            Issue.record("expected the reverted state, got \(state)")
            return
        }
        #expect(reasons == ["per-finding repair changed finding D26-1 — only D06-1 was in scope"])
        #expect(state.statusLine == "The fix failed verification and was reverted: "
            + "per-finding repair changed finding D26-1 — only D06-1 was in scope.")
    }

    /// A refused revert (the head moved after the write) must never read as
    /// "reverted": the bad write may still be in place.
    @Test func flaggedRunNeverClaimsAReversion() throws {
        let record = try facts(
            "audited head \(inspected.rawValue); verification failed: new finding D15-1; "
                + "revert=refused (current head x diverged from written head \(written.rawValue)); FLAGGED for review; "
                + "per_finding=D06-1; authority_tier=perFindingRepair")
        let state = derive(finding(), runs: [run(.failed, record: record)])
        guard case .failed(_, let reason) = state else {
            Issue.record("expected the failed state, got \(state)")
            return
        }
        #expect(reason.contains("could not be reverted"))
        #expect(state.statusLine?.contains("was reverted") == false)
    }

    @Test func pageChangedRefusalSaysReRunLint() throws {
        let record = try facts(
            "Page changed since this finding — re-run lint. No change was written: head moved; "
                + "per_finding=D06-1; per_finding_outcome=page-changed; authority_tier=perFindingRepair")
        #expect(record.perFindingRefusal == .pageChanged)
        let state = derive(finding(), runs: [run(.completed, record: record)])
        #expect(state == .pageChanged(itemID: QueueItem.ID(rawValue: "fix-item")))
        #expect(state.statusLine == "Page changed since this finding — re-run lint.")
    }

    @Test func otherRefusalsAndFailuresNameTheirReason() throws {
        let unavailable = try facts(
            "The lint model could not start. No change was written: x; per_finding=D06-1; "
                + "per_finding_outcome=model-unavailable; authority_tier=perFindingRepair")
        let modelState = derive(finding(), runs: [run(.failed, record: unavailable)])
        #expect(modelState.statusLine?.contains("check Settings") == true)

        // No report at all, the item failed: the item's own error.
        #expect(derive(finding(), runs: [run(.failed, error: "spawn refused")])
            == .failed(itemID: QueueItem.ID(rawValue: "fix-item"), reason: "spawn refused"))
        // Cancelled.
        #expect(derive(finding(), runs: [run(.cancelled)]).statusLine
            == "The fix did not run: the fix run was cancelled")
        // Settled but its report has not loaded yet: still honest in-flight.
        #expect(derive(finding(), runs: [run(.completed)])
            == .inFlight(itemID: QueueItem.ID(rawValue: "fix-item")))
        // Queued / running.
        #expect(derive(finding(), runs: [run(.queued)])
            == .inFlight(itemID: QueueItem.ID(rawValue: "fix-item")))
    }

    @Test func noWriteRunSaysTheFindingStays() throws {
        let record = try facts(
            "audited head \(inspected.rawValue); verification verified on the written head; "
                + "per_finding=D06-1; written_head=\(inspected.rawValue); authority_tier=perFindingRepair")
        let state = derive(finding(), runs: [run(.completed, record: record)])
        #expect(state == .noChange(itemID: QueueItem.ID(rawValue: "fix-item")))
        #expect(state.statusLine == "The fix run made no change — the finding stays. Edit the page manually.")
    }

    /// The newest fix run for a finding wins (a retry after a page-changed
    /// refusal shows the retry's outcome).
    @Test func newestFixRunWins() throws {
        let refused = try facts(
            "x; per_finding=D06-1; per_finding_outcome=page-changed; authority_tier=perFindingRepair")
        let state = derive(finding(), runs: [run(.completed, record: refused), run(.running)])
        #expect(state == .inFlight(itemID: QueueItem.ID(rawValue: "fix-item")))
    }
}
