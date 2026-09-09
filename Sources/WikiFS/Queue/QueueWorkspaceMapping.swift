import Foundation
import WikiFSCore
import WikiFSEngine

/// Pure mapping from the queue backend types (`QueueItem`, `QueueReportSummary`,
/// `QueueAttemptReport`) onto the queue-workspace presentation values
/// (`QueueJobHeaderPresentation`, `QueueJobOverviewPresentation`).
///
/// Everything here is a static, side-effect-free function so the Activity
/// window can derive presentation values *before* view body evaluation — the
/// observation-crash workaround (see `ActivityWindowView.buildRowDisplayData`)
/// and the plan's "derive presentation values from immutable inputs before list
/// iteration" rule both hold. Actions are injected as closures; this layer
/// performs no commands and reads no `@Observable` state.
///
/// Report truth rules honored here (plan §"Report truth rules"):
/// - Determinate progress only for a known total with an observed numerator.
/// - Unknown counts are absent, never zero.
/// - `.interrupted` targets project as interrupted, never failed/succeeded.
/// - The provider is passed through as reported; callers never pass a capacity
///   bucket (producers only set the actual provider).
enum QueueWorkspaceMapper {

    // MARK: - Lifecycle

    /// `QueueItem.State` → the workspace lifecycle, 1:1 (plan: "QueueItemState
    /// stays the authority").
    static func lifecycle(for state: QueueItemState) -> QueueWorkspaceJobLifecycle {
        switch state {
        case .queued: return .queued
        case .running: return .running
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    /// Operation word for the selected-job header: "Ingest" / "Extract" /
    /// "Lint" (plan §1 header). Derived from the payload + queue kind exactly
    /// like the navigator's kind labels.
    static func operationLabel(for item: QueueItem) -> String {
        if item.payload.lintPageIDs != nil { return "Lint" }
        switch item.queue {
        case .ingestion: return "Ingest"
        case .extraction, .transcription: return "Extract"
        }
    }

    /// The selected-job header title: the full operation label made explicit
    /// as a prefix over the job details — "Ingestion: <Job Details>",
    /// "Extraction: <Job Details>", "Lint: <Job Details>" — so the job type
    /// reads in the title itself, not only in secondary metadata. Keyed on
    /// the recorded operation (lint-vs-ingest from the payload, same
    /// derivation as ``reportOperation(for:)``) so title and report never
    /// disagree.
    static func headerTitle(operation: QueueReportOperation, jobTitle: String) -> String {
        switch operation {
        case .ingest: return "Ingestion: \(jobTitle)"
        case .extract: return "Extraction: \(jobTitle)"
        case .lint: return "Lint: \(jobTitle)"
        }
    }

    /// The recorded operation for an item — the header/overview language
    /// selector. Lint-vs-ingest comes from the payload, exactly like the
    /// producers' report-begin decision, so UI and report never disagree.
    static func reportOperation(for item: QueueItem) -> QueueReportOperation {
        if item.payload.lintPageIDs != nil { return .lint }
        switch item.queue {
        case .ingestion: return .ingest
        case .extraction, .transcription: return .extract
        }
    }

    // MARK: - Header

    /// Phase progress for the header, derived from the item's report summary.
    /// `nil` when nothing countable is recorded (queued before any phase, a
    /// whole-wiki scope, unknown totals) — the header renders no progress
    /// region rather than a fake "0 of N".
    ///
    /// **Live-only presentation (M1):** progress renders only while the job
    /// lifecycle is `.running`. A failed or cancelled run can leave its last
    /// committed report mid-phase (the worker threw between `.staging` /
    /// `.running` and any terminal commit), and that stale phase must never
    /// animate a live-looking bar on a job that is no longer running. Queued
    /// and terminal jobs show no progress; terminal jobs show the static
    /// duration clock instead.
    ///
    /// Numerators are the phase-specific *observed* counts from the summary:
    /// - staging: every target no longer planned (the staging front).
    /// - running: every target handed to or finished by the operation — for
    ///   ingestion that is "submitted" (per-source completion is never
    ///   inferred), for extraction/lint the observed outcomes so far.
    static func headerProgress(
        from summary: QueueReportSummary?,
        operation: QueueReportOperation,
        payloadTargetCount: Int,
        jobLifecycle: QueueWorkspaceJobLifecycle
    ) -> QueueWorkspaceProgress? {
        guard jobLifecycle == .running else { return nil }
        guard let summary, summary.availability == .available else { return nil }
        // Known total: the recorded inventory size when present, else the
        // payload count. Both absent → nothing is countable → the determinate
        // cases fall back to indeterminate rather than a fake "0 of N".
        let recordedTotal = summary.phaseCounts.values.reduce(0, +)
        let total = recordedTotal > 0 ? recordedTotal : payloadTargetCount
        let counts = summary.phaseCounts

        func reachedExcludingPlanned() -> Int {
            total - (counts[.planned] ?? 0)
        }

        func handedToOperation() -> Int {
            (counts[.submitted] ?? 0) + (counts[.processing] ?? 0)
                + (counts[.succeeded] ?? 0) + (counts[.skipped] ?? 0)
                + (counts[.failed] ?? 0)
        }

        switch summary.phase {
        case .planned:
            return nil
        case .staging:
            // Determinate needs a known total with an observed numerator.
            guard total > 0 else {
                return .indeterminate(phase: "Staging \(unitName(for: operation))")
            }
            return .determinate(
                phase: "Staging \(unitName(for: operation))",
                completed: reachedExcludingPlanned(),
                total: total)
        case .launching:
            return .indeterminate(phase: "Launching")
        case .running:
            guard total > 0 else {
                return .indeterminate(
                    phase: "\(runningVerb(for: operation)) \(unitName(for: operation))")
            }
            return .determinate(
                phase: "\(runningVerb(for: operation)) \(unitName(for: operation))",
                completed: handedToOperation(),
                total: total)
        case .merging:
            return .indeterminate(phase: "Merging")
        case .persisting:
            return .indeterminate(phase: "Persisting")
        case .finished:
            // Terminal — the header shows the static duration clock instead.
            return nil
        }
    }

    /// The counted-language verb for a running phase (plan §"Operation
    /// language"): ingestion counts submissions, never "ingested".
    static func runningVerb(for operation: QueueReportOperation) -> String {
        switch operation {
        case .ingest: return "Submitted"
        case .extract: return "Processing"
        case .lint: return "Checking"
        }
    }

    /// Countable unit noun: "sources" for ingest/extract, "pages" for lint.
    static func unitName(for operation: QueueReportOperation) -> String {
        switch operation {
        case .ingest, .extract: return "sources"
        case .lint: return "pages"
        }
    }

    /// The Overview section noun (plan: kind-specific language is the
    /// caller's): "Inputs" for ingest (whose Overview gains the provenance-
    /// resolved "Outputs" section), "Sources" for extract, "Pages" for a
    /// page-level lint, "Scope" for whole-wiki.
    static func sectionTitle(for operation: QueueReportOperation, isWholeWiki: Bool) -> String {
        switch operation {
        case .ingest: return "Inputs"
        case .extract: return "Sources"
        case .lint: return isWholeWiki ? "Scope" : "Pages"
        }
    }

    // MARK: - Recorded outputs (ingestion)

    /// The fixed section noun for the ingestion-only outputs region.
    static let outputsSectionTitle = "Outputs"

    /// Suffix marking a cap-filling outputs count ("200+"): at
    /// `QueueWorkspaceMetrics.Outputs.maxRows` the number is a truncation
    /// floor, not a total.
    static let truncatedCountSuffix = "+"

    /// Count text for a completed recorded-outputs load: the loaded row
    /// count — or that count plus ``truncatedCountSuffix`` when it fills the
    /// store-query row cap (`QueueWorkspaceMetrics.Outputs.maxRows`). A
    /// full-page result means the store result was TRUNCATED at the cap, so
    /// a bare "200" would read as a verified total; "200+" reads as the
    /// bounded floor it is.
    static func outputsCountText(rowCount: Int) -> String {
        rowCount >= QueueWorkspaceMetrics.Outputs.maxRows
            ? "\(rowCount)\(truncatedCountSuffix)"
            : String(rowCount)
    }

    /// Map the selected job's recorded-outputs load onto section values.
    ///
    /// Count text: known only after a completed load — including a resolved
    /// zero ("Outputs (0)" is store evidence, not a fabricated number).
    /// While loading and on failure the count is unknown → `nil`, which the
    /// view renders as nothing (never "0").
    ///
    /// Empty-state text distinguishes the three honest states: a load in
    /// flight, a load that completed with no citation evidence, and a store
    /// read failure — "no pages recorded" is never claimed when the read
    /// simply failed.
    static func outputsSection(
        state: QueueOutputsLoadState,
        nameIndex: QueueTargetNameIndex,
        openPage: @escaping (PageID) -> Void
    ) -> QueueOutputsSectionValue {
        switch state {
        case .loading:
            return QueueOutputsSectionValue(
                countText: nil,
                rows: [],
                emptyStateText: "Loading recorded pages…")
        case .failed:
            return QueueOutputsSectionValue(
                countText: nil,
                rows: [],
                emptyStateText: "Recorded pages couldn’t be loaded.")
        case .loaded(let pages):
            let rows = pages.map {
                outputRow(cited: $0, nameIndex: nameIndex, openPage: openPage)
            }
            return QueueOutputsSectionValue(
                countText: outputsCountText(rowCount: rows.count),
                rows: rows,
                emptyStateText: "No pages recorded yet.")
        }
    }

    /// One recorded-output row. Title resolution — the queue's live-title
    /// seam first (`nameIndex`, the same one that drives every other row),
    /// then the recorded store title, then the honest "Deleted page"
    /// degradation. The Open Page name link appears only while the page
    /// resolves through the live seam (same membership rule as the
    /// inventory's `rowActions`): a page that no longer resolves keeps its
    /// name as plain text and never renders a dead link.
    static func outputRow(
        cited: CitedPage,
        nameIndex: QueueTargetNameIndex,
        openPage: @escaping (PageID) -> Void
    ) -> QueueTargetRowValue {
        let identity = QueueWorkspaceTargetIdentity.page(cited.pageID)
        let liveTitle = nameIndex.pageTitle(cited.pageID)
        let title = liveTitle ?? cited.title ?? "Deleted page"
        let actions: [QueueWorkspaceAction] = liveTitle == nil ? [] : [
            QueueWorkspaceAction(
                label: "Open Page", systemImage: "arrow.up.forward.app") {
                openPage(cited.pageID)
            }
        ]
        return QueueTargetRowValue(
            identity: identity,
            title: title,
            status: .recorded(),
            actions: actions)
    }

    // MARK: - Target states → status / reason

    /// Report target state → the shared status vocabulary. `.interrupted`
    /// projects as its own interrupted presentation, never failed/succeeded
    /// (report truth rule 10).
    static func targetStatus(
        for state: QueueReportTargetState,
        result: QueueTargetResult?
    ) -> QueueWorkspaceStatus {
        switch state {
        case .planned: return .planned()
        case .preparing: return .preparing()
        case .submitted: return .submitted()
        case .processing: return .processing()
        case .succeeded: return .succeeded()
        case .skipped: return .skipped()
        case .failed: return .failedTarget()
        case .interrupted: return .interrupted()
        // Operator decision (2026-09-08): unobserved targets render as
        // "Planned" — the same vocabulary as not-yet-run rows. Absence of
        // evidence stays truthful in the Run Details inspector ("Not
        // Reported") and never reads as a zero or an empty success.
        case .notReported: return .planned()
        }
    }

    /// The row's disclosed reason line: the recorded skip/failure reason when
    /// present, else the record's `detail` (producers put the output evidence
    /// note there). Recorded strings only — never inferred.
    static func targetReason(for record: QueueReportTargetRecord) -> String? {
        switch record.state {
        case .skipped(let reason): return reason
        case .failed(let reason): return reason
        default: return record.detail
        }
    }

    // MARK: - Summary synthesis (cache merge path)

    /// Synthesize the bounded navigator summary for a freshly committed report
    /// so the tracker's summary cache can merge `.reportUpdated` events without
    /// re-reading the store. Search text folds recorded names, reasons, and the
    /// result summary, bounded **exactly like the store's own summaries**
    /// (`QueueReportSummaryLimits`): at most `maxSearchTargets` target records
    /// each contributing up to three fields (display name, skip/fail reason,
    /// detail), each field capped at `maxFieldLength`, then the result summary
    /// as one more capped field, all joined and capped at `maxTotalLength`.
    /// Keeping the two paths byte-identical means searching the navigator finds
    /// the same text whether a summary came from the store or from an event.
    static func summary(from report: QueueAttemptReport) -> QueueReportSummary {
        var fields: [String] = []
        func fold(_ raw: String?) {
            guard let raw, raw.isEmpty == false else { return }
            fields.append(String(raw.prefix(QueueReportSummaryLimits.maxFieldLength)))
        }
        var targetsUsed = 0
        for target in report.targets {
            guard targetsUsed < QueueReportSummaryLimits.maxSearchTargets else { break }
            targetsUsed += 1
            fold(target.displayName)
            switch target.state {
            case .skipped(let reason), .failed(let reason): fold(reason)
            default: break
            }
            fold(target.detail)
        }
        if let result = report.resultSummary { fold(result) }
        let searchText = String(
            fields.joined(separator: " ")
                .prefix(QueueReportSummaryLimits.maxTotalLength))
        return QueueReportSummary(
            itemID: report.attemptID.itemID,
            attempt: report.attemptID.attempt,
            revision: report.revision,
            phase: report.phase,
            availability: report.availability,
            phaseCounts: report.counts(),
            resultSummary: report.resultSummary,
            searchText: searchText)
    }
}

// MARK: - Target-failure / interrupted status vocabulary

extension QueueWorkspaceStatus {
    /// A recorded target failure (distinct from the job-level `.failed()` —
    /// one aggregate error never marks every target failed, report truth
    /// rule 4).
    static func failedTarget() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Failed", symbol: "xmark.octagon", style: .failure)
    }

    /// A dispatch died (cancel/halt/crash) before observing this target.
    /// Truth rule 10: unfinished targets project as interrupted, never as
    /// failed or succeeded.
    static func interrupted() -> QueueWorkspaceStatus {
        QueueWorkspaceStatus(text: "Interrupted", symbol: "pause.circle", style: .warning)
    }
}
