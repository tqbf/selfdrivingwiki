import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// W2b's hosted Run Details scenarios: the Undo affordance and the "What
/// went wrong" disclosure, hosted in a real window over a REAL store.
///
/// Discovery rules (the harness's established limits, per
/// `ActivityWindowWorkspaceHostedTests`): the Run Details List bridges to a
/// real `NSTableView` (`SwiftUIOutlineListView`), so ROW STRUCTURE is
/// readable — row count, row frames, `AppKitTextInteractionView` mounts for
/// `.textSelection` rows. SwiftUI-drawn labels (button titles, the
/// aggregate and findings text) do NOT bridge — those strings are pinned by
/// `LintRepairSectionValueTests`; this suite pins the hosted WIRING: the
/// rows mount, the button row's synthesized click runs the undo through the
/// caller's flow, and the store + breaker show the real effects.
///
/// The panel's `onUndo` closure runs the same flow as the Activity window's
/// action (batch plans from the section's pages, one
/// `LintUndoService.undoRepairedPages` call, then publish the result and
/// trip message into the section's presentation state).
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct LintRunDetailsScenarioTests {

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination(
            "hosted lint Run Details scenarios")
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated], reason: "hosted lint Run Details scenarios")
        return app
    }()

    /// The facts rows every panel carries (Job ID, Provider, Model).
    private static let baseRowCount = 3

    // MARK: - Fixture

    /// A real store with one repaired page and one repaired-then-edited
    /// page (the mixed batch), plus the run's durable-shaped records.
    @MainActor
    private final class Fixture {
        let root: URL
        let store: GRDBWikiStore
        let breaker: LintRepairBreaker
        let breakerKey = LintRepairBreakerKey(
            pipelineDigest: "scenario-digest", provider: "anthropic",
            model: "claude-opus", effort: "high")
        let page: WikiPage
        let inspectedHead: PageVersionID
        let writtenHead: PageVersionID
        /// A second page whose head moved AFTER the run.
        let movedPage: WikiPage
        let movedInspectedHead: PageVersionID
        let movedWrittenHead: PageVersionID

        static let approvalRowID = "apr-scenario"
        static let wikiID = WikiID(rawValue: "scenario-wiki")

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lint-details-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try GRDBWikiStore(databaseURL: root.appendingPathComponent("WikiFS.sqlite"))
            let root = self.root
            breaker = LintRepairBreaker(containerResolver: { root.appendingPathComponent("appgroup") })

            page = try store.createPage(title: "Gate page")
            try store.updatePage(id: page.id, title: "Gate page", body: "# Original\n\nplain body\n")
            inspectedHead = try #require(try store.pageHeadVersionID(pageID: page.id))
            try store.updatePage(id: page.id, title: "Gate page", body: "# Repaired\n\nfixed body\n")
            writtenHead = try #require(try store.pageHeadVersionID(pageID: page.id))

            movedPage = try store.createPage(title: "Moved page")
            try store.updatePage(id: movedPage.id, title: "Moved page", body: "before\n")
            movedInspectedHead = try #require(try store.pageHeadVersionID(pageID: movedPage.id))
            try store.updatePage(id: movedPage.id, title: "Moved page", body: "repaired\n")
            movedWrittenHead = try #require(try store.pageHeadVersionID(pageID: movedPage.id))
            try store.updatePage(
                id: movedPage.id, title: "Moved page", body: "hand edit after the run\n")
        }

        func repairRecord(
            _ pageID: PageID, title: String,
            inspected: PageVersionID, written: PageVersionID
        ) -> QueueReportTargetRecord {
            QueueReportTargetRecord(
                target: .page(pageID), displayName: title, state: .succeeded,
                detail: "authority_tier=shippedApproval; approval_id=\(Self.approvalRowID); "
                    + "audited head \(inspected.rawValue); run-report coverage complete; "
                    + "verification verified on the written head; "
                    + "written_head=\(written.rawValue); "
                    + "authority_tier=shippedApproval; approval_id=\(Self.approvalRowID)")
        }

        func failureRecord(
            _ pageID: PageID, title: String,
            inspected: PageVersionID, written: PageVersionID
        ) -> QueueReportTargetRecord {
            QueueReportTargetRecord(
                target: .page(pageID), displayName: title, state: .failed(reason: "x"),
                detail: "authority_tier=shippedApproval; approval_id=\(Self.approvalRowID); "
                    + "revert=reverted to \(inspected.rawValue) from \(written.rawValue); "
                    + "audited head \(inspected.rawValue); run-report coverage complete; "
                    + "verification failed: claimed repair for D03|line-2#1 but the finding persists on the written head; "
                    + "written_head=\(written.rawValue); "
                    + "revert=reverted to \(inspected.rawValue) from \(written.rawValue); "
                    + "authority_tier=shippedApproval; approval_id=\(Self.approvalRowID)")
        }

        func report(records: [QueueReportTargetRecord]) -> QueueAttemptReport {
            QueueAttemptReport(
                attemptID: QueueAttemptID(
                    itemID: QueueItem.ID(rawValue: "lint-item"), attempt: 0),
                executionID: QueueExecutionID(rawValue: UUID()),
                revision: QueueReportRevision(rawValue: 1),
                operation: .lint,
                scope: .targets(records),
                phase: .finished,
                provider: ProviderID(rawValue: "anthropic"),
                model: QueueReportModelName(rawValue: "claude-opus"),
                availability: .available,
                resultSummary: "Per-page lint outcomes: 2 applied",
                usage: nil, outputs: nil,
                targets: records)
        }

        /// Two repaired pages: one survivable, one whose head moved.
        func mixedUndoSection() throws -> QueueRunDetailsLintRepair {
            try #require(QueueRunDetailsLintRepair.make(
                report: report(records: [
                    repairRecord(
                        page.id, title: "Gate page",
                        inspected: inspectedHead, written: writtenHead),
                    repairRecord(
                        movedPage.id, title: "Moved page",
                        inspected: movedInspectedHead, written: movedWrittenHead),
                ]),
                wikiID: Self.wikiID))
        }

        /// One clean repair (pure revert).
        func singleUndoSection() throws -> QueueRunDetailsLintRepair {
            try #require(QueueRunDetailsLintRepair.make(
                report: report(records: [
                    repairRecord(
                        page.id, title: "Gate page",
                        inspected: inspectedHead, written: writtenHead),
                ]),
                wikiID: Self.wikiID))
        }

        /// An auto-reverted run with a persisted verification failure and
        /// no undoable pages.
        func failureSection() throws -> QueueRunDetailsLintRepair {
            try #require(QueueRunDetailsLintRepair.make(
                report: report(records: [
                    failureRecord(
                        page.id, title: "Gate page",
                        inspected: inspectedHead, written: writtenHead),
                ]),
                wikiID: Self.wikiID))
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The panel under test: the Run Details List plus the lint repair
    /// section, with the undo flow wired exactly as the Activity window
    /// wires it.
    private struct HostedPanel: View {
        let facts: QueueRunDetailsFacts
        @State var repair: QueueRunDetailsLintRepair?
        let store: GRDBWikiStore
        let breaker: LintRepairBreaker
        let breakerKey: LintRepairBreakerKey

        var body: some View {
            QueueRunDetailsView(
                facts,
                lintRepair: repair,
                onUndo: repair?.showsUndoButton == true ? { runUndo() } : nil,
                versionBody: { versionID in
                    do { return try store.pageVersionBody(versionID: versionID) }
                    catch { return nil }
                })
                .frame(width: 380, height: 620)
                .background(Color(nsColor: .windowBackgroundColor))
        }

        private func runUndo() {
            guard let current = repair, current.showsUndoButton else { return }
            let plans = current.repairPages.map {
                LintUndoService.PagePlan(
                    pageID: $0.pageID, inspectedHead: $0.inspectedHead,
                    writtenHead: $0.writtenHead)
            }
            var inFlight = current
            inFlight.undoInFlight = true
            repair = inFlight
            Task { @MainActor in
                let result = LintUndoService.undoRepairedPages(
                    store: store, pages: plans, breaker: breaker, breakerKey: breakerKey)
                var updated = current
                updated.undoInFlight = false
                updated.undoResult = result
                updated.breakerNotice = result.breakerVerdict.flatMap {
                    LintUndoService.breakerTripMessage($0)
                }
                repair = updated
            }
        }
    }

    // MARK: - Mount + discovery

    private struct Mounted {
        let window: NSWindow
        let fixture: Fixture
    }

    private func mount(_ repair: QueueRunDetailsLintRepair?, fixture: Fixture) -> Mounted {
        _ = Self.app
        let panel = HostedPanel(
            facts: QueueRunDetailsFacts(
                jobID: QueueItem.ID(rawValue: "lint-item"),
                providerModel: .agent(provider: "anthropic", model: "claude-opus")),
            repair: repair,
            store: fixture.store,
            breaker: fixture.breaker,
            breakerKey: fixture.breakerKey)
        let host = NSHostingController(rootView: panel)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 400, height: 640))
        window.makeKeyAndOrderFront(nil)
        return Mounted(window: window, fixture: fixture)
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        var out = [root]
        for child in root.subviews {
            out.append(contentsOf: allSubviews(of: child))
        }
        return out
    }

    /// The List's bridged table (SwiftUI Lists bridge to
    /// `SwiftUIOutlineListView`, an NSTableView subclass).
    private func outlineTable(in mounted: Mounted) -> NSTableView? {
        allSubviews(of: mounted.window.contentView!).compactMap { $0 as? NSTableView }.first
    }

    private func rowCount(in mounted: Mounted) -> Int {
        outlineTable(in: mounted)?.numberOfRows ?? 0
    }

    /// The row's view for a visible row (lazy materialization makes the
    /// last row provably reachable per the established suite).
    private func rowView(at index: Int, in mounted: Mounted) -> NSView? {
        guard let table = outlineTable(in: mounted), index < table.numberOfRows else {
            return nil
        }
        return table.rowView(atRow: index, makeIfNecessary: false)
    }

    /// The row's frame in window coordinates.
    private func frameInWindow(_ view: NSView, window: NSWindow) -> CGRect {
        view.convert(view.bounds, to: nil)
    }

    /// Press the leading region of a row view with a synthesized mouse
    /// click — the real event path (the same seam the other hosted suite
    /// uses for its toolbar toggle). The section's controls (the undo
    /// button, the disclosure toggle) are leading-aligned; a row-center
    /// click lands on the row's spacer, not the control.
    private func pressRow(_ rowView: NSView, window: NSWindow) -> Bool {
        let bounds = frameInWindow(rowView, window: window)
        let center = CGPoint(x: bounds.minX + 40, y: bounds.midY)
        let uptime = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: center, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: center, modifierFlags: [],
                timestamp: uptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0)
        else { return false }
        window.sendEvent(down)
        window.sendEvent(up)
        return true
    }

    /// The mounted `.textSelection` rows — the only SwiftUI-drawn text that
    /// bridges to AppKit (`AppKitTextInteractionView`).
    private func interactionTextCount(in mounted: Mounted) -> Int {
        allSubviews(of: mounted.window.contentView!)
            .filter { String(describing: type(of: $0)).contains("AppKitTextInteraction") }
            .count
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        attempts: Int = 40
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func settle() async {
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Press the section's control row (the undo row, or the disclosure
    /// row) with bounded retries — SwiftUI materializes the row's hosted
    /// control asynchronously, so the first synthesized click can land
    /// before the button mounts. `effect` is the observable outcome.
    private func pressControlRowUntil(
        at index: Int, in mounted: Mounted,
        effect: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<6 {
            if let row = rowView(at: index, in: mounted) {
                _ = pressRow(row, window: mounted.window)
            }
            if await waitUntil(effect, attempts: 10) { return true }
        }
        return effect()
    }

    // MARK: - (a) Button renders exactly when surviving repairs exist

    @Test func undoRowRendersOnlyWhenSurvivingRepairsExist() async throws {
        let fixture = try Fixture()

        // A report-only run maps to NO section at all — only the facts rows.
        let reportOnlySection = QueueRunDetailsLintRepair.make(
            report: fixture.report(records: [
                QueueReportTargetRecord(
                    target: .page(fixture.page.id), displayName: "Gate page",
                    state: .succeeded,
                    detail: "authority_tier=reportOnly; authority_reason=gates; "
                        + "audited head \(fixture.inspectedHead.rawValue); "
                        + "no run scratch to read the run report from"),
            ]),
            wikiID: Fixture.wikiID)
        #expect(reportOnlySection == nil,
                "a report-only run has no lint repair section — no undo row, hidden not disabled")

        // An auto-reverted run: the disclosure row renders, the undo row
        // does NOT — the write did not survive.
        let revertedSection = try fixture.failureSection()
        #expect(revertedSection.showsUndoButton == false)
        #expect(revertedSection.showsDisclosure)
        let flagged = mount(revertedSection, fixture: fixture)
        _ = await waitUntil { [self] in rowCount(in: flagged) == Self.baseRowCount + 1 }
        #expect(rowCount(in: flagged) == Self.baseRowCount + 1,
                "the failed run renders its facts plus the disclosure row — no undo row")

        // One surviving repair: the undo row renders after the facts.
        let undoable = try fixture.singleUndoSection()
        #expect(undoable.showsUndoButton)
        #expect(undoable.appliedFixCount == 1)
        let mounted = mount(undoable, fixture: fixture)
        let fiveRows = await waitUntil { [self] in
            rowCount(in: mounted) == Self.baseRowCount + 2
        }
        #expect(fiveRows, "the undoable run renders facts + fixes row + undo row")
        let lastRow = rowView(at: Self.baseRowCount + 1, in: mounted)
        #expect(lastRow != nil, "the undo row materializes")
    }

    // MARK: - (b) Tap reverts and records the breaker undo

    @Test func tappingUndoRevertsAndRecordsBreakerUndo() async throws {
        let fixture = try Fixture()
        let mounted = mount(try fixture.singleUndoSection(), fixture: fixture)
        _ = await waitUntil { [self] in rowCount(in: mounted) == Self.baseRowCount + 2 }

        // The undo row is the LAST row of the undoable panel. The click
        // retries until the store shows the revert (the row's hosted button
        // materializes asynchronously).
        let undone = await pressControlRowUntil(
            at: Self.baseRowCount + 1, in: mounted,
            effect: {
                (try? fixture.store.pageHeadVersionID(pageID: fixture.page.id))
                    == fixture.inspectedHead
            })
        #expect(undone, "the synthesized click ran the undo batch")
        let headAfter = try #require(
            try fixture.store.pageHeadVersionID(pageID: fixture.page.id))
        #expect(headAfter == fixture.inspectedHead,
                "the click ran the undo: the page is back at the inspected head")
        #expect(fixture.breaker.windowStatus(for: fixture.breakerKey).userUndos == 1,
                "one click is ONE user undo for the configuration")
        let head = try #require(try fixture.store.pageHeadVersionID(pageID: fixture.page.id))
        #expect(head == fixture.inspectedHead, "the page is back at the inspected head")
        let status = fixture.breaker.windowStatus(for: fixture.breakerKey)
        #expect(status.userUndos == 1, "one click is ONE user undo for the configuration")
        #expect(status.isTripped == false)
    }

    // MARK: - (c) Head-moved page: no revert, manual-revert row mounts

    @Test func headMovedPageShowsManualRevertMessageAndDoesNotRevert() async throws {
        let fixture = try Fixture()
        // A concurrent writer moves the second page after the run.
        try fixture.store.updatePage(
            id: fixture.movedPage.id, title: "Moved page", body: "a different hand edit\n")
        let currentHead = try #require(
            try fixture.store.pageHeadVersionID(pageID: fixture.movedPage.id))

        let mounted = mount(try fixture.mixedUndoSection(), fixture: fixture)
        _ = await waitUntil { [self] in rowCount(in: mounted) == Self.baseRowCount + 2 }

        // The honest partial outcome mounts: the moved page's manual-revert
        // row (a `.textSelection` row, so it bridges as an interaction view)
        // plus the disclosure row — and the store shows the split.
        let partialMounted = await pressControlRowUntil(
            at: Self.baseRowCount + 1, in: mounted,
            effect: { [self] in
                rowCount(in: mounted) >= Self.baseRowCount + 3
                    && interactionTextCount(in: mounted) >= Self.baseRowCount + 1
            })
        #expect(partialMounted,
                "the moved page's manual-revert row and the disclosure mount")

        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.movedPage.id) == currentHead,
                "the moved page was NOT reverted")
        #expect(try fixture.store.pageHeadVersionID(pageID: fixture.page.id) == fixture.inspectedHead,
                "the clean page reverted to the inspected head")
        #expect(fixture.breaker.windowStatus(for: fixture.breakerKey).userUndos == 1,
                "the batch records ONE undo, not one per page")
    }

    // MARK: - (d) Disclosure mounts findings + reverted diff

    @Test func disclosureMountsFindingsAndRevertedDiff() async throws {
        let fixture = try Fixture()
        let mounted = mount(try fixture.failureSection(), fixture: fixture)
        _ = await waitUntil { [self] in rowCount(in: mounted) == Self.baseRowCount + 1 }

        let before = interactionTextCount(in: mounted)

        // Expanding mounts the findings row content: the persisted finding
        // is a `.textSelection` row (bridges), and the reused SplitDiffView's
        // 220pt pane grows the disclosure row's height.
        let expanded = await pressControlRowUntil(
            at: Self.baseRowCount, in: mounted,
            effect: { [self] in interactionTextCount(in: mounted) > before })
        #expect(expanded, "expanding mounts the persisted finding rows")
        let height = rowView(at: Self.baseRowCount, in: mounted).map {
            frameInWindow($0, window: mounted.window).height
        } ?? 0
        #expect(height > 200,
                "the reverted diff pane grows the disclosure row (measured \(height))")

        let value = try fixture.failureSection()
        #expect(value.failurePages.count == 1)
        #expect(value.failurePages.first?.reasons == [
            "claimed repair for D03|line-2#1 but the finding persists on the written head",
        ])
        #expect(value.failurePages.first?.writtenHead == fixture.writtenHead)
        #expect(value.failurePages.first?.inspectedHead == fixture.inspectedHead)
    }

    // MARK: - (e) Breaker trips after the second undo

    @Test func breakerTripsAfterSecondUndo() async throws {
        let fixture = try Fixture()

        // First run's undo (mixed batch): within tolerance.
        let firstMounted = mount(try fixture.mixedUndoSection(), fixture: fixture)
        _ = await waitUntil { rowCount(in: firstMounted) == Self.baseRowCount + 2 }
        let firstDone = await pressControlRowUntil(
            at: Self.baseRowCount + 1, in: firstMounted,
            effect: {
                fixture.breaker.windowStatus(for: fixture.breakerKey).userUndos == 1
            })
        #expect(firstDone, "the first undo records one breaker undo")
        #expect(fixture.breaker.windowStatus(for: fixture.breakerKey).isTripped == false)

        // A SECOND run repairs the page again; undoing it is the second undo
        // for this configuration — the breaker trips.
        try fixture.store.updatePage(
            id: fixture.page.id, title: "Gate page", body: "# Repaired again\n\nsecond write\n")
        let secondWritten = try #require(
            try fixture.store.pageHeadVersionID(pageID: fixture.page.id))
        let secondSection = try #require(QueueRunDetailsLintRepair.make(
            report: fixture.report(records: [
                fixture.repairRecord(
                    fixture.page.id, title: "Gate page",
                    inspected: fixture.inspectedHead, written: secondWritten),
            ]),
            wikiID: Fixture.wikiID))
        let secondMounted = mount(secondSection, fixture: fixture)
        _ = await waitUntil { rowCount(in: secondMounted) == Self.baseRowCount + 2 }
        _ = await pressControlRowUntil(
            at: Self.baseRowCount + 1, in: secondMounted,
            effect: {
                fixture.breaker.windowStatus(for: fixture.breakerKey).isTripped
            })

        let tripped = fixture.breaker.windowStatus(for: fixture.breakerKey)
        #expect(tripped.isTripped, "the second undo trips the breaker")
        let reason = try #require(tripped.tripReason)
        let message = try #require(LintUndoService.breakerTripMessage(.tripped(reason: reason)))
        #expect(message.hasPrefix("Auto-repair paused for this configuration"))
        #expect(message.contains("2 user undos"), "the breaker's own reason rides in the message")
    }
}
