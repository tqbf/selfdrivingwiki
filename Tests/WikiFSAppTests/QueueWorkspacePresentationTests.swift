#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// Pure presentation-logic tests for the queue workspace components
/// (plan-001.md §1/§4). No rendering, no hosting, no live session: every rule
/// the views apply — status vocabulary, progress guards, search matching,
/// run-details omission rules, formatting — is decided by the value types in
/// `QueueWorkspacePresentation.swift`, so tests construct fixtures and assert
/// the decisions directly. Hosted rendering checks come later with the
/// workspace scenario harness (plan §5).
@Suite struct QueueWorkspacePresentationTests {
    // MARK: - Status vocabulary

    @Test func jobLifecycleStatusVocabulary() {
        // Every lifecycle state pairs text + symbol + semantic style; the views
        // never invent their own labels for these.
        #expect(QueueWorkspaceStatus.queued() == QueueWorkspaceStatus(
            text: "Queued", symbol: "clock", style: .secondary))
        #expect(QueueWorkspaceStatus.running() == QueueWorkspaceStatus(
            text: "Running", symbol: "ellipsis.circle", style: .running))
        #expect(QueueWorkspaceStatus.completed() == QueueWorkspaceStatus(
            text: "Completed", symbol: "checkmark.circle.fill", style: .success))
        #expect(QueueWorkspaceStatus.failed() == QueueWorkspaceStatus(
            text: "Failed", symbol: "exclamationmark.triangle.fill", style: .failure))
        #expect(QueueWorkspaceStatus.cancelled() == QueueWorkspaceStatus(
            text: "Cancelled", symbol: "xmark.circle", style: .secondary))
    }

    @Test func targetStatusVocabulary() {
        // §2 target-outcome vocabulary. The `planned()` vocabulary entry
        // still exists (2026-09-08 decision: unknown outcomes never read as
        // zero or empty success), but inventory rows no longer RENDER it —
        // operator decision 2026-09-09: evidence-less rows are name-only,
        // so the mapper maps planned/notReported to `nil` (see
        // plannedRowsCarryNoStatusRealStatesKeepChip).
        #expect(QueueWorkspaceStatus.planned().text == "Planned")
        #expect(QueueWorkspaceStatus.preparing().text == "Preparing")
        #expect(QueueWorkspaceStatus.submitted().text == "Submitted")
        #expect(QueueWorkspaceStatus.processing().text == "Processing")
        #expect(QueueWorkspaceStatus.succeeded().text == "Succeeded")
        #expect(QueueWorkspaceStatus.skipped().text == "Skipped")
        // Every status carries a symbol: color is never the only signal.
        for status in [
            QueueWorkspaceStatus.queued(), .running(), .completed(), .failed(),
            .cancelled(), .planned(), .preparing(), .submitted(), .processing(),
            .succeeded(), .skipped(),
        ] {
            #expect(!status.symbol.isEmpty)
            #expect(!status.text.isEmpty)
        }
    }

    @Test func lifecycleActionVisibility() {
        // Cancel only for queued/running; Retry only for failed/cancelled.
        #expect(QueueWorkspaceJobLifecycle.queued.showsCancelAction)
        #expect(QueueWorkspaceJobLifecycle.running.showsCancelAction)
        #expect(!QueueWorkspaceJobLifecycle.completed.showsCancelAction)
        #expect(!QueueWorkspaceJobLifecycle.failed.showsCancelAction)
        #expect(!QueueWorkspaceJobLifecycle.cancelled.showsCancelAction)

        #expect(QueueWorkspaceJobLifecycle.failed.showsRetryAction)
        #expect(QueueWorkspaceJobLifecycle.cancelled.showsRetryAction)
        #expect(!QueueWorkspaceJobLifecycle.queued.showsRetryAction)
        #expect(!QueueWorkspaceJobLifecycle.running.showsRetryAction)
        #expect(!QueueWorkspaceJobLifecycle.completed.showsRetryAction)

        // The lifecycle status matches the standalone factory.
        #expect(QueueWorkspaceJobLifecycle.running.status == .running())
        #expect(QueueWorkspaceJobLifecycle.failed.status == .failed())
    }

    // MARK: - Progress

    @Test func progressCountsOnlyWhenDeterminate() {
        let indeterminate = QueueWorkspaceProgress.indeterminate(phase: "Merging pages")
        #expect(indeterminate.countsText == nil)
        #expect(indeterminate.phaseText == "Merging pages")

        let determinate = QueueWorkspaceProgress.determinate(
            phase: "Staging sources", completed: 8, total: 12)
        // "8 of 12" — phase-specific numerator and known total only.
        #expect(determinate.countsText == "8 of 12")
        #expect(determinate.phaseText == "Staging sources")
    }

    @Test func determinateProgressGuardRejectsUnknownTotalMisuse() {
        // Known total + observed numerator renders determinate.
        #expect(QueueWorkspaceProgress.determinate(
            phase: "Staging", completed: 8, total: 12).isRenderableDeterminate)
        // A true observed zero with a known total is legitimate: "0 of 12".
        #expect(QueueWorkspaceProgress.determinate(
            phase: "Staging", completed: 0, total: 12).isRenderableDeterminate)
        // Misuse falls back to indeterminate: unknown totals passed as 0,
        // negative numerators, numerator exceeding the total.
        #expect(!QueueWorkspaceProgress.determinate(
            phase: "Staging", completed: 0, total: 0).isRenderableDeterminate)
        #expect(!QueueWorkspaceProgress.determinate(
            phase: "Staging", completed: -1, total: 12).isRenderableDeterminate)
        #expect(!QueueWorkspaceProgress.determinate(
            phase: "Staging", completed: 13, total: 12).isRenderableDeterminate)
        #expect(!QueueWorkspaceProgress.indeterminate(phase: "Staging").isRenderableDeterminate)
    }

    // MARK: - Target rows

    @Test func targetIdentityRowIDNamespacing() {
        // Same raw ULID under different namespaces must produce different row
        // IDs — the case tag is what keeps the spaces separate.
        let raw = "01HZY4X9G2EXAMPLE"
        let sourceID = QueueWorkspaceTargetIdentity.source(SourceID(rawValue: raw))
        let pageID = QueueWorkspaceTargetIdentity.page(PageID(rawValue: raw))
        #expect(sourceID.rowID == "source:\(raw)")
        #expect(pageID.rowID == "page:\(raw)")
        #expect(sourceID.rowID != pageID.rowID)
    }

    @Test func targetRowValueDerivedIDAndDisplayName() {
        let identity = QueueWorkspaceTargetIdentity.source(SourceID(rawValue: "src-1"))
        let row = QueueTargetRowValue(
            identity: identity,
            title: "Research Paper.pdf",
            fullName: "Research Paper — very long original filename.pdf",
            status: nil)
        #expect(row.id == identity.rowID)
        // The full recorded name stays reachable (tooltip/search) even though
        // the collapsed row renders the truncated title.
        #expect(row.displayName == "Research Paper — very long original filename.pdf")

        let noFullName = QueueTargetRowValue(
            identity: identity, title: "Short.pdf", status: nil)
        #expect(noFullName.displayName == "Short.pdf")
    }

    /// Operator decision (2026-09-09): evidence-less inventory rows render
    /// NAME-ONLY — "Planned" is the default state, so it gets no status
    /// circle and no text. The typed signal is
    /// `QueueTargetRowValue.status == nil` (the mapper maps `.planned` /
    /// `.notReported` to `nil`; the view renders the status region only for
    /// a present status). Rows with a real recorded state keep their chip
    /// (symbol + text).
    @Test func plannedRowsCarryNoStatusRealStatesKeepChip() {
        // Mapper seam: no evidence → nil; real states → the chip vocabulary.
        #expect(QueueWorkspaceMapper.targetStatus(for: .planned, result: nil) == nil)
        #expect(QueueWorkspaceMapper.targetStatus(for: .notReported, result: nil) == nil)

        // A planned row value carries no status → the row renders name-only.
        let planned = QueueTargetRowValue(
            identity: QueueWorkspaceTargetIdentity.source(SourceID(rawValue: "src-planned")),
            title: "Pending.pdf",
            status: QueueWorkspaceMapper.targetStatus(for: .planned, result: nil))
        #expect(planned.status == nil,
                "an evidence-less row is name-only: no status circle, no 'Planned' text")

        // A real recorded state keeps its chip (symbol + text present).
        let submitted = QueueTargetRowValue(
            identity: QueueWorkspaceTargetIdentity.source(SourceID(rawValue: "src-submitted")),
            title: "Done.pdf",
            status: QueueWorkspaceMapper.targetStatus(for: .submitted, result: nil))
        #expect(submitted.status?.text == "Submitted")
        #expect(submitted.status?.symbol == "paperplane")
        // …and its status text stays searchable.
        #expect(submitted.matches(query: "submitted"))
    }

    @Test func targetRowSearchMatching() {
        let row = QueueTargetRowValue(
            identity: QueueWorkspaceTargetIdentity.source(SourceID(rawValue: "src-9")),
            title: "Research Long Source.pdf",
            fullName: "Research Long Source — final.pdf",
            status: .skipped(),
            reason: "Source bytes unavailable")
        // Empty or whitespace queries match everything (no filtering).
        #expect(row.matches(query: ""))
        #expect(row.matches(query: "   "))
        // Title, full name, reason, and status text are all searchable;
        // localizedStandardContains is case-insensitive.
        #expect(row.matches(query: "long source"))
        #expect(row.matches(query: "RESEARCH"))
        #expect(row.matches(query: "final.pdf"))
        #expect(row.matches(query: "bytes unavailable"))
        #expect(row.matches(query: "skipped"))
        // Non-matching query filters the row out.
        #expect(!row.matches(query: "podcast"))
        // Scope rows stay findable by title.
        let scope = QueueTargetRowValue(
            id: "scope:whole-wiki", identity: nil, title: "Whole wiki", status: .running())
        #expect(scope.matches(query: "whole"))
        #expect(!scope.matches(query: "pdf"))
    }

    @Test func nilStatusRowDoesNotMatchPlannedQuery() {
        // The 2026-09-09 name-only decision maps planned rows to a nil
        // status, so the haystack never contains the text "Planned" for
        // them — searching "planned" must not silently resurrect rows by
        // matching a status they deliberately do not render.
        let evidenceLess = QueueTargetRowValue(
            identity: QueueWorkspaceTargetIdentity.source(SourceID(rawValue: "src-planned")),
            title: "Pending.pdf",
            status: QueueWorkspaceMapper.targetStatus(for: .planned, result: nil))
        #expect(evidenceLess.status == nil)
        #expect(!evidenceLess.matches(query: "planned"))

        // The chip-bearing counterpart still matches its own status text.
        let skipped = QueueTargetRowValue(
            identity: QueueWorkspaceTargetIdentity.source(SourceID(rawValue: "src-skipped")),
            title: "Pending.pdf", status: .skipped())
        #expect(skipped.matches(query: "skipped"))
        #expect(!skipped.matches(query: "planned"))
    }

    @Test func rowActionClosureInvoked() {
        let counter = ActionCounter()
        let row = QueueTargetRowValue(
            identity: QueueWorkspaceTargetIdentity.page(PageID(rawValue: "page-2")),
            title: "Notes",
            status: .succeeded(),
            actions: [
                QueueWorkspaceAction(label: "Open Page", systemImage: "arrow.up.forward.app") {
                    counter.count += 1
                }
            ])
        #expect(counter.count == 0)
        row.actions[0].perform()
        #expect(counter.count == 1)
    }

    // MARK: - Run details

    @Test func runDetailsOmitUnavailableOptionals() {
        // Nothing recorded: only the facts whose absence matters render, as
        // explicit placeholders — never "—" rows for everything. (The blank
        // default job id omits its row too; the real mapping always supplies
        // `item.id.rawValue`, so the panel's Job ID row never disappears in
        // practice — see runDetailsJobIDRowPresence.)
        let empty = QueueRunDetailsFacts()
        let entries = empty.entries
        #expect(entries.map(\.label) == ["Provider", "Model"])
        #expect(entries.allSatisfy { $0.isPlaceholder })
        #expect(entries.allSatisfy { $0.value == "Not Reported" })
    }

    @Test func runDetailsJobIDRowPresence() {
        // Item 1 contract: the job's raw ULID leads the entries — never
        // omitted, never a "Not Reported" placeholder, and flagged monospaced
        // so the inspector renders the copyable id in a fixed-width font.
        let facts = QueueRunDetailsFacts(jobID: "01J8ZQ4T7KWM3N5P6A9B2C4D5E")
        let entries = facts.entries
        // Job ID leads; the provider/model placeholders follow (their absence
        // matters, so they always render).
        #expect(entries.map(\.label) == ["Job ID", "Provider", "Model"])
        #expect(entries.first?.value == "01J8ZQ4T7KWM3N5P6A9B2C4D5E")
        #expect(entries.first?.isPlaceholder == false)
        #expect(entries.first?.isMonospaced == true)
    }

    @Test func runDetailsFullFactsOrderAndValues() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let facts = QueueRunDetailsFacts(
            jobID: "01J8ZQ4T7KWM3N5P6A9B2C4D5E",
            enqueuedAt: start,
            startedAt: start,
            finishedAt: start.addingTimeInterval(90),
            durationText: QueueWorkspaceFormat.duration(from: start, to: start.addingTimeInterval(90)),
            attempt: 2,
            providerText: "claude-code",
            modelText: "claude-sonnet-4",
            usage: SessionUsage(
                inputTokens: 4_178, outputTokens: 537, totalTokens: 4_715,
                cachedReadTokens: 133_376, thoughtTokens: 395,
                cost: 0.0421, currency: "USD", contextUsed: 0, contextSize: 0))
        let entries = facts.entries
        // The job id leads; every other fact follows in plan order. Usage is
        // ONE labeled row per present field after Model (operator request:
        // the single-line "In … · Out … tokens · … cached · … thought" form
        // is rejected), closing with Cost.
        #expect(entries.map(\.label) == [
            "Job ID", "Enqueued", "Started", "Finished", "Duration", "Attempt",
            "Provider", "Model", "Input", "Output", "Cached", "Thought", "Cost",
        ])
        #expect(entries.containsNoPlaceholders())
        #expect(entries.first?.isMonospaced == true)
        #expect(entries.dropFirst().allSatisfy { $0.isMonospaced == false })
        #expect(entries.first { $0.label == "Attempt" }?.value == "2")
        #expect(entries.first { $0.label == "Duration" }?.value == "1m 30s")
        // Usage values are locale-grouped exact counts; the label carries the
        // meaning (no "In"/"Out" prefixes, no "tokens" suffix). Cost keeps
        // sub-cent precision via preciseCost.
        #expect(entries.first { $0.label == "Input" }?.value == UsageFormatter.groupedCount(4_178))
        #expect(entries.first { $0.label == "Output" }?.value == UsageFormatter.groupedCount(537))
        #expect(entries.first { $0.label == "Cached" }?.value == UsageFormatter.groupedCount(133_376))
        #expect(entries.first { $0.label == "Thought" }?.value == UsageFormatter.groupedCount(395))
        #expect(entries.first { $0.label == "Cost" }?.value == "$0.0421")
    }

    @Test func runDetailsUsageRowsOmitZeroAndAbsentFields() {
        // Zero/absent usage fields render NO row — never a fake zero. A
        // cost-only snapshot is a single Cost row; a zero thought counter
        // (present but 0) is treated as absent.
        let costOnly = QueueRunDetailsFacts(usage: SessionUsage(
            inputTokens: 0, outputTokens: 0, totalTokens: 0,
            cachedReadTokens: nil, thoughtTokens: 0,
            cost: 0.0421, currency: "USD", contextUsed: 0, contextSize: 0))
        #expect(costOnly.entries.map(\.label) == ["Provider", "Model", "Cost"])

        let inputOnly = QueueRunDetailsFacts(usage: SessionUsage(
            inputTokens: 8_120, outputTokens: 0, totalTokens: 8_120,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0))
        #expect(inputOnly.entries.map(\.label) == ["Provider", "Model", "Input"])
        #expect(inputOnly.entries.last?.value == UsageFormatter.groupedCount(8_120))
    }

    @Test func runDetailsNoUsageProducesNoUsageRows() {
        // No usage snapshot at all → no usage rows (not zeros, not a
        // placeholder row).
        let facts = QueueRunDetailsFacts(jobID: "01J8ZQ4T7KWM3N5P6A9B2C4D5E")
        #expect(facts.entries.map(\.label) == ["Job ID", "Provider", "Model"])
        // A snapshot with nothing reportable is the same as no snapshot.
        let empty = QueueRunDetailsFacts(usage: SessionUsage(
            inputTokens: 0, outputTokens: 0, totalTokens: 0,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0))
        #expect(empty.entries.map(\.label) == ["Provider", "Model"])
    }

    // MARK: - Run details provider/model mid-run fallback

    @Test func runDetailsProviderModelReportHeaderWins() {
        // Report header values always win when present — even against a
        // live usage snapshot carrying its own labels.
        let resolved = ActivityWindowView.runDetailsProviderModel(
            reportProvider: "claude-code",
            reportModel: "claude-sonnet-4",
            usage: SessionUsage(
                inputTokens: 100, outputTokens: 50, totalTokens: 150,
                cachedReadTokens: nil, thoughtTokens: nil,
                cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
                providerLabel: "Live Provider", modelId: "live-model",
                modelName: "Live Model"))
        #expect(resolved.provider == "claude-code")
        #expect(resolved.model == "claude-sonnet-4")
    }

    @Test func runDetailsProviderModelFallsBackToLiveUsageMidRun() {
        // A running job: the report header has no provider/model yet, so the
        // recorded-or-live usage snapshot stands in — the live session's own
        // labels, never invented. The human-readable model name wins over
        // the raw id (the `fullSummary` vocabulary).
        let resolved = ActivityWindowView.runDetailsProviderModel(
            reportProvider: nil,
            reportModel: nil,
            usage: SessionUsage(
                inputTokens: 100, outputTokens: 50, totalTokens: 150,
                cachedReadTokens: nil, thoughtTokens: nil,
                cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
                providerLabel: "Claude", modelId: "sonnet-4-5",
                modelName: "Claude Sonnet 4.5"))
        #expect(resolved.provider == "Claude")
        #expect(resolved.model == "Claude Sonnet 4.5")

        // Without an advertised model name, the raw model id shows.
        let idOnly = ActivityWindowView.runDetailsProviderModel(
            reportProvider: nil,
            reportModel: nil,
            usage: SessionUsage(
                inputTokens: 100, outputTokens: 50, totalTokens: 150,
                cachedReadTokens: nil, thoughtTokens: nil,
                cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
                providerLabel: "Claude", modelId: "sonnet-4-5"))
        #expect(idOnly.provider == "Claude")
        #expect(idOnly.model == "sonnet-4-5")
    }

    @Test func runDetailsProviderModelMixedPresenceAndBlanks() {
        // Each side resolves independently: a report model with an absent
        // report provider still falls back for the provider only.
        let usage = SessionUsage(
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0,
            providerLabel: "Live Provider", modelId: "live-model")
        let mixed = ActivityWindowView.runDetailsProviderModel(
            reportProvider: nil, reportModel: "reported-model", usage: usage)
        #expect(mixed.provider == "Live Provider")
        #expect(mixed.model == "reported-model")

        // Blank report text counts as absent (same rule as `entries`), so
        // the usage fallback fills in rather than rendering "Not Reported".
        let blank = ActivityWindowView.runDetailsProviderModel(
            reportProvider: "  ", reportModel: "", usage: usage)
        #expect(blank.provider == "Live Provider")
        #expect(blank.model == "live-model")

        // Nothing anywhere → both nil; `entries` renders the "Not Reported"
        // placeholders as before.
        let nothing = ActivityWindowView.runDetailsProviderModel(
            reportProvider: nil, reportModel: nil, usage: nil)
        #expect(nothing.provider == nil)
        #expect(nothing.model == nil)
    }

    // MARK: - Run details retry usage precedence

    @Test func runDetailsRunningItemPrefersLiveUsageOverStaleRecorded() {
        // After Retry Job the item keeps its id while the previous attempt's
        // recorded `.usage` snapshot survives `.started` (the tracker clears
        // `liveUsage` at terminal state, never `itemUsage`). While the item
        // runs, the panel must show the FRESH live snapshot — not the prior
        // attempt's frozen totals next to a running clock. The report header
        // carries no usage while a run is in flight (it is written at
        // completion), so the tracker is the mid-run source.
        let staleRecorded = SessionUsage(
            inputTokens: 4_178, outputTokens: 537, totalTokens: 4_715,
            cachedReadTokens: 133_376, thoughtTokens: 395,
            cost: 0.0421, currency: "USD", contextUsed: 0, contextSize: 0)
        let freshLive = SessionUsage(
            inputTokens: 210, outputTokens: 33, totalTokens: 243,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: 0.0021, currency: "USD", contextUsed: 0, contextSize: 0,
            providerLabel: "Claude", modelId: "sonnet-4-5",
            modelName: "Claude Sonnet 4.5")
        let resolved = ActivityWindowView.runDetailsUsage(
            itemState: .running, report: nil,
            recorded: staleRecorded, live: freshLive)
        #expect(resolved == freshLive)

        // The panel built from that resolution reflects the live numbers.
        let panel = QueueRunDetailsFacts(
            jobID: "01J8ZQ4T7KWM3N5P6A9B2C4D5E", usage: resolved)
        #expect(panel.entries.first { $0.label == "Input" }?.value
                == UsageFormatter.groupedCount(210))
        #expect(panel.entries.first { $0.label == "Output" }?.value
                == UsageFormatter.groupedCount(33))

        // A running item with no live snapshot yet (before the first
        // usage_update) falls back to the recorded snapshot rather than
        // showing nothing.
        #expect(ActivityWindowView.runDetailsUsage(
            itemState: .running, report: nil,
            recorded: staleRecorded, live: nil)
                == staleRecorded)
    }

    @Test func runDetailsTerminalItemKeepsRecordedUsage() {
        // Terminal states show the durable report-header usage when it
        // exists (design change 11); otherwise the tracker's recorded
        // snapshot — the pre-usage fallback. The live snapshot is cleared at
        // the terminal transition — and even a lingering live value must not
        // override the durable/recorded one. Queued (never started) behaves
        // the same: nothing live to show.
        let recorded = SessionUsage(
            inputTokens: 4_178, outputTokens: 537, totalTokens: 4_715,
            cachedReadTokens: 133_376, thoughtTokens: 395,
            cost: 0.0421, currency: "USD", contextUsed: 0, contextSize: 0)
        let lingeringLive = SessionUsage(
            inputTokens: 1, outputTokens: 1, totalTokens: 2,
            cachedReadTokens: nil, thoughtTokens: nil,
            cost: nil, currency: nil, contextUsed: 0, contextSize: 0)
        let reportUsage = QueueReportUsage(
            inputTokens: 4_178, outputTokens: 537,
            cachedReadTokens: 133_376, thoughtTokens: 395,
            cost: 0.0421, currency: "USD")
        for state in [QueueItemState.completed, .failed, .cancelled, .queued] {
            // Durable report-header usage wins over the tracker snapshot
            // (which may be stale — the report holds the completion truth).
            #expect(ActivityWindowView.runDetailsUsage(
                itemState: state, report: reportUsage,
                recorded: recorded, live: lingeringLive)
                    == SessionUsage(reportUsage: reportUsage))
            // Legacy/pre-completion reports (NULL usage columns) fall back
            // to the tracker's recorded snapshot.
            #expect(ActivityWindowView.runDetailsUsage(
                itemState: state, report: nil,
                recorded: recorded, live: lingeringLive)
                    == recorded)
            // Absence stays absence — a terminal item never fabricates
            // usage rows out of a live snapshot.
            #expect(ActivityWindowView.runDetailsUsage(
                itemState: state, report: nil,
                recorded: nil, live: lingeringLive) == nil)
        }
        // A legacy report with NULL usage columns renders NO usage rows when
        // the tracker has nothing either — never zeros.
        let legacyPanel = QueueRunDetailsFacts(jobID: "01J8ZQ4T7KWM3N5P6A9B2C4D5E")
        #expect(legacyPanel.entries.allSatisfy {
            !["Input", "Output", "Cached", "Thought", "Cost"].contains($0.label)
        })
    }

    // MARK: - Overview result statement (design change 10)

    /// Minimal report fixture: only the availability + producer summary vary.
    private func report(
        availability: QueueReportAvailability,
        resultSummary: String?
    ) -> QueueAttemptReport {
        QueueAttemptReport(
            attemptID: QueueAttemptID(
                itemID: QueueItemID(rawValue: "01J8ZQ4T7KWM3N5P6A9B2C4D5E"),
                attempt: 0),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: 1),
            operation: .lint,
            scope: .wholeWiki,
            phase: .finished,
            provider: nil,
            model: nil,
            availability: availability,
            resultSummary: resultSummary,
            targets: [])
    }

    @Test func resultStatementRendersProducerSummariesAndHonestFailureOnly() {
        // .available: the producer's recorded summary passes through.
        #expect(ActivityWindowView.resultStatement(for: report(
            availability: .available,
            resultSummary: "3 submitted")) == "3 submitted")

        // .notReported renders NO statement line — the operator decision
        // (2026-09-10): "the run completed; per-source outcomes are not
        // reported" only restates what the inventory rows already show, so
        // the line communicated nothing and read as a result. Even a
        // producer-supplied not-reported summary does not render.
        #expect(ActivityWindowView.resultStatement(for: report(
            availability: .notReported,
            resultSummary: nil)) == nil)
        #expect(ActivityWindowView.resultStatement(for: report(
            availability: .notReported,
            resultSummary: "Agent run completed; page-level results not reported")) == nil)

        // .reportingUnavailable keeps the honest failure: uncommitted
        // outcomes are never presented as durable.
        #expect(ActivityWindowView.resultStatement(for: report(
            availability: .reportingUnavailable,
            resultSummary: nil))?
            .contains("Reporting unavailable") == true)
    }

    // MARK: - Header job identity

    @Test func headerCarriesStronglyTypedQueueItemID() {
        let jobID = QueueItemID(rawValue: "01M24JCFZF2G8JM12QHTZAX0PQ")
        let header = QueueJobHeaderPresentation(
            title: "1 source",
            operationLabel: "Ingest",
            jobID: jobID,
            lifecycle: .completed)

        // The presentation preserves the queue-item namespace. Raw text is
        // produced only at the rendering or pasteboard boundary.
        #expect(header.jobID == jobID)
        #expect(header.jobID.rawValue == "01M24JCFZF2G8JM12QHTZAX0PQ")

        // Sidebar metadata uses the same typed queue identity, followed by its
        // timing suffix. It must not substitute the containing wiki ID.
        #expect(ActivityWindowView.rowMetadataText(
            jobID: jobID,
            suffix: "3 hours ago") == "01M24JCFZF2G8JM12QHTZAX0PQ · 3 hours ago")
        #expect(ActivityWindowView.rowMetadataText(jobID: jobID, suffix: nil)
                == "01M24JCFZF2G8JM12QHTZAX0PQ")
    }

    @Test func runDetailsFirstAttemptAndBlankTextOmitted() {
        let facts = QueueRunDetailsFacts(
            enqueuedAt: Date(timeIntervalSince1970: 0),
            attempt: 0,           // first run: no "Attempt" row
            providerText: "  ",   // blank text is absence, not a provider
            modelText: nil)
        let labels = facts.entries.map(\.label)
        #expect(!labels.contains("Attempt"))
        let provider = facts.entries.first { $0.label == "Provider" }
        #expect(provider?.isPlaceholder == true)
    }

    @Test func runDetailsDurationRowOmittedWithoutBounds() {
        let facts = QueueRunDetailsFacts(startedAt: Date(timeIntervalSince1970: 0))
        #expect(facts.entries.first { $0.label == "Duration" } == nil)
    }

    // MARK: - Formatting

    @Test func elapsedClockBoundaries() {
        let start = Date(timeIntervalSince1970: 10_000)
        #expect(QueueWorkspaceFormat.elapsed(from: nil, to: start) == "—")
        #expect(QueueWorkspaceFormat.elapsed(from: start, to: start.addingTimeInterval(42)) == "42s")
        #expect(QueueWorkspaceFormat.elapsed(from: start, to: start.addingTimeInterval(60)) == "1m")
        #expect(QueueWorkspaceFormat.elapsed(from: start, to: start.addingTimeInterval(192)) == "3m 12s")
        #expect(QueueWorkspaceFormat.elapsed(from: start, to: start.addingTimeInterval(3_600)) == "1h")
        #expect(QueueWorkspaceFormat.elapsed(from: start, to: start.addingTimeInterval(3_900)) == "1h 5m")
        // Clock skew (now before start) clamps to zero rather than negating.
        #expect(QueueWorkspaceFormat.elapsed(from: start, to: start.addingTimeInterval(-5)) == "0s")
    }

    @Test func durationFormatting() {
        let start = Date(timeIntervalSince1970: 10_000)
        #expect(QueueWorkspaceFormat.duration(from: start, to: start.addingTimeInterval(90)) == "1m 30s")
        #expect(QueueWorkspaceFormat.duration(from: start, to: nil) == nil)
        #expect(QueueWorkspaceFormat.duration(from: nil, to: start) == nil)
        #expect(QueueWorkspaceFormat.duration(from: nil, to: nil) == nil)
    }

    @Test func timestampIsNonEmpty() {
        #expect(!QueueWorkspaceFormat.timestamp(Date(timeIntervalSince1970: 0)).isEmpty)
    }

    // MARK: - Metrics (layout contract pins)

    @Test func workspaceMetricsContractValues() {
        // Navigator column bounds from the plan's layout contract.
        #expect(QueueWorkspaceMetrics.Navigator.minWidth == 220)
        #expect(QueueWorkspaceMetrics.Navigator.idealWidth == 280)
        #expect(QueueWorkspaceMetrics.Navigator.maxWidth == 360)
        // Existing usability minimum and preferred new-window size.
        #expect(QueueWorkspaceMetrics.Window.minWidth == 640)
        #expect(QueueWorkspaceMetrics.Window.minHeight == 400)
        #expect(QueueWorkspaceMetrics.Window.preferredWidth == 1040)
        #expect(QueueWorkspaceMetrics.Window.preferredHeight == 720)
        // The restrained spacing scale.
        #expect(QueueWorkspaceMetrics.Spacing.xs == 8)
        #expect(QueueWorkspaceMetrics.Spacing.sm == 12)
        #expect(QueueWorkspaceMetrics.Spacing.md == 16)
        #expect(QueueWorkspaceMetrics.Spacing.lg == 24)
        // Local inventory search appears for large batches only.
        #expect(QueueWorkspaceMetrics.Inventory.localSearchThreshold == 12)
        // Toolbar job-search geometry (design change 6): threshold between
        // the window minimum and preferred widths; expanded field and
        // collapsed button at toolbar scale.
        #expect(QueueWorkspaceMetrics.Search.expandedThreshold == 800)
        #expect(QueueWorkspaceMetrics.Search.expandedFieldWidth == 220)
        // The standard toolbar icon-button square, shared by the collapsed
        // search button and the Run Details toggle (both render at the main
        // window's standard toolbar Button metrics).
        #expect(QueueWorkspaceMetrics.Toolbar.iconButtonSide == 28)
        #expect(QueueWorkspaceMetrics.Search.collapsedButtonSide
                == QueueWorkspaceMetrics.Toolbar.iconButtonSide)
    }

    // MARK: - Toolbar search form (design change 6, 2026-09-09)

    /// The search prompt + accessibility label carried over from the former
    /// `.searchable` field unchanged — both forms of the control announce
    /// themselves identically.
    @Test func toolbarSearchPromptIsPinned() {
        #expect(ActivityWindowView.searchPrompt == "Search loaded jobs")
    }

    @Test func toolbarSearchExpandsAtOrAboveThresholdWidth() {
        // Wide empty window: expanded field.
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: QueueWorkspaceMetrics.Window.preferredWidth,
                queryIsEmpty: true,
                userRequestedExpansion: false) == .expandedField)
        // Exactly at the threshold: expanded (>= is the expanded side).
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: QueueWorkspaceMetrics.Search.expandedThreshold,
                queryIsEmpty: true,
                userRequestedExpansion: false) == .expandedField)
    }

    @Test func toolbarSearchCollapsesBelowThresholdWidth() {
        // Narrow empty window: collapsed button.
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: QueueWorkspaceMetrics.Window.minWidth,
                queryIsEmpty: true,
                userRequestedExpansion: false) == .collapsedButton)
        // Just under the threshold: still collapsed.
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: QueueWorkspaceMetrics.Search.expandedThreshold - 1,
                queryIsEmpty: true,
                userRequestedExpansion: false) == .collapsedButton)
    }

    @Test func toolbarSearchStaysExpandedWhileQueryIsActive() {
        // A non-empty query keeps the field visible at any width — collapsing
        // would hide the text being edited and the filter it drives.
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: QueueWorkspaceMetrics.Window.minWidth,
                queryIsEmpty: false,
                userRequestedExpansion: false) == .expandedField)
    }

    @Test func toolbarSearchClickRequestExpandsUntilQueryClears() {
        // The magnifying-glass click wins over a sub-threshold width...
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: QueueWorkspaceMetrics.Window.minWidth,
                queryIsEmpty: true,
                userRequestedExpansion: true) == .expandedField)
        // ...and the request is spent once the query empties again, so a
        // narrow window collapses back to the button.
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: QueueWorkspaceMetrics.Window.minWidth,
                queryIsEmpty: true,
                userRequestedExpansion: false) == .collapsedButton)
    }

    @Test func toolbarSearchUnmeasuredWidthAssumesExpanded() {
        // Before the first layout measurement the control reads like the
        // previous always-present search field.
        #expect(
            QueueSearchToolbarForm.decision(
                splitViewWidth: nil,
                queryIsEmpty: true,
                userRequestedExpansion: false) == .expandedField)
    }
}

/// Minimal mutable box so a test can observe that a row action's closure
/// actually fires (closure wiring is the integration surface).
private final class ActionCounter {
    var count = 0
}

private extension [QueueRunDetailEntry] {
    /// No entry is a placeholder — for the full-facts fixture where every
    /// value is known and reported.
    func containsNoPlaceholders() -> Bool {
        allSatisfy { !$0.isPlaceholder }
    }
}
#endif
