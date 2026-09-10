#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSEngine
@testable import WikiFS

/// Tests for the queue workspace integration slice: the pure mapper
/// (`QueueWorkspaceMapper`), the tracker's report-summary cache, and the view
/// model's stale-selection guard for selected-report loads.
///
/// Pure-mapper tests run anywhere; the cache/view-model suites are
/// `@MainActor` (the tracker and view model are) and serialized with a time
/// limit because they exercise real continuation/sleep-based coordination.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct QueueWorkspaceIntegrationTests {

    // MARK: - Fixtures

    private func makeItem(
        id: String,
        queue: QueueKind,
        state: QueueItemState = .running,
        sourceIDs: [String] = [],
        lintPageIDs: [PageID]? = nil,
        attempt: Int = 0
    ) -> QueueItem {
        QueueItem(
            id: QueueItemID(rawValue: id), queue: queue,
            wikiID: WikiID(rawValue: "wiki1"),
            payload: QueueItemPayload(
                sourceIDs: sourceIDs.map { SourceID(rawValue: $0) },
                lintPageIDs: lintPageIDs),
            state: state, orderingKey: 1000, attempt: attempt, createdAt: 0)
    }

    private func makeReport(
        itemID: String,
        attempt: Int = 0,
        revision: Int = 1,
        operation: QueueReportOperation = .ingest,
        scope: QueueReportScope? = nil,
        phase: QueueReportPhase = .staging,
        availability: QueueReportAvailability = .available,
        targets: [QueueReportTargetRecord] = [],
        resultSummary: String? = nil
    ) -> QueueAttemptReport {
        let resolvedScope = scope
            ?? .targets(targets.isEmpty
                ? [
                    QueueReportTargetRecord(
                        target: .source(SourceID(rawValue: "s1")),
                        displayName: "A.pdf", state: .planned)
                ]
                : targets)
        let resolvedTargets: [QueueReportTargetRecord]
        if case .targets(let records) = resolvedScope {
            resolvedTargets = records
        } else {
            resolvedTargets = targets
        }
        return QueueAttemptReport(
            attemptID: QueueAttemptID(
                itemID: QueueItemID(rawValue: itemID), attempt: attempt),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: revision),
            operation: operation,
            scope: resolvedScope,
            phase: phase,
            provider: nil,
            model: nil,
            availability: availability,
            resultSummary: resultSummary,
            targets: resolvedTargets)
    }

    private func makeSummary(
        itemID: String,
        revision: Int,
        attempt: Int = 0,
        phase: QueueReportPhase = .staging,
        availability: QueueReportAvailability = .available,
        phaseCounts: [QueueReportTargetCountKey: Int] = [.planned: 4, .submitted: 8]
    ) -> QueueReportSummary {
        QueueReportSummary(
            itemID: QueueItemID(rawValue: itemID),
            attempt: attempt,
            revision: QueueReportRevision(rawValue: revision),
            phase: phase,
            availability: availability,
            phaseCounts: phaseCounts,
            resultSummary: nil,
            searchText: "recorded names here")
    }

    // MARK: - Mapper: lifecycle + operation

    @Test func lifecycleMapsOneToOneFromItemState() {
        #expect(QueueWorkspaceMapper.lifecycle(for: .queued) == .queued)
        #expect(QueueWorkspaceMapper.lifecycle(for: .running) == .running)
        #expect(QueueWorkspaceMapper.lifecycle(for: .completed) == .completed)
        #expect(QueueWorkspaceMapper.lifecycle(for: .failed) == .failed)
        #expect(QueueWorkspaceMapper.lifecycle(for: .cancelled) == .cancelled)
    }

    @Test func operationLanguageFollowsPayloadAndQueue() {
        // Lint wins over queue kind (payload decides), ingestion says Ingest,
        // extraction/transcription say Extract.
        #expect(QueueWorkspaceMapper.operationLabel(for: makeItem(id: "i", queue: .ingestion)) == "Ingest")
        #expect(QueueWorkspaceMapper.operationLabel(for: makeItem(id: "e", queue: .extraction)) == "Extract")
        #expect(QueueWorkspaceMapper.operationLabel(for: makeItem(id: "t", queue: .transcription)) == "Extract")
        let lint = makeItem(id: "l", queue: .ingestion, lintPageIDs: [])
        #expect(QueueWorkspaceMapper.operationLabel(for: lint) == "Lint")

        #expect(QueueWorkspaceMapper.reportOperation(for: lint) == .lint)
        #expect(QueueWorkspaceMapper.reportOperation(for: makeItem(id: "i2", queue: .ingestion)) == .ingest)
        #expect(QueueWorkspaceMapper.reportOperation(for: makeItem(id: "e2", queue: .extraction)) == .extract)
    }

    @Test func navigatorAndHeaderShareJobTitles() {
        // Navigator rows and selected-job headers use one formatter. Titles
        // contain operation/count context where needed, but never a resolved
        // target name or raw target ID. Whole-wiki lint keeps the wiki name.
        let rawPageID = PageID(rawValue: "01J9ZQPAGE4T8AWJ3XG8YQ0MEB")
        let lint = makeItem(id: "l", queue: .ingestion, lintPageIDs: [rawPageID])
        let lintMany = makeItem(id: "l3", queue: .ingestion, lintPageIDs: [
            PageID(rawValue: "p1"), PageID(rawValue: "p2"), PageID(rawValue: "p3")])
        let wholeWiki = makeItem(id: "lw", queue: .ingestion, lintPageIDs: [])
        let ingest = makeItem(id: "i", queue: .ingestion, sourceIDs: ["a", "b", "c"])
        let ingestOne = makeItem(id: "i1", queue: .ingestion, sourceIDs: ["a"])
        let extract = makeItem(id: "x", queue: .extraction, sourceIDs: ["a", "b"])

        #expect(ActivityWindowView.computeRowTitle(for: lint, wikiName: "Wiki") == "Lint 1 page")
        #expect(ActivityWindowView.computeRowTitle(for: lintMany, wikiName: "Wiki") == "Lint 3 pages")
        #expect(ActivityWindowView.computeRowTitle(for: wholeWiki, wikiName: "Wiki") == "Lint Wiki")
        #expect(ActivityWindowView.computeRowTitle(for: ingest, wikiName: "Wiki") == "Ingest 3 sources")
        #expect(ActivityWindowView.computeRowTitle(for: ingestOne, wikiName: "Wiki") == "1 source")
        #expect(ActivityWindowView.computeRowTitle(for: extract, wikiName: "Wiki") == "2 sources")

        // The selected-job header uses this exact same value. There is no
        // second formatter that can add a divergent operation prefix.
        for item in [lint, lintMany, wholeWiki, ingest, ingestOne, extract] {
            let sharedTitle = ActivityWindowView.computeRowTitle(for: item, wikiName: "Wiki")
            #expect(!sharedTitle.contains(rawPageID.rawValue),
                    "job title must not contain a raw target ID: '\(sharedTitle)'")
        }
        #expect(ActivityWindowView.computeRowTitle(for: ingestOne, wikiName: "Wiki") == "1 source")
    }

    @Test func windowScopeFilteringIsStrict() {
        // Extraction has its own window: an extraction job must never appear
        // in the Agent Queue list, and ingestion/lint never in the Extraction
        // Queue. The item's own queue kind is the single authority.
        let ingest = makeItem(id: "i", queue: .ingestion)
        let lint = makeItem(id: "l", queue: .ingestion, lintPageIDs: [])
        let extract = makeItem(id: "x", queue: .extraction)
        #expect(ActivityWindowView.windowContains(ingest, queue: .ingestion))
        #expect(ActivityWindowView.windowContains(lint, queue: .ingestion))
        #expect(!ActivityWindowView.windowContains(extract, queue: .ingestion))
        #expect(ActivityWindowView.windowContains(extract, queue: .extraction))
        #expect(!ActivityWindowView.windowContains(ingest, queue: .extraction))
        #expect(!ActivityWindowView.windowContains(lint, queue: .extraction))
    }

    // MARK: - Mapper: header progress truth rules

    @Test func headerProgressRequiresAvailableSummaryAndKnownTotal() {
        let item = makeItem(id: "x", queue: .ingestion, sourceIDs: ["a", "b"])
        // No summary yet → no progress region (lifecycle-only row).
        #expect(QueueWorkspaceMapper.headerProgress(
            from: nil, operation: .ingest, payloadTargetCount: 2,
            jobLifecycle: .running) == nil)
        // Unknown total (no recorded counts, empty payload): staging must not
        // render determinate "0 of 0" — it degrades to an indeterminate bar.
        let unknownTotal = QueueWorkspaceMapper.headerProgress(
            from: makeSummary(itemID: "x", revision: 1, phaseCounts: [:]),
            operation: .ingest, payloadTargetCount: 0, jobLifecycle: .running)
        if case .determinate = unknownTotal {
            Issue.record("Unknown total must never render determinate")
        }
        // Reporting unavailable → lifecycle-only presentation.
        #expect(QueueWorkspaceMapper.headerProgress(
            from: makeSummary(
                itemID: "x", revision: 1,
                availability: .reportingUnavailable, phaseCounts: [.submitted: 1, .planned: 1]),
            operation: .ingest, payloadTargetCount: 2, jobLifecycle: .running) == nil)
        _ = item // payload only used for shape above
    }

    @Test func headerProgressStagingCountsEverythingPastPlanned() {
        // Staging: "8 of 12 staged-or-beyond" = total − planned.
        let progress = QueueWorkspaceMapper.headerProgress(
            from: makeSummary(
                itemID: "s", revision: 1, phase: .staging,
                phaseCounts: [.planned: 4, .preparing: 1, .submitted: 7]),
            operation: .ingest, payloadTargetCount: 12, jobLifecycle: .running)
        #expect(progress == .determinate(phase: "Staging sources", completed: 8, total: 12))
    }

    @Test func headerProgressRunningUsesSubmissionLanguageForIngest() {
        // Ingestion counts submissions, never "ingested" (plan operation
        // language): handed = submitted + processing + observed outcomes.
        let progress = QueueWorkspaceMapper.headerProgress(
            from: makeSummary(
                itemID: "r", revision: 1, phase: .running,
                phaseCounts: [.submitted: 5, .processing: 1, .planned: 6]),
            operation: .ingest, payloadTargetCount: 12, jobLifecycle: .running)
        #expect(progress == .determinate(phase: "Submitted sources", completed: 6, total: 12))
    }

    @Test func headerProgressRunningCountsObservedOutcomesForExtract() {
        let progress = QueueWorkspaceMapper.headerProgress(
            from: makeSummary(
                itemID: "x", revision: 1, phase: .running,
                phaseCounts: [.succeeded: 2, .failed: 1, .processing: 1, .planned: 8]),
            operation: .extract, payloadTargetCount: 12, jobLifecycle: .running)
        #expect(progress == .determinate(phase: "Processing sources", completed: 4, total: 12))
    }

    @Test func headerProgressUnmeasurablePhasesAreIndeterminate() {
        for phase in [QueueReportPhase.launching, .merging, .persisting] {
            let progress = QueueWorkspaceMapper.headerProgress(
                from: makeSummary(
                    itemID: "i", revision: 1, phase: phase, phaseCounts: [:]),
                operation: .ingest, payloadTargetCount: 0, jobLifecycle: .running)
            guard case .indeterminate = progress else {
                Issue.record("\(phase) should render indeterminate, got \(String(describing: progress))")
                continue
            }
        }
        // Planned and finished record no header progress: a queued job has no
        // clock/counts yet and a finished job shows its static duration.
        #expect(QueueWorkspaceMapper.headerProgress(
            from: makeSummary(itemID: "p", revision: 1, phase: .planned),
            operation: .ingest, payloadTargetCount: 3, jobLifecycle: .running) == nil)
        #expect(QueueWorkspaceMapper.headerProgress(
            from: makeSummary(itemID: "f", revision: 1, phase: .finished),
            operation: .ingest, payloadTargetCount: 3, jobLifecycle: .running) == nil)
    }

    // MARK: - Mapper: live progress is lifecycle-gated (M1 regression)

    @Test func headerProgressRendersNothingForDeadJobsEvenWithOpenPhase() {
        // M1: convert/persist can throw after a `.staging`/`.running` report
        // commit, leaving the recorded phase open while the job itself failed
        // or was cancelled. A dead job must never render live-looking
        // progress from that previous phase — the header shows the static
        // duration clock instead.
        let staleRunningPhase = makeSummary(
            itemID: "dead", revision: 3, phase: .running,
            phaseCounts: [.submitted: 5, .planned: 7])
        let staleStagingPhase = makeSummary(
            itemID: "dead2", revision: 3, phase: .staging,
            phaseCounts: [.planned: 4, .preparing: 1, .submitted: 7])
        let deadLifecycles: [QueueWorkspaceJobLifecycle] = [
            .queued, .completed, .failed, .cancelled
        ]
        for lifecycle in deadLifecycles {
            #expect(
                QueueWorkspaceMapper.headerProgress(
                    from: staleRunningPhase,
                    operation: .ingest,
                    payloadTargetCount: 12,
                    jobLifecycle: lifecycle) == nil,
                "\(lifecycle) must not render progress from an open phase")
            #expect(
                QueueWorkspaceMapper.headerProgress(
                    from: staleStagingPhase,
                    operation: .ingest,
                    payloadTargetCount: 12,
                    jobLifecycle: lifecycle) == nil,
                "\(lifecycle) must not render progress from an open phase")
        }
        // The same open-phase summary DOES drive progress while the job runs.
        #expect(QueueWorkspaceMapper.headerProgress(
            from: staleRunningPhase,
            operation: .ingest,
            payloadTargetCount: 12,
            jobLifecycle: .running) != nil)
    }

    // MARK: - Mapper: target status vocabulary

    @Test func targetStatusNeverProjectsInterruptedAsFailedOrSucceeded() {
        // Report truth rule 10: unfinished targets are interrupted.
        let interrupted = QueueWorkspaceMapper.targetStatus(for: .interrupted, result: nil)
        #expect(interrupted?.text == "Interrupted")
        #expect(interrupted?.style != .failure)

        let failed = QueueWorkspaceMapper.targetStatus(
            for: .failed(reason: "convert failed"), result: nil)
        #expect(failed?.text == "Failed")
        #expect(failed?.style == .failure)

        let succeeded = QueueWorkspaceMapper.targetStatus(for: .succeeded, result: nil)
        #expect(succeeded?.text == "Succeeded")

        // Operator decision (2026-09-09): evidence-less targets (.planned,
        // .notReported) map to NO status — the inventory row renders
        // name-only, never a zero or an empty success (supersedes the
        // 2026-09-08 "render as Planned" presentation).
        #expect(QueueWorkspaceMapper.targetStatus(for: .planned, result: nil) == nil)
        #expect(QueueWorkspaceMapper.targetStatus(for: .notReported, result: nil) == nil)
    }

    @Test func targetReasonPrefersRecordedReasonOverDetail() {
        var record = QueueReportTargetRecord(
            target: .source(SourceID(rawValue: "s")),
            displayName: "A.pdf",
            state: .skipped(reason: "Source bytes unavailable"),
            detail: "detail text")
        #expect(QueueWorkspaceMapper.targetReason(for: record) == "Source bytes unavailable")

        record.state = .planned
        #expect(QueueWorkspaceMapper.targetReason(for: record) == "detail text")

        record.detail = nil
        #expect(QueueWorkspaceMapper.targetReason(for: record) == nil)
    }

    // MARK: - Mapper: summary synthesis from a full report

    @Test func summarySynthesisFoldsNamesReasonsAndResult() {
        let report = makeReport(
            itemID: "syn",
            targets: [
                QueueReportTargetRecord(
                    target: .source(SourceID(rawValue: "s1")),
                    displayName: "A.pdf", state: .succeeded),
                QueueReportTargetRecord(
                    target: .source(SourceID(rawValue: "s2")),
                    displayName: "B.pdf", state: .skipped(reason: "bytes unavailable")),
            ],
            resultSummary: "12 submitted")
        let summary = QueueWorkspaceMapper.summary(from: report)
        #expect(summary.itemID == QueueItemID(rawValue: "syn"))
        #expect(summary.revision == QueueReportRevision(rawValue: 1))
        #expect(summary.phaseCounts[.succeeded] == 1)
        #expect(summary.phaseCounts[.skipped] == 1)
        #expect(summary.searchText.contains("A.pdf"))
        #expect(summary.searchText.contains("B.pdf"))
        #expect(summary.searchText.contains("bytes unavailable"))
        #expect(summary.searchText.contains("12 submitted"))
    }

    @Test func summarySynthesisBoundsSearchText() {
        let names = (0..<200).map { index in
            QueueReportTargetRecord(
                target: .source(SourceID(rawValue: "s\(index)")),
                displayName: "target-\(index)", state: .planned)
        }
        let summary = QueueWorkspaceMapper.summary(
            from: makeReport(itemID: "big", targets: names))
        #expect(summary.searchText.count <= QueueReportSummaryLimits.maxTotalLength)
        // Bounded folding: targets past the fold limit are absent.
        #expect(!summary.searchText.contains("target-199"))
    }

    @Test func summarySynthesisMatchesStoreFieldBounds() {
        // L2 regression: the event-synthesized summary must fold search text
        // with the SAME bounds the store's `loadReportSummaries` uses —
        // `maxSearchTargets` target RECORDS (not `maxSearchTargets` fields),
        // each field capped at `maxFieldLength` — so the navigator finds the
        // same text whether a summary came from the store or from an event.
        let foldIndex = QueueReportSummaryLimits.maxSearchTargets - 1
        // One record PAST the fold limit, to prove the bound below.
        let threeFieldTargets = (0...foldIndex + 1).map { index in
            QueueReportTargetRecord(
                target: .source(SourceID(rawValue: "s\(index)")),
                displayName: "name-\(index)",
                state: .skipped(reason: "reason-\(index)"),
                detail: "detail-\(index)")
        }
        let summary = QueueWorkspaceMapper.summary(
            from: makeReport(itemID: "parity", targets: threeFieldTargets))
        // All 64 target records fold. The old event path stopped at 64 FIELDS
        // (~21 three-field targets), so late targets were unfindable from
        // event-synthesized summaries even though store-loaded ones had them.
        #expect(summary.searchText.contains("name-\(foldIndex)"))
        #expect(summary.searchText.contains("reason-\(foldIndex)"))
        #expect(summary.searchText.contains("detail-\(foldIndex)"))
        // The record past the fold limit stays out.
        #expect(!summary.searchText.contains("name-\(foldIndex + 1)"))
        #expect(!summary.searchText.contains("detail-\(foldIndex + 1)"))

        // Per-field cap: a 5000-character reason contributes at most
        // maxFieldLength characters, like the store's `folded(_:)`.
        let huge = String(repeating: "z", count: 5_000)
        let capped = QueueWorkspaceMapper.summary(
            from: makeReport(itemID: "cap", targets: [
                QueueReportTargetRecord(
                    target: .source(SourceID(rawValue: "s0")),
                    displayName: "A.pdf",
                    state: .failed(reason: huge),
                    detail: nil)
            ]))
        let zCount = capped.searchText.filter { $0 == "z" }.count
        #expect(zCount == QueueReportSummaryLimits.maxFieldLength)

        // The total cap still bounds the joined text.
        let many = (0..<QueueReportSummaryLimits.maxSearchTargets).map { index in
            QueueReportTargetRecord(
                target: .source(SourceID(rawValue: "m\(index)")),
                displayName: String(repeating: "n\(index) ", count: 50),
                state: .planned)
        }
        let total = QueueWorkspaceMapper.summary(
            from: makeReport(itemID: "total", targets: many))
        #expect(total.searchText.count <= QueueReportSummaryLimits.maxTotalLength)
    }

    // MARK: - Target name index (M2)

    @Test func nameIndexMatchesLinearScanSemantics() {
        // M2 regression: the index must answer exactly what the pre-index
        // linear scans answered — first match wins on duplicate IDs, missing
        // IDs resolve nil. The navigator's titles and the inventory's action
        // availability both depend on this parity.
        var index = QueueTargetNameIndex()
        let sourceRows: [(SourceID, String)] = [
            (SourceID(rawValue: "s1"), "first.pdf"),
            (SourceID(rawValue: "s2"), "only.pdf"),
            (SourceID(rawValue: "s1"), "second.pdf"), // duplicate — must NOT win
        ]
        for (id, name) in sourceRows { index.recordSource(id, name: name) }
        let pageRows: [(PageID, String)] = [
            (PageID(rawValue: "p1"), "First Title"),
            (PageID(rawValue: "p2"), "Second Title"),
            (PageID(rawValue: "p1"), "Duplicate Title"), // duplicate — must NOT win
        ]
        for (id, title) in pageRows { index.recordPage(id, title: title) }

        // Oracle: the old linear scans over the same row order.
        func scanSource(_ id: SourceID) -> String? {
            sourceRows.first { $0.0 == id }?.1
        }
        func scanPage(_ id: PageID) -> String? {
            pageRows.first { $0.0 == id }?.1
        }
        #expect(index.sourceName(SourceID(rawValue: "s1")) == scanSource(SourceID(rawValue: "s1")))
        #expect(index.sourceName(SourceID(rawValue: "s1")) == "first.pdf")
        #expect(index.sourceName(SourceID(rawValue: "s2")) == "only.pdf")
        #expect(index.sourceName(SourceID(rawValue: "s3")) == nil)
        #expect(index.pageTitle(PageID(rawValue: "p1")) == scanPage(PageID(rawValue: "p1")))
        #expect(index.pageTitle(PageID(rawValue: "p2")) == "Second Title")
        #expect(index.pageTitle(PageID(rawValue: "p3")) == nil)
    }

    @Test func displayNamesPreservePayloadOrderAndWholeWikiMarker() {
        // M2 regression at the item-resolution seam: payload order preserved,
        // unresolved IDs dropped, whole-wiki lint collapses to the marker —
        // identical to the replaced per-item compactMap scans.
        var index = QueueTargetNameIndex()
        index.recordSource(SourceID(rawValue: "s1"), name: "a.pdf")
        index.recordSource(SourceID(rawValue: "s2"), name: "b.pdf")
        index.recordPage(PageID(rawValue: "p1"), title: "One")
        index.recordPage(PageID(rawValue: "p2"), title: "Two")

        // Sources: payload order, missing dropped.
        let ingest = makeItem(id: "m2a", queue: .ingestion, sourceIDs: ["s2", "gone", "s1"])
        let resolved = index.displayNames(for: ingest)
        #expect(resolved.names == ["b.pdf", "a.pdf"])
        #expect(resolved.targets == resolved.names)

        // Lint pages: titles in payload order.
        let lint = makeItem(id: "m2b", queue: .ingestion, lintPageIDs: [
            PageID(rawValue: "p2"), PageID(rawValue: "p1")])
        #expect(index.displayNames(for: lint).names == ["Two", "One"])

        // Whole-wiki lint: the "Entire wiki" marker, never an enumeration.
        let wholeWiki = makeItem(id: "m2c", queue: .ingestion, lintPageIDs: [])
        let marker = index.displayNames(for: wholeWiki)
        #expect(marker.names == [])
        #expect(marker.targets == ["Entire wiki"])

        // No live session (empty index): nothing resolves, exactly like the
        // old `store?`-nil scans.
        let empty = QueueTargetNameIndex().displayNames(for: ingest)
        #expect(empty.names == [])
        #expect(empty.targets == [])
    }

    // MARK: - Sidebar progress line (precompute path)

    @Test func progressLineJoinsPhaseAndCounts() {
        let item = makeItem(id: "pl", queue: .ingestion, sourceIDs: ["a"])
        let line = ActivityWindowView.progressLine(
            summary: makeSummary(
                itemID: "pl", revision: 1, phase: .staging,
                phaseCounts: [.planned: 4, .submitted: 8]),
            item: item)
        #expect(line == "Staging sources · 8 of 12")

        // No summary → no line (lifecycle-only row).
        #expect(ActivityWindowView.progressLine(summary: nil, item: item) == nil)
    }

    @Test func progressLineGatesDeadJobsAtTheRowSeam() {
        // M1 regression at the sidebar seam: the row's precomputed progress
        // line routes through the same lifecycle-gated mapper, so a failed or
        // cancelled job with an open recorded phase renders no live-looking
        // "Staging sources · N of M" line under its title.
        let openPhase = makeSummary(
            itemID: "dead-row", revision: 2, phase: .staging,
            phaseCounts: [.planned: 1, .preparing: 1, .submitted: 1])
        let failedItem = makeItem(
            id: "dead-row", queue: .ingestion, state: .failed,
            sourceIDs: ["a", "b", "c"])
        #expect(ActivityWindowView.progressLine(summary: openPhase, item: failedItem) == nil)

        let cancelledItem = makeItem(
            id: "dead-row", queue: .ingestion, state: .cancelled,
            sourceIDs: ["a", "b", "c"])
        #expect(ActivityWindowView.progressLine(summary: openPhase, item: cancelledItem) == nil)

        // The same summary still produces the line while the job runs.
        let runningItem = makeItem(
            id: "dead-row", queue: .ingestion, state: .running,
            sourceIDs: ["a", "b", "c"])
        #expect(
            ActivityWindowView.progressLine(summary: openPhase, item: runningItem)
                == "Staging sources · 2 of 3")
    }

    // MARK: - Tracker: summary cache

    @MainActor
    @Test func summaryBatchLoadPopulatesCache() async {
        let engine = StubReportEngine()
        await engine.setSummariesResult(.loaded([
            QueueItemID(rawValue: "a"): makeSummary(itemID: "a", revision: 3),
        ]))
        let tracker = QueueActivityTracker()
        tracker.attach(engine: engine)

        await tracker.refreshReportSummaries(itemIDs: [
            QueueItemID(rawValue: "a"), QueueItemID(rawValue: "b"),
        ])

        // Loaded summary cached; item without a report settles loaded-empty
        // (a truthful "no report recorded", not a perpetual loading state).
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "a"))?
            .revision == QueueReportRevision(rawValue: 3))
        #expect(tracker.reportSummaryState(for: QueueItemID(rawValue: "a")) == .loaded)
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "b")) == nil)
        #expect(tracker.reportSummaryState(for: QueueItemID(rawValue: "b")) == .loaded)

        tracker.stop()
    }

    @MainActor
    @Test func summaryLoadFailureKeepsLifecycleRowsAndLabelsUnavailable() async {
        let engine = StubReportEngine()
        await engine.setSummariesResult(.unavailable(reason: "store locked"))
        let tracker = QueueActivityTracker()
        tracker.attach(engine: engine)

        await tracker.refreshReportSummaries(itemIDs: [QueueItemID(rawValue: "a")])

        // Lifecycle-only fallback: no summary, state unavailable, no banner —
        // the failure is only logged (plan §"How summaries load").
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "a")) == nil)
        #expect(tracker.reportSummaryState(for: QueueItemID(rawValue: "a")) == .unavailable)

        tracker.stop()
    }

    @MainActor
    @Test func summaryMergeIsMonotonicByRevision() {
        let tracker = QueueActivityTracker()
        let newer = makeSummary(itemID: "m", revision: 5)
        let older = makeSummary(itemID: "m", revision: 2)

        tracker.merge(summary: newer)
        tracker.merge(summary: older)  // delayed batch load must lose

        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "m"))?
            .revision == QueueReportRevision(rawValue: 5))
    }

    @MainActor
    @Test func summaryMergeComparesAttemptBeforeRevision() {
        // A retry creates a new attempt whose revisions restart at 1. The
        // merge must compare attempt identity first: revision alone would let
        // the previous attempt's high revision pin the cache and hide the
        // retry's report forever.
        let tracker = QueueActivityTracker()
        tracker.merge(summary: makeSummary(itemID: "retry", revision: 9, attempt: 0))
        tracker.merge(summary: makeSummary(itemID: "retry", revision: 1, attempt: 1))

        let merged = tracker.reportSummary(for: QueueItemID(rawValue: "retry"))
        #expect(merged?.attempt == 1)
        #expect(merged?.revision == QueueReportRevision(rawValue: 1))

        // A delayed load from the OLD attempt must not roll the retry back —
        // even with a much higher revision.
        tracker.merge(summary: makeSummary(itemID: "retry", revision: 12, attempt: 0))
        let afterStaleLoad = tracker.reportSummary(for: QueueItemID(rawValue: "retry"))
        #expect(afterStaleLoad?.attempt == 1)
        #expect(afterStaleLoad?.revision == QueueReportRevision(rawValue: 1))

        // Within one attempt the revision rule still holds.
        tracker.merge(summary: makeSummary(itemID: "retry", revision: 2, attempt: 1))
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "retry"))?
            .revision == QueueReportRevision(rawValue: 2))
        tracker.merge(summary: makeSummary(itemID: "retry", revision: 1, attempt: 1))
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "retry"))?
            .revision == QueueReportRevision(rawValue: 2))
    }

    @MainActor
    @Test func reportUpdatedEventSynthesizesAndMergesSummary() {
        let tracker = QueueActivityTracker()
        let report = makeReport(
            itemID: "ev",
            revision: 7,
            phase: .running,
            targets: [
                QueueReportTargetRecord(
                    target: .source(SourceID(rawValue: "s1")),
                    displayName: "Live.pdf", state: .submitted),
            ])

        tracker.handle(.reportUpdated(QueueItemID(rawValue: "ev"), report))

        let summary = tracker.reportSummary(for: QueueItemID(rawValue: "ev"))
        #expect(summary?.revision == QueueReportRevision(rawValue: 7))
        #expect(summary?.phaseCounts[.submitted] == 1)
        #expect(summary?.searchText.contains("Live.pdf") == true)
        #expect(tracker.reportSummaryState(for: QueueItemID(rawValue: "ev")) == .loaded)

        // An older-committed revision never rolls the cache back.
        tracker.handle(.reportUpdated(
            QueueItemID(rawValue: "ev"),
            makeReport(itemID: "ev", revision: 3, targets: [])))
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "ev"))?
            .revision == QueueReportRevision(rawValue: 7))
    }

    @MainActor
    @Test func reportUnavailableKeepsCommittedSummaryAndLabelsOnlyMissingItems() {
        let tracker = QueueActivityTracker()
        tracker.merge(summary: makeSummary(itemID: "keep", revision: 2))

        tracker.handle(.reportUnavailable(QueueItemID(rawValue: "keep"), reason: "store write failed"))
        tracker.handle(.reportUnavailable(QueueItemID(rawValue: "bare"), reason: "store write failed"))

        // Last committed summary survives; persistence failure never invents
        // or erases outcomes (report merge rules).
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "keep"))?
            .revision == QueueReportRevision(rawValue: 2))
        #expect(tracker.reportSummaryState(for: QueueItemID(rawValue: "keep")) == .loaded)
        #expect(tracker.reportSummaryState(for: QueueItemID(rawValue: "bare")) == .unavailable)
    }

    @MainActor
    @Test func pruneAndStopClearSummaryCache() {
        let tracker = QueueActivityTracker()
        tracker.merge(summary: makeSummary(itemID: "gone", revision: 1))
        tracker.pruneTranscripts(for: QueueItemID(rawValue: "gone"))
        #expect(tracker.reportSummaryState(for: QueueItemID(rawValue: "gone")) == .loading)

        tracker.merge(summary: makeSummary(itemID: "other", revision: 1))
        tracker.stop()
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "other")) == nil)
        #expect(tracker.reportSummaryStates.isEmpty)
    }

    @MainActor
    @Test func unforcedRefreshSkipsLoadedItemsButForcedRefreshRefetches() async {
        let engine = StubReportEngine()
        await engine.setSummariesResult(.loaded([
            QueueItemID(rawValue: "a"): makeSummary(itemID: "a", revision: 1),
        ]))
        let tracker = QueueActivityTracker()
        tracker.attach(engine: engine)
        let ids = [QueueItemID(rawValue: "a")]
        await tracker.refreshReportSummaries(itemIDs: ids)
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "a"))?
            .revision == QueueReportRevision(rawValue: 1))

        // The store moved on, but an unforced refresh must not re-read
        // cached items (the event stream is the live path).
        await engine.setSummariesResult(.loaded([
            QueueItemID(rawValue: "a"): makeSummary(itemID: "a", revision: 9),
        ]))
        await tracker.refreshReportSummaries(itemIDs: ids, force: false)
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "a"))?
            .revision == QueueReportRevision(rawValue: 1))

        // Forced refresh (terminal transition / explicit refresh) re-reads.
        await tracker.refreshReportSummaries(itemIDs: ids, force: true)
        #expect(tracker.reportSummary(for: QueueItemID(rawValue: "a"))?
            .revision == QueueReportRevision(rawValue: 9))

        tracker.stop()
    }

    // MARK: - View model: selected-report loading + stale-selection guard

    @MainActor
    @Test func overviewRejectsReportWhoseAttemptDiffersFromSelection() {
        // The cached report describes attempt 0; the selection has already
        // moved to attempt 1 (a retry). The Overview must fall back to the
        // payload-derived presentation until the reload lands — rendering the
        // previous attempt's inventory for the new attempt is stale content.
        let attemptZeroReport = makeReport(itemID: "ov", attempt: 0)
        #expect(ActivityWindowView.loadedReportMatches(
            report: attemptZeroReport,
            item: makeItem(id: "ov", queue: .ingestion, attempt: 0)))
        #expect(!ActivityWindowView.loadedReportMatches(
            report: attemptZeroReport,
            item: makeItem(id: "ov", queue: .ingestion, attempt: 1)))

        // Same attempt but a different item is also rejected (existing
        // itemID guard).
        #expect(!ActivityWindowView.loadedReportMatches(
            report: attemptZeroReport,
            item: makeItem(id: "other", queue: .ingestion, attempt: 0)))

        // A report that matches both item and attempt is accepted.
        let attemptOneReport = makeReport(itemID: "ov", attempt: 1)
        #expect(ActivityWindowView.loadedReportMatches(
            report: attemptOneReport,
            item: makeItem(id: "ov", queue: .ingestion, attempt: 1)))
    }

    // MARK: - Outside-filter notice (value level)

    /// The workspace's outside-filter notice (plan §"Selection, filters, and
    /// deep links") shows exactly when an ACTIVE filter hides the selected
    /// job from the navigator — the decision runs over the same haystack the
    /// navigator rows match, so the notice and the navigator can never
    /// disagree. Asserted here at value level because the notice's SwiftUI
    /// text never bridges into the hosted test's AppKit tree. The copy is
    /// pinned as constants so wording cannot drift from the docs.
    @MainActor
    @Test func outsideFilterNoticeSharesNavigatorMatchAndPinsCopy() {
        // A running ingestion job whose row resolves to a known title,
        // wiki name, target names, and a recorded summary search text.
        let item = makeItem(id: "outside", queue: .ingestion, sourceIDs: ["s1"])
        let rowTitle = "Research Long Source.pdf"
        let wikiName = "Research"
        let targetNames = ["Research Long Source.pdf"]
        let summarySearchText = "3 submitted"
        func hidden(_ filter: QueueJobFilter) -> Bool {
            ActivityWindowView.isHiddenByFilter(
                item,
                filter: filter,
                rowTitle: rowTitle,
                wikiName: wikiName,
                targetNames: targetNames,
                summarySearchText: summarySearchText)
        }

        // No filter → the notice never shows.
        #expect(!hidden(QueueJobFilter()))

        // A search the navigator accepts (row title, case-insensitively)
        // keeps the job visible.
        var matchingSearch = QueueJobFilter()
        matchingSearch.search = "research long"
        #expect(!hidden(matchingSearch))

        // The same search through the target names also matches.
        var targetSearch = QueueJobFilter()
        targetSearch.search = "research long source.pdf"
        #expect(!hidden(targetSearch))

        // A search the haystack rejects hides the job: the notice's show
        // condition fires.
        var foreignSearch = QueueJobFilter()
        foreignSearch.search = "unrelated query"
        #expect(hidden(foreignSearch))

        // Report-backed search text participates: a query only the summary
        // carries still matches.
        var summarySearch = QueueJobFilter()
        summarySearch.search = "3 submitted"
        #expect(!hidden(summarySearch))

        // A state filter the job fails hides it regardless of text.
        var stateFilter = QueueJobFilter()
        stateFilter.state = .failed
        #expect(hidden(stateFilter))

        // An operation filter that excludes ingestion jobs hides it.
        var operationFilter = QueueJobFilter()
        operationFilter.operation = .lint
        #expect(hidden(operationFilter))

        // Whitespace-only search is not an active filter.
        var blankSearch = QueueJobFilter()
        blankSearch.search = "   "
        #expect(!hidden(blankSearch))

        // The notice's copy, pinned. These are the strings the workspace
        // renders (Label + accessibility label + Clear Filters button).
        #expect(ActivityWindowView.filteredSelectionNoticeText
                == "Selected job is outside this filter")
        #expect(ActivityWindowView.clearFiltersButtonLabel == "Clear Filters")
    }

    @MainActor
    @Test func loadReportStoresCommittedReportForCurrentAttempt() async {
        let engine = StubReportEngine()
        let report = makeReport(itemID: "sel", attempt: 0, revision: 4)
        await engine.setReportResult(.loaded(report), for: QueueItemID(rawValue: "sel"))
        let viewModel = QueueViewModel()
        viewModel.attach(engine: engine)

        await viewModel.loadReport(for: QueueItemID(rawValue: "sel"), attempt: 0)

        #expect(viewModel.selectedReport == .loaded(report))
        #expect(viewModel.selectedReportItemID == QueueItemID(rawValue: "sel"))

        viewModel.detach()
    }

    @MainActor
    @Test func loadReportDiscardsStaleAttemptLoads() async {
        // A load that raced a retry carries the previous attempt's report and
        // is discarded rather than shown for the new attempt.
        let engine = StubReportEngine()
        await engine.setReportResult(
            .loaded(makeReport(itemID: "stale", attempt: 0)),
            for: QueueItemID(rawValue: "stale"))
        let viewModel = QueueViewModel()
        viewModel.attach(engine: engine)

        await viewModel.loadReport(for: QueueItemID(rawValue: "stale"), attempt: 1)

        #expect(viewModel.selectedReport == .notReported)

        viewModel.detach()
    }

    @MainActor
    @Test func loadReportSurfacesNotReportedAndUnavailable() async {
        let engine = StubReportEngine()
        await engine.setReportResult(.notReported, for: QueueItemID(rawValue: "legacy"))
        await engine.setReportResult(
            .unavailable(reason: "older daemon"), for: QueueItemID(rawValue: "broke"))
        let viewModel = QueueViewModel()
        viewModel.attach(engine: engine)

        await viewModel.loadReport(for: QueueItemID(rawValue: "legacy"), attempt: 0)
        #expect(viewModel.selectedReport == .notReported)

        await viewModel.loadReport(for: QueueItemID(rawValue: "broke"), attempt: 0)
        #expect(viewModel.selectedReport == .unavailable(reason: "older daemon"))

        viewModel.detach()
    }

    @MainActor
    @Test func slowLoadForReplacedSelectionNeverWritesAnotherJobsReport() async throws {
        // The stale-selection guard: a slow daemon load for item A that
        // finishes after the user selected item B must not write A's report
        // into B's workspace ("never another job's content", plan).
        let engine = StubReportEngine()
        let aID = QueueItemID(rawValue: "slowA")
        let bID = QueueItemID(rawValue: "fastB")
        await engine.setReportResult(
            .loaded(makeReport(itemID: "slowA", revision: 2)), for: aID)
        await engine.setReportResult(
            .loaded(makeReport(itemID: "fastB", revision: 1)), for: bID)
        // Artificial cooperative latency for A's read so the cancellation +
        // stale guard path is deterministic (no wall-clock racing).
        await engine.setReportLoadDelay(.milliseconds(250))
        let viewModel = QueueViewModel()
        viewModel.attach(engine: engine)

        // Selection A starts loading and reaches the (delayed) engine read.
        let slowTask = Task { await viewModel.loadReport(for: aID, attempt: 0) }
        await engine.waitUntilSignal(count: 1)
        // Mirroring the app's `.task(id:)` behavior, switching selection
        // cancels the in-flight load; B's load runs to completion.
        slowTask.cancel()
        await viewModel.loadReport(for: bID, attempt: 0)
        #expect(viewModel.selectedReportItemID == bID)

        // The delayed A load lands — and must be discarded.
        await slowTask.value
        #expect(viewModel.selectedReportItemID == bID)
        guard case .loaded(let report) = viewModel.selectedReport else {
            Issue.record("Expected B's report to remain loaded")
            return
        }
        #expect(report.attemptID.itemID == bID)

        viewModel.detach()
    }
}

