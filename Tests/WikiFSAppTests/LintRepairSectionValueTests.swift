import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// The lint repair section's SwiftUI-drawn strings and visibility rules,
/// pinned as pure values (the hosted suite pins the AppKit wiring; these
/// pin the words). The inputs are the durable record texts the W2a
/// accounting writes.
@Suite("Lint repair section values")
@MainActor
struct LintRepairSectionValueTests {

    private let v1 = PageVersionID(rawValue: "v1")
    private let v2 = PageVersionID(rawValue: "v2")
    private let v9 = PageVersionID(rawValue: "v9")
    private let pageA = PageID(rawValue: "pa")
    private let pageB = PageID(rawValue: "pb")
    private let wikiID = WikiID(rawValue: "w")
    private let approval1 = LintApprovalID(rawValue: "apr-1")

    // MARK: - Record builders

    private func record(
        _ pageID: PageID, title: String, state: QueueReportTargetState,
        detail: String
    ) -> QueueReportTargetRecord {
        QueueReportTargetRecord(
            target: .page(pageID), displayName: title, state: state, detail: detail)
    }

    private func survivingRepairDetail(
        inspected: PageVersionID, written: PageVersionID
    ) -> String {
        let labels = "authority_tier=shippedApproval; approval_id=\(approval1.rawValue); "
        return labels
            + "audited head \(inspected.rawValue); run-report coverage complete; "
            + "verification verified on the written head; "
            + "written_head=\(written.rawValue); " + labels
    }

    private func autoRevertedDetail(
        inspected: PageVersionID, written: PageVersionID
    ) -> String {
        let labels = "authority_tier=shippedApproval; approval_id=\(approval1.rawValue); "
        let revert = "revert=reverted to \(inspected.rawValue) from \(written.rawValue)"
        return labels + revert + "; "
            + "audited head \(inspected.rawValue); run-report coverage complete; "
            + "verification failed: claimed repair for D03|line-3#1 but the finding persists on the written head; "
            + "written_head=\(written.rawValue); " + revert + "; " + labels
    }

    private func report(
        operation: QueueReportOperation = .lint,
        scope: QueueReportScope,
        records: [QueueReportTargetRecord] = []
    ) -> QueueAttemptReport {
        QueueAttemptReport(
            attemptID: QueueAttemptID(itemID: QueueItem.ID(rawValue: "i"), attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: 1),
            operation: operation,
            scope: scope,
            phase: .finished,
            provider: ProviderID(rawValue: "anthropic"),
            model: QueueReportModelName(rawValue: "claude-opus"),
            availability: .available,
            resultSummary: nil, usage: nil, outputs: nil,
            targets: records)
    }

    // MARK: - Mapping and visibility

