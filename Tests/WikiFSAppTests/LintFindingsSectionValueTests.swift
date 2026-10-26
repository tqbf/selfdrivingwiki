import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// The lint findings section's mapping and visibility rules, pinned as pure
/// values (the hosted suite pins the window wiring; these pin the words and
/// the counts). The inputs are the durable record texts the accounting
/// writes — `findings=<n>` plus one `finding=` segment per detection.
@Suite("Lint findings section values")
@MainActor
struct LintFindingsSectionValueTests {

    private let pageA = PageID(rawValue: "pa")
    private let pageB = PageID(rawValue: "pb")
    private let wikiID = WikiID(rawValue: "w")

    // MARK: - Record builders

    private func record(
        _ pageID: PageID, title: String, state: QueueReportTargetState,
        detail: String
    ) -> QueueReportTargetRecord {
        QueueReportTargetRecord(
            target: .page(pageID), displayName: title, state: state, detail: detail)
    }

    /// The accounting detail a report-only run writes for a page with two
    /// detections: the trace labels, the audit detail, and the findings
    /// labels (`findings=<n>` + one `finding=` segment each).
    private func reportOnlyDetail(findings: Int) -> String {
        var detail = "authority_tier=reportOnly; "
            + "authority_reason=gate components not fully resolved; "
            + "audited head v1; run-report coverage complete; "
            + "verification verified on the written head; findings=\(findings)"
        if findings > 0 {
            detail += "; finding=D15|line-3#1 D15 unresolved evidence=<<<<<<< HEAD, note"
            detail += "; finding=D07|line-9#1 D07 unresolved evidence=broken target"
        }
        detail += "; written_head=v1; authority_tier=reportOnly; "
            + "authority_reason=gate components not fully resolved"
        return detail
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

    // MARK: - Mapping

    @Test func makeMapsFindingsAndReportOnlyReason() throws {
        let section = try #require(QueueRunDetailsLintFindings.make(
            report: report(scope: .targets([
                record(pageA, title: "Damaged", state: .succeeded,
                       detail: reportOnlyDetail(findings: 2)),
            ]))))

        #expect(section.showsSection)
        #expect(section.totalCount == 2)
        #expect(section.pages.count == 1)
        #expect(section.pages[0].pageID == pageA)
        #expect(section.pages[0].title == "Damaged")
        #expect(section.pages[0].findings.count == 2)
        #expect(section.pages[0].findings[0].classLabel == "D15")
        #expect(section.pages[0].findings[0].outcomeToken == "unresolved")
        #expect(section.pages[0].findings[0].evidence == "<<<<<<< HEAD, note")
        #expect(section.reportOnlyReason == "gate components not fully resolved")
        // The honest line names the reason and what a repair would need.
        #expect(section.reportOnlyLine == "Report-only run — gate components not fully "
            + "resolved. Findings are reported, not repaired: repairs need an approved "
            + "configuration or staged-proposal review.")
        // Per-class counts, class label ordered.
        #expect(section.countsByClass.map { $0.classLabel } == ["D07", "D15"])
        #expect(section.countsByClass.map { $0.count } == [1, 1])
        #expect(section.classCountsSummary == "D07 ×1, D15 ×1")
    }

    @Test func cleanReportOnlyRunMapsTheHonestZero() throws {
        let section = try #require(QueueRunDetailsLintFindings.make(
            report: report(scope: .targets([
                record(pageA, title: "Clean", state: .succeeded,
                       detail: reportOnlyDetail(findings: 0)),
            ]))))

        #expect(section.showsSection, "a clean run renders the section with none detected")
        #expect(section.totalCount == 0)
        #expect(section.classCountsSummary == nil)
        #expect(section.pages[0].findings.isEmpty)
        #expect(section.reportOnlyReason == "gate components not fully resolved")
    }

    @Test func countsAggregateAcrossPages() throws {
        let section = try #require(QueueRunDetailsLintFindings.make(
            report: report(scope: .targets([
                record(pageA, title: "First", state: .succeeded,
                       detail: reportOnlyDetail(findings: 2)),
                record(pageB, title: "Second", state: .succeeded,
                       detail: reportOnlyDetail(findings: 1)),
            ]))))

        #expect(section.pages.count == 2)
        #expect(section.totalCount == 3)
    }

    // MARK: - Visibility

    @Test func legacyRecordsAndNonLintRunsRenderNothing() {
        // Records written before the findings labels existed: no section,
        // never an invented count.
        let legacy = QueueRunDetailsLintFindings.make(
            report: report(scope: .targets([
                record(pageA, title: "Legacy", state: .succeeded,
                       detail: "authority_tier=reportOnly; audited head v1; "
                           + "no run scratch to read the run report from"),
            ])))
        #expect(legacy == nil)

        // Whole-wiki scope carries no per-page records.
        let wholeWiki = QueueRunDetailsLintFindings.make(
            report: report(scope: .wholeWiki, records: []))
        #expect(wholeWiki == nil)

        // Non-lint operations never map.
        let ingest = QueueRunDetailsLintFindings.make(
            report: report(
                operation: .ingest,
                scope: .targets([record(pageA, title: "S", state: .succeeded,
                                        detail: reportOnlyDetail(findings: 1))]),
                records: []))
        #expect(ingest == nil)
    }

    @Test func nonReportOnlyTiersMapFindingsWithoutTheReasonLine() throws {
        // A shipped-approval repair run's records carry findings labels
        // too; the section renders them, but there is no report-only line.
        let detail = "authority_tier=shippedApproval; approval_id=apr-1; "
            + "audited head v1; run-report coverage complete; "
            + "verification verified on the written head; findings=1; "
            + "finding=D03|line-3#1 D03 repaired evidence=| broken |"
            + "; written_head=v2; authority_tier=shippedApproval; approval_id=apr-1"
        let section = try #require(QueueRunDetailsLintFindings.make(
            report: report(scope: .targets([
                record(pageA, title: "Repaired", state: .succeeded, detail: detail),
            ]))))
        #expect(section.totalCount == 1)
        #expect(section.pages[0].findings[0].outcomeToken == "repaired")
        #expect(section.reportOnlyReason == nil)
        #expect(section.reportOnlyLine == nil)
    }
}
