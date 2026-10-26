import Foundation
import WikiFSCore
import WikiFSEngine

/// The Run Details panel's detected-findings section — the value model the
/// panel renders for lint runs whose records carry the accounting's
/// findings labels (`findings=<n>` plus one `finding=` segment per
/// detection, `LintPageRecordFacts.findingsDetail`).
///
/// This is the report-only run's findings surface (plan §5.10/§5.14): a run
/// that may not write anything still DETECTS, and its detections render —
/// total, per-class counts, each finding's class label, assigned outcome,
/// and the scan's evidence excerpt — instead of vanishing because the run
/// has no written repairs (the W2b section) and no staged proposals (the
/// W5b section) to show.
///
/// Everything derives from ALREADY-PERSISTED data: the durable queue
/// report's per-page records re-parsed by `LintPageRecordFacts`. Nothing is
/// invented: a record without the findings labels (written before they
/// existed) contributes nothing, and a run whose records carry no labels at
/// all maps to `nil` — the section stays absent rather than guessing.
struct QueueRunDetailsLintFindings: Sendable, Equatable {

    /// One page's detected findings, in recorded order.
    struct PageFindings: Identifiable, Sendable, Equatable {
        let pageID: PageID
        let title: String
        /// The record's parsed findings.
        let findings: [LintPageRecordFacts.RecordFinding]
        /// The record's `findings=<n>` total. Equals `findings.count` for
        /// records this build reads; kept separate so a future parse
        /// mismatch can never silently change the total.
        let reportedCount: Int

        var id: PageID { pageID }
    }

    /// The pages whose records carry findings labels, in report order.
    let pages: [PageFindings]
    /// Why the run was report-only (`authority_reason=` from a record whose
    /// tier is `.reportOnly`). `nil` when no record names a report-only
    /// tier — the honest line renders only when the records state it.
    let reportOnlyReason: String?

    /// Every record's total detections.
    var totalCount: Int { pages.reduce(0) { $0 + $1.reportedCount } }

    /// Per-class counts across all records, class label ordered
    /// (`"D03" → 2`). The per-class counts row's data.
    var countsByClass: [(classLabel: String, count: Int)] {
        var counts: [String: Int] = [:]
        for page in pages {
            for finding in page.findings {
                counts[finding.classLabel, default: 0] += 1
            }
        }
        return counts.sorted { $0.key < $1.key }
            .map { (classLabel: $0.key, count: $0.value) }
    }

    /// The per-class counts row's text ("D03 ×2, D07 ×1"), or nil when
    /// nothing was detected.
    var classCountsSummary: String? {
        guard totalCount > 0 else { return nil }
        return countsByClass
            .map { "\($0.classLabel) ×\($0.count)" }
            .joined(separator: ", ")
    }

    /// Whether the section renders at all: at least one record carries the
    /// findings labels. A clean report-only run carries `findings=0` and
    /// renders "none detected" — an honest zero, not an absent section.
    var showsSection: Bool { pages.isEmpty == false }

    /// The honest report-only line, rendered as one row: the recorded
    /// reason the run could not repair, and what a repair would need
    /// instead. `nil` when no record names a report-only tier.
    var reportOnlyLine: String? {
        guard let reportOnlyReason else { return nil }
        return "Report-only run — \(reportOnlyReason). Findings are reported, not repaired: "
            + "repairs need an approved configuration or staged-proposal review."
    }

    /// Map a lint attempt's durable report into the section, or nil when
    /// nothing here applies (a non-lint run, a whole-wiki scope with no
    /// per-page records, or records that predate the findings labels).
    static func make(report: QueueAttemptReport) -> QueueRunDetailsLintFindings? {
        guard report.operation == .lint else { return nil }
        guard case .targets(let records) = report.scope else { return nil }

        var pages: [PageFindings] = []
        var reportOnlyReason: String?
        for record in records {
            guard let facts = LintPageRecordFacts.parse(record: record),
                  let reportedCount = facts.findingCount else { continue }
            pages.append(PageFindings(
                pageID: facts.pageID, title: facts.title,
                findings: facts.findings, reportedCount: reportedCount))
            if reportOnlyReason == nil, facts.tier == .reportOnly {
                reportOnlyReason = facts.authorityReason
            }
        }
        guard pages.isEmpty == false else { return nil }
        return QueueRunDetailsLintFindings(
            pages: pages, reportOnlyReason: reportOnlyReason)
    }
}