    @Test func makeMapsSurvivingRepairAndFailurePages() throws {
        let section = try #require(QueueRunDetailsLintRepair.make(
            report: report(scope: .targets([
                record(pageA, title: "Clean repair", state: .succeeded,
                       detail: survivingRepairDetail(inspected: v1, written: v2)),
                record(pageB, title: "Reverted", state: .failed(reason: "x"),
                       detail: autoRevertedDetail(inspected: v1, written: v2)),
            ])), wikiID: wikiID))

        #expect(section.appliedFixCount == 1)
        #expect(section.repairPages.count == 1)
        #expect(section.repairPages.first?.pageID == pageA)
        #expect(section.repairPages.first?.title == "Clean repair")
        #expect(section.repairPages.first?.inspectedHead == v1)
        #expect(section.repairPages.first?.writtenHead == v2)
        #expect(section.failurePages.count == 1)
        #expect(section.failurePages.first?.pageID == pageB)
        #expect(section.failurePages.first?.reasons == [
            "claimed repair for D03|line-3#1 but the finding persists on the written head",
        ])
        #expect(section.approvalID == approval1)
        #expect(section.showsUndoButton, "the surviving repair shows the undo button")
        #expect(section.showsDisclosure, "the failure record shows the disclosure")
    }

    @Test func undoHidesForReportOnlyBudgetRejectedAndWholeWiki() throws {
        // Report-only tier: no surviving repair, no failure record.
        let reportOnlyReport = report(scope: .targets([
            record(pageA, title: "R", state: .succeeded,
                   detail: "authority_tier=reportOnly; authority_reason=gates; "
                       + "audited head \(v1.rawValue); "
                       + "no run scratch to read the run report from"),
        ]))
        let reportOnly = QueueRunDetailsLintRepair.make(
            report: reportOnlyReport, wikiID: wikiID)
        #expect(reportOnly == nil, "a pure report-only run renders no section at all")

        // Budget-rejected: the write phase never happened.
        let budget = QueueRunDetailsLintRepair.make(
            report: report(scope: .targets([
                record(pageA, title: "B", state: .failed(reason: "x"),
                       detail: "authority_tier=budgetExceeded; authority_reason=hunks=9/6; "
                           + "audited head \(v1.rawValue); write phase not performed — patch rejected whole: hunks=9/6; "
                           + "written_head=\(v1.rawValue); authority_tier=budgetExceeded"),
            ])), wikiID: wikiID)
        #expect(budget == nil, "a rejected patch wrote nothing to undo or disclose")

        // Auto-reverted: already undone by the host.
        let reverted = try #require(QueueRunDetailsLintRepair.make(
            report: report(scope: .targets([
                record(pageA, title: "F", state: .failed(reason: "x"),
                       detail: autoRevertedDetail(inspected: v1, written: v2)),
            ])), wikiID: wikiID))
        #expect(reverted.showsUndoButton == false)
        #expect(reverted.showsDisclosure)

        // Whole-wiki report-only scope: the marker carries no records.
        let wholeWiki = QueueRunDetailsLintRepair.make(
            report: report(scope: .wholeWiki, records: []), wikiID: wikiID)
        #expect(wholeWiki == nil, "whole-wiki report-only runs render no section")

        // Non-lint operations never map.
        let ingest = QueueRunDetailsLintRepair.make(
            report: report(
                operation: .ingest,
                scope: .targets([record(pageA, title: "S", state: .succeeded,
                                        detail: survivingRepairDetail(inspected: v1, written: v2))]),
                records: []),
            wikiID: wikiID)
        #expect(ingest == nil)
    }

    // MARK: - The undo aggregate's honest wording

    @Test func undoSummaryCountsEachOutcomeClass() throws {
        func result(
            _ pageID: PageID, _ outcome: LintUndoService.PageOutcome
        ) -> LintUndoService.PageResult {
            LintUndoService.PageResult(pageID: pageID, outcome: outcome)
        }
        let full = LintUndoService.BatchResult(
            pages: [result(pageA, .reverted), result(pageB, .reverted)],
            breakerVerdict: .clean)
        #expect(full.revertedCount == 2)
        let repairRecord = record(pageA, title: "A", state: .succeeded,
                                  detail: survivingRepairDetail(inspected: v1, written: v2))
        let sectionFull = try #require(QueueRunDetailsLintRepair.make(
            report: report(scope: .targets([repairRecord])), wikiID: wikiID,
            undoResult: full))
        #expect(sectionFull.undoSummary == "Undo: 2 reverted.")

        let partial = LintUndoService.BatchResult(
            pages: [result(pageA, .reverted), result(pageB, .headMoved(current: v9))],
            breakerVerdict: nil)
        let partialReport = report(scope: .targets([
            repairRecord,
            record(pageB, title: "B", state: .succeeded,
                   detail: survivingRepairDetail(inspected: v1, written: v2)),
        ]))
        let sectionPartial = try #require(QueueRunDetailsLintRepair.make(
            report: partialReport, wikiID: wikiID,
            undoResult: partial))
        #expect(sectionPartial.undoSummary == "Undo: 1 reverted, 1 changed since this run.")
        #expect(sectionPartial.showsUndoButton == false,
                "one undo per run — the button hides once the batch ran")
        #expect(sectionPartial.headMovedResults.count == 1)

        let refused = LintUndoService.BatchResult(
            pages: [result(pageA, .failed(reason: "store refused"))],
            breakerVerdict: nil)
        let sectionRefused = try #require(QueueRunDetailsLintRepair.make(
            report: report(scope: .targets([repairRecord])), wikiID: wikiID,
            undoResult: refused))
        #expect(sectionRefused.undoSummary == "Undo: 1 failed.")
    }

    // MARK: - Breaker context and trip wording

    @Test func breakerContextLineReportsUsageAndTrip() {
        let clean = ActivityWindowView.breakerContextLine(
            .init(windowSize: 10, verificationFailures: 1, userUndos: 2, tripReason: nil))
        #expect(clean.contains("2 of 2 allowed user undos used"))
        #expect(clean.contains("1 of 2 allowed verification failures used"))
        #expect(clean.contains("Tripped") == false)

        let tripped = ActivityWindowView.breakerContextLine(
            .init(windowSize: 10, verificationFailures: 2, userUndos: 2,
                  tripReason: "2 user undos in the last 10 repair runs"))
        #expect(tripped.contains("Tripped — 2 user undos in the last 10 repair runs."))
    }

    @Test func tripMessageCarriesTheBreakerReason() throws {
        #expect(LintUndoService.breakerTripMessage(.clean) == nil)
        let message = try #require(
            LintUndoService.breakerTripMessage(
                .tripped(reason: "2 user undos in the last 3 repair runs")))
        #expect(message == "Auto-repair paused for this configuration: "
            + "2 user undos in the last 3 repair runs.")
    }

    // MARK: - Page titles for the manual-revert rows

    @Test func pageTitleResolvesFromSectionRecords() throws {
        let section = try #require(QueueRunDetailsLintRepair.make(
            report: report(scope: .targets([
                record(pageA, title: "Named page", state: .succeeded,
                       detail: survivingRepairDetail(inspected: v1, written: v2)),
            ])), wikiID: wikiID))
        #expect(QueueRunDetailsView.pageTitle(for: pageA, in: section) == "Named page")
        #expect(QueueRunDetailsView.pageTitle(for: PageID(rawValue: "unknown"), in: section)
            == "unknown", "a page outside the section's records falls back to the raw id")
    }
}