// MARK: - Stub engine

/// Configurable `QueueEngineClient` stub for the integration tests. The
/// report/summary members are actor-isolated and delay-able so stale-load
/// races can be arranged deterministically via `waitUntilSignal(count:)`.
actor StubReportEngine: QueueEngineClient {
    private var snapshots: QueueSnapshot = QueueSnapshot()
    private var summariesResult: QueueReportSummariesResult = .loaded([:])
    private var reportResults: [QueueItem.ID: QueueReportLoadResult] = [:]
    /// Artificial read latency for `loadQueueReport` (cooperative sleep —
    /// never blocks a pool thread), used to stage stale-selection races.
    private var reportLoadDelay: Duration?

    /// Continuations resolved as engine report loads BEGIN, letting a test
    /// deterministically await "the load has started" before proceeding.
    private var loadStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var loadsStarted = 0

    func setSnapshotValue(_ snapshot: QueueSnapshot) {
        snapshots = snapshot
    }

    func setSummariesResult(_ result: QueueReportSummariesResult) {
        summariesResult = result
    }

    func setReportResult(_ result: QueueReportLoadResult, for itemID: QueueItem.ID) {
        reportResults[itemID] = result
    }

    func setReportLoadDelay(_ delay: Duration?) {
        reportLoadDelay = delay
    }

    /// Suspends until `count` report loads have started.
    func waitUntilSignal(count: Int) async {
        while loadsStarted < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                loadStartContinuations.append(continuation)
            }
        }
    }

    // MARK: QueueEngineClient

    nonisolated var events: AsyncStream<QueueEvent> { AsyncStream { _ in } }
    @discardableResult
    nonisolated func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID { QueueItemID(rawValue: "stub") }
    nonisolated func cancelItem(_ id: QueueItem.ID) async {}
    @discardableResult
    nonisolated func cancelAllInFlight() async -> Int { 0 }
    nonisolated func retryItem(_ id: QueueItem.ID) async throws {}
    nonisolated func pause(_ queue: QueueKind) async {}
    nonisolated func resume(_ queue: QueueKind) async {}
    nonisolated func halt(_ queue: QueueKind) async {}
    nonisolated func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {}
    func snapshot() async -> QueueSnapshot { snapshots }
    nonisolated func hasActiveWork(for wikiID: WikiID) async -> Bool { false }
    nonisolated func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> { .success(()) }
    nonisolated func loadTranscript(for itemID: QueueItem.ID) async -> [ChatTranscriptItem] { [] }
    nonisolated func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }

    func loadQueueReport(for itemID: QueueItem.ID) async -> QueueReportLoadResult {
        loadsStarted += 1
        let pending = loadStartContinuations
        loadStartContinuations.removeAll()
        for continuation in pending { continuation.resume() }
        if let delay = reportLoadDelay {
            // Cooperative sleep only: cancelled loads wake immediately.
            try? await Task.sleep(for: delay)
        }
        return reportResults[itemID] ?? .notReported
    }

    func loadQueueReportSummaries(for itemIDs: [QueueItem.ID]) async -> QueueReportSummariesResult {
        summariesResult
    }
}
#endif
