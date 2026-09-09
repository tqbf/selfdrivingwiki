#if os(macOS)
import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

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
        // §2 target-outcome vocabulary. Unknown outcomes render as "Planned"
        // (operator decision, 2026-09-08) — never zero, never empty success.
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
            status: .planned())
        #expect(row.id == identity.rowID)
        // The full recorded name stays reachable (tooltip/search) even though
        // the collapsed row renders the truncated title.
        #expect(row.displayName == "Research Paper — very long original filename.pdf")

        let noFullName = QueueTargetRowValue(
            identity: identity, title: "Short.pdf", status: .planned())
        #expect(noFullName.displayName == "Short.pdf")
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
        // explicit placeholders — never "—" rows for everything.
        let empty = QueueRunDetailsFacts()
        let entries = empty.entries
        #expect(entries.map(\.label) == ["Provider", "Model"])
        #expect(entries.allSatisfy { $0.isPlaceholder })
        #expect(entries.allSatisfy { $0.value == "Not Reported" })
    }

    @Test func runDetailsFullFactsOrderAndValues() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let facts = QueueRunDetailsFacts(
            enqueuedAt: start,
            startedAt: start,
            finishedAt: start.addingTimeInterval(90),
            durationText: QueueWorkspaceFormat.duration(from: start, to: start.addingTimeInterval(90)),
            attempt: 2,
            providerText: "claude-code",
            modelText: "claude-sonnet-4",
            usageLines: ["1,204 tokens · $0.012", "continuation"])
        let entries = facts.entries
        #expect(entries.map(\.label) == [
            "Enqueued", "Started", "Finished", "Duration", "Attempt",
            "Provider", "Model", "Usage", "",
        ])
        #expect(entries.containsNoPlaceholders())
        #expect(entries.first { $0.label == "Attempt" }?.value == "2")
        #expect(entries.first { $0.label == "Duration" }?.value == "1m 30s")
        // Usage continuation lines keep the grid aligned under "Usage".
        #expect(entries.last?.label.isEmpty == true)
        #expect(entries.last?.value == "continuation")
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
        #expect(QueueWorkspaceMetrics.Search.collapsedButtonSide == 28)
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
