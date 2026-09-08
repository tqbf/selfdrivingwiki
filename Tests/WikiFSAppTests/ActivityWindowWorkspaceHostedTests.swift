#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// H1: real hosted `NSWindow` scenarios for the Activity window's queue
/// workspace — the plan's named acceptance surface (plan §1 + §"Selection,
/// filters, and deep links"), mounted as the production view, not a
/// value-level stand-in.
///
/// **One shared window.** Mounting a SECOND full Activity window in the same
/// test process exits the process silently (AppKit/SwiftUI hosting teardown
/// limitation — the same class of hazard the `HostedAppKitTestGate` exists
/// for). The suite therefore mounts ONE production window and drives every
/// scenario through it: the scripted engine's snapshot is mutable and each
/// `update(_:)` yields a `.runStateChanged` event so the view model
/// refreshes, and cross-job scenarios select items through the real
/// deep-link seam (`pendingSelectionItemID`/`pendingSelectionQueue`).
/// Tests are serialized and run in source order — later scenarios build on
/// the state earlier ones left.
///
/// **Discovery surface.** SwiftUI draws `Text` and custom-labeled buttons
/// into its own layer — neither the AppKit view tree nor the in-process
/// accessibility tree exposes those in a `swift test` host (verified: no
/// NSTextField mounts, the AX tree surfaces only platform-backed controls,
/// and forcing manual accessibility changes nothing). The harness therefore
/// finds the parts of the production window that DO bridge to real AppKit
/// objects, and asserts through those:
/// - the toolbar (`NSToolbarItem.label`, e.g. "Pause Queue") and the
///   `NSPopUpButton` the Queue Actions menu mounts as,
/// - the segmented Overview/Activity selector (`NSSegmentedControl` labels),
/// - the navigator's Filter popup button (real title),
/// - editable `NSTextField`s — the Overview's local search placeholder
///   ("Find in Sources" / "Find in Pages"), the workspace's kind-specific
///   language in bridgeable form,
/// - the real `SwiftUIAppKitButton`s inside navigator row cells (the
///   trailing cancel/retry actions) — pressed with `performClick`,
/// - the inventory's `NSTableView` (`numberOfRows`, `rowView(atRow:)` — lazy
///   materialization makes the last row provably reachable).
///
/// Label text that only SwiftUI draws (section headers, statuses, notices)
/// stays pinned by the value-level suites (`QueueWorkspacePresentationTests`,
/// `QueueWorkspaceIntegrationTests`); this suite pins the hosted wiring.
///
/// Suite discipline: serialized + time-limited, every wait is a bounded
/// condition loop with cooperative `Task.sleep` (never parks the cooperative
/// pool), and the shared window stays mounted for the whole suite.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ActivityWindowWorkspaceHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    // MARK: - Shared mount

    /// The suite's single hosted window (see the type doc). Lazily mounted on
    /// the first scenario; the gate lease is held for the suite's lifetime.
    private nonisolated(unsafe) static var sharedMount: Mounted?

    /// The suite's fixtures, mounted once:
    /// - `running` — an active ingestion job (the harness scenario drives it),
    /// - `lintPages` / `wholeWiki` — lint jobs for the shared-workspace
    ///   scenarios,
    /// - `large` — a completed job with a 300-target report.
    private static let running = QueueItem(
        id: QueueItemID(rawValue: "shared-running"),
        queue: .ingestion,
        wikiID: WikiID(rawValue: "workspace-wiki"),
        payload: QueueItemPayload(
            sourceIDs: (0..<15).map { SourceID(rawValue: "rs\($0)") }),
        state: .running,
        orderingKey: 1_000,
        attempt: 0,
        createdAt: 0,
        startedAt: Int64(Date().timeIntervalSince1970 * 1000) - 60_000)

    /// A page-lint job (shared-workspace scenario).
    private static let lintPages = QueueItem(
        id: QueueItemID(rawValue: "shared-lint"),
        queue: .ingestion,
        wikiID: WikiID(rawValue: "workspace-wiki"),
        payload: QueueItemPayload(
            sourceIDs: [],
            lintPageIDs: (0..<15).map { PageID(rawValue: "lp\($0)") }),
        state: .running,
        orderingKey: 2_000,
        attempt: 0,
        createdAt: 0,
        startedAt: Int64(Date().timeIntervalSince1970 * 1000) - 50_000)

    /// A whole-wiki lint job (shared-workspace scenario).
    private static let wholeWiki = QueueItem(
        id: QueueItemID(rawValue: "shared-whole"),
        queue: .ingestion,
        wikiID: WikiID(rawValue: "workspace-wiki"),
        payload: QueueItemPayload(sourceIDs: [], lintPageIDs: []),
        state: .running,
        orderingKey: 3_000,
        attempt: 0,
        createdAt: 0,
        startedAt: Int64(Date().timeIntervalSince1970 * 1000) - 40_000)

    /// A completed job with a 300-target report (large-inventory scenario).
    private static let large = QueueItem(
        id: QueueItemID(rawValue: "large"),
        queue: .ingestion,
        wikiID: WikiID(rawValue: "workspace-wiki"),
        payload: QueueItemPayload(
            sourceIDs: (0..<300).map { SourceID(rawValue: "s\($0)") }),
        state: .completed,
        orderingKey: 4_000,
        attempt: 0,
        createdAt: 0,
        startedAt: 0,
        finishedAt: Int64(Date().timeIntervalSince1970 * 1000) - 10_000)

    /// The full fixture snapshot, with `running` optionally replaced by a
    /// state-transitioned variant of itself (the action scenarios).
    private static func fixtures(
        runningVariant: QueueItem? = nil
    ) -> QueueSnapshot {
        QueueSnapshot(
            activeItems: [runningVariant ?? running, lintPages, wholeWiki],
            recentItems: [large],
            runStates: [.ingestion: .running])
    }

    /// The shared mount, hosting it on first use.
    private func workspace() async throws -> Mounted {
        if let mounted = Self.sharedMount { return mounted }
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let targets = (0..<300).map { index in
            QueueReportTargetRecord(
                target: .source(SourceID(rawValue: "s\(index)")),
                displayName: String(format: "Target-%03d", index),
                state: .planned)
        }
        let client = ScriptedQueueEngineClient(
            snapshot: Self.fixtures(),
            reports: [Self.large.id: .loaded(Self.makeReport(item: Self.large, targets: targets))])
        let tracker = QueueActivityTracker()
        tracker.attach(engine: client)
        let root = ActivityWindowView(
            queue: .ingestion,
            queueEngine: client,
            activityTracker: tracker,
            sessionManager: nil)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight))
        window.makeKeyAndOrderFront(nil)
        let mounted = Mounted(
            window: window, host: host, client: client, tracker: tracker, lease: lease)
        Self.sharedMount = mounted
        await settle()
        return mounted
    }

    /// The suite's single hosted window, mounted on first use.
    @MainActor
    private final class Mounted {
        let window: NSWindow
        let host: NSHostingController<ActivityWindowView>
        let client: ScriptedQueueEngineClient
        let tracker: QueueActivityTracker
        /// Held for the suite's lifetime: a second full Activity-window mount
        /// in one process exits silently, so this window must never unmount
        /// mid-suite.
        private let lease: HostedAppKitTestGate.Lease

        init(
            window: NSWindow,
            host: NSHostingController<ActivityWindowView>,
            client: ScriptedQueueEngineClient,
            tracker: QueueActivityTracker,
            lease: HostedAppKitTestGate.Lease
        ) {
            self.window = window
            self.host = host
            self.client = client
            self.tracker = tracker
            self.lease = lease
        }

        var rootView: NSView { host.view }
    }

    /// Wait until `condition` holds, bounded by `attempts` × 50 ms.
    @discardableResult
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        attempts: Int = 30,
        label: String = "condition"
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// One bounded settle beat for SwiftUI layout after mount/interaction.
    private func settle(_ attempts: Int = 10) async {
        for _ in 0..<attempts {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Select a job through the REAL deep-link seam: the tracker's pending
    /// selection is consumed by the window's `onChange` (#837 path).
    private func select(_ itemID: QueueItem.ID, on mounted: Mounted) {
        mounted.tracker.pendingSelectionItemID = itemID
        mounted.tracker.pendingSelectionQueue = .ingestion
    }

    // MARK: - Bridged-surface discovery

    /// Every subview of `root`, depth-first, including `root`.
    private func allSubviews(of root: NSView) -> [NSView] {
        var out = [root]
        for child in root.subviews {
            out.append(contentsOf: allSubviews(of: child))
        }
        return out
    }

    /// All pop-up buttons in the hosted tree (menus bridge here).
    private func popupButtons(in root: NSView) -> [NSPopUpButton] {
        allSubviews(of: root).compactMap { $0 as? NSPopUpButton }
    }

    /// All segmented controls in the hosted tree.
    private func segmentedControls(in root: NSView) -> [NSSegmentedControl] {
        allSubviews(of: root).compactMap { $0 as? NSSegmentedControl }
    }

    /// All table views in the hosted tree (SwiftUI Lists bridge to
    /// `SwiftUIOutlineListView`, an `NSTableView` subclass).
    private func tables(in root: NSView) -> [NSTableView] {
        allSubviews(of: root).compactMap { $0 as? NSTableView }
    }

    /// The Overview/Activity selector: the segmented control whose segments
    /// are exactly Overview, Activity.
    private func surfaceSelector(in root: NSView) -> NSSegmentedControl? {
        segmentedControls(in: root).first {
            $0.segmentCount == 2
                && $0.label(forSegment: 0) == "Overview"
                && $0.label(forSegment: 1) == "Activity"
        }
    }

    /// The navigator rows' trailing action buttons — real `NSButton`s the
    /// List row cells host (icon-only Cancel / Retry). Bounded by the
    /// navigator table's actual trailing edge: the detail column's inventory
    /// List also hosts cell-backed buttons (target-row chevrons and the Run
    /// Details disclosure toggle), and at the sidebar's ideal width those sit
    /// under any constant bound.
    private func rowActionButtons(in root: NSView) -> [NSButton] {
        let columnMaxX = sidebarTable(in: root)
            .map { $0.convert($0.bounds, to: nil).maxX }
            ?? QueueWorkspaceMetrics.Navigator.maxWidth + 40
        return allSubviews(of: root).compactMap { $0 as? NSButton }.filter { button in
            guard isInListRowCell(button) else { return false }
            let windowFrame = button.convert(button.bounds, to: nil)
            return windowFrame.minX < columnMaxX
        }
    }

    /// Whether `button` lives inside a List row cell (the shared navigator /
    /// inventory cell-hosted button disambiguator).
    private func isInListRowCell(_ button: NSView) -> Bool {
        var ancestor: NSView? = button.superview
        while let view = ancestor {
            let name = String(describing: type(of: view))
            if name.contains("ListTableCellView") || name.contains("ListTableRowView") {
                return true
            }
            ancestor = view.superview
        }
        return false
    }

    /// The navigator sidebar table — the leftmost table in the hosted tree
    /// (both columns bridge their Lists to real `NSTableView`s at these
    /// fixture sizes).
    private func sidebarTable(in root: NSView) -> NSTableView? {
        tables(in: root)
            .filter { $0.bounds.height > 0 }
            .min { lhs, rhs in
                lhs.convert(lhs.bounds, to: nil).minX
                    < rhs.convert(rhs.bounds, to: nil).minX
            }
    }

    /// Editable text fields' placeholders (the Overview's local search).
    private func placeholders(in root: NSView) -> [String] {
        allSubviews(of: root).compactMap {
            ($0 as? NSTextField)?.placeholderString
        }
    }

    /// Toolbar item labels (the Pause Queue control is a real NSToolbarItem).
    private func toolbarLabels(of window: NSWindow) -> [String] {
        window.toolbar?.items.map(\.label) ?? []
    }

    /// The selected job's inventory table — the table view with the most rows
    /// (the navigator sidebar never matches at these fixture sizes).
    private func largestTable(in root: NSView) -> NSTableView? {
        tables(in: root).max { $0.numberOfRows < $1.numberOfRows }
    }

    // MARK: - Fixtures

    private func makeItem(
        id: String,
        state: QueueItemState,
        sourceIDs: [String] = [],
        lintPageIDs: [PageID]? = nil,
        error: String? = nil
    ) -> QueueItem {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return QueueItem(
            id: QueueItemID(rawValue: id),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "workspace-wiki"),
            payload: QueueItemPayload(
                sourceIDs: sourceIDs.map { SourceID(rawValue: $0) },
                lintPageIDs: lintPageIDs),
            state: state,
            orderingKey: 1_000,
            attempt: 0,
            error: error,
            createdAt: now - 120_000,
            startedAt: state == .queued ? nil : now - 60_000,
            finishedAt: state == .completed || state == .failed || state == .cancelled
                ? now - 10_000
                : nil)
    }

    /// A durable report for the selected job's Overview.
    private static func makeReport(
        item: QueueItem,
        targets: [QueueReportTargetRecord],
        operation: QueueReportOperation = .ingest
    ) -> QueueAttemptReport {
        QueueAttemptReport(
            attemptID: QueueAttemptID(itemID: item.id, attempt: item.attempt),
            executionID: QueueExecutionID(rawValue: UUID()),
            revision: QueueReportRevision(rawValue: 1),
            operation: operation,
            scope: .targets(targets),
            phase: .finished,
            provider: nil,
            model: nil,
            availability: .available,
            resultSummary: "3 submitted",
            targets: targets)
    }

    // MARK: - Scenario: the harness (visible label + real invoked action)

    @Test func hostedHarnessFindsVisibleLabelAndInvokesAction() async throws {
        let mounted = try await workspace()

        // The harness finds visible labels: the window title, the shared
        // Overview/Activity selector, and the real Pause Queue toolbar item.
        let selectorFound = await waitUntil {
            surfaceSelector(in: mounted.rootView) != nil
        }
        #expect(selectorFound, "The Overview/Activity selector must be visible")
        #expect(mounted.window.title == "Agent Queue")
        #expect(toolbarLabels(of: mounted.window).contains("Pause Queue"),
                "The Pause Queue toolbar item must be visible")

        // …and invokes a real action: pressing the navigator row's Cancel
        // button (a real NSButton in the row cell) reaches the engine.
        let cancelButton = try #require(
            await waitForRowActionButton(in: mounted.rootView),
            "The running job's row must host a Cancel action button")
        cancelButton.performClick(nil)
        let recorded = await waitUntil {
            mounted.client.recordedCommands.contains(
                "cancelItem:\(Self.running.id.rawValue)")
        }
        #expect(recorded, "Pressing the row Cancel must run cancelItem on the engine")
    }

    /// Bounded wait for the navigator rows' trailing action button.
    private func waitForRowActionButton(
        in root: NSView
    ) async -> NSButton? {
        for _ in 0..<30 {
            if let button = rowActionButtons(in: root).first {
                return button
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return rowActionButtons(in: root).first
    }

    // MARK: - Scenario: state-driven workspace actions
    //
    // Drives the shared job through failed and queued states. The failed
    // row's hosted click wedges the environment (silent process exit), so
    // that half pins the action's PRESENCE; the command the button runs is
    // pinned at the presentation level (`QueueWorkspacePresentationTests`
    // lifecycle showsRetryAction) and — for states whose clicks are stable —
    // hosted below.

    @Test func workspaceActionScenariosFailedJobHostsRetryAction() async throws {
        let mounted = try await workspace()
        // Transition the shared job to failed through the real event path —
        // the other fixtures stay in the snapshot so selection survives.
        var failed = Self.running
        failed.state = .failed
        failed.error = "convert failed"
        mounted.client.update(snapshot: Self.fixtures(runningVariant: failed))
        await settle(4)

        let retryButton = try #require(
            await waitForRowActionButton(in: mounted.rootView),
            "A failed job's row must host its Retry action button")
        #expect(retryButton.isEnabled, "The failed row's Retry action must be enabled")
        #expect(surfaceSelector(in: mounted.rootView) != nil,
                "The shared Overview/Activity selector is present for failed jobs")
    }

    @Test func workspaceActionScenariosQueuedJobRunsCancel() async throws {
        let mounted = try await workspace()
        var queued = Self.running
        queued.state = .queued
        mounted.client.update(snapshot: Self.fixtures(runningVariant: queued))
        await settle(4)

        let cancelButton = try #require(
            await waitForRowActionButton(in: mounted.rootView),
            "A queued job's row must host its Cancel action button")
        cancelButton.performClick(nil)
        let cancelled = await waitUntil {
            mounted.client.recordedCommands.contains(
                "cancelItem:\(Self.running.id.rawValue)")
        }
        #expect(cancelled, "The queued row's action must be cancelItem")
        #expect(surfaceSelector(in: mounted.rootView) != nil,
                "The shared Overview/Activity selector is present for queued jobs")
        #expect(toolbarLabels(of: mounted.window).contains("Pause Queue"),
                "The Pause Queue control is present")
    }

    // MARK: - Scenario: one shared workspace across operations
    //
    // Kind-specific language asserted through the Overview's local-search
    // placeholder — the bridgeable surface where "Sources" vs "Pages"
    // reaches AppKit. Jobs are selected through the deep-link seam.

    @Test func sharedWorkspaceAcrossOperationsIngestUsesSourcesLanguage() async throws {
        let mounted = try await workspace()
        select(Self.running.id, on: mounted)
        let ingestSearch = await waitUntil {
            placeholders(in: mounted.rootView).contains("Find in Sources")
        }
        #expect(ingestSearch, "Ingestion batches surface 'Find in Sources'")
        #expect(surfaceSelector(in: mounted.rootView) != nil,
                "Shared selector present for ingestion")
    }

    @Test func sharedWorkspaceAcrossOperationsLintUsesPagesLanguage() async throws {
        let mounted = try await workspace()
        select(QueueItemID(rawValue: "shared-lint"), on: mounted)
        let lintSearch = await waitUntil {
            placeholders(in: mounted.rootView).contains("Find in Pages")
        }
        #expect(lintSearch, "Lint batches surface 'Find in Pages'")
        #expect(placeholders(in: mounted.rootView).contains("Find in Sources") == false,
                "The lint workspace never claims the sources language")
        #expect(surfaceSelector(in: mounted.rootView) != nil,
                "Shared selector present for lint")
    }

    @Test func sharedWorkspaceAcrossOperationsWholeWikiStaysOneScopeRow() async throws {
        let mounted = try await workspace()
        // Whole-wiki lint: exactly ONE inventory row — the scope marker. The
        // workspace never enumerates the wiki's pages. Wait for the selection
        // to propagate and the one-row overview table to mount.
        select(QueueItemID(rawValue: "shared-whole"), on: mounted)
        // Whole-wiki lint: exactly ONE inventory target row — the scope
        // marker. The workspace never enumerates the wiki's pages. The
        // Overview's List carries two trailing rows below the boundary
        // (divider + Run Details disclosure), so one target row = 3 rows.
        let oneRowTable = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows == 1 + 2 } },
            attempts: 60)
        #expect(oneRowTable,
                "Whole-wiki lint shows exactly one scope row, never an enumeration")
        #expect(surfaceSelector(in: mounted.rootView) != nil,
                "Shared selector present for whole-wiki lint")
    }

    // MARK: - Scenario: Stop All confirmation semantics

    @Test func queueStopConfirmationSemantics() async throws {
        let mounted = try await workspace()

        // The destructive control is reachable in the REAL toolbar: the
        // Pause Queue item exists and the Queue Actions menu mounts as an
        // NSPopUpButton inside it.
        let toolbarFound = await waitUntil {
            toolbarLabels(of: mounted.window).contains("Pause Queue")
        }
        #expect(toolbarFound, "The queue's pause control must be in the toolbar")

        // The Queue Actions menu bridges as a pop-up button in the toolbar
        // item's hosted view. SwiftUI builds its NSMenu items lazily at open
        // time (opening it programmatically would block the main actor), so
        // the item list is verified only when the menu already carries items.
        let pauseItemView = mounted.window.toolbar?.items
            .first { $0.label == "Pause Queue" }?.view
        let popup = pauseItemView.flatMap { popupButtons(in: $0).first }
        if let menu = popup?.menu, !menu.items.isEmpty {
            #expect(menu.items.contains { $0.title == "Stop All…" },
                    "The Queue Actions menu must offer Stop All…")
        }

        // The confirmation's exact semantics (plan §"Stop All"): it states
        // that Stop All pauses this queue and cancels its running work. It
        // does not delete queued work, and it never implies that it does.
        // Pinned through the named constants the confirmation dialog renders.
        let title = ActivityWindowView.stopAllConfirmationTitle(for: "Agent Queue")
        #expect(title == "Stop all running work in Agent Queue?")
        let message = ActivityWindowView.stopAllConfirmationMessage
        #expect(message.contains("pauses the queue"))
        #expect(message.contains("cancels its running jobs"))
        #expect(message.contains("Queued jobs remain queued"))
        let lowered = message.lowercased()
        #expect(!lowered.contains("delete") && !lowered.contains("remove"),
                "The confirmation must not imply queued work is deleted")
        #expect(ActivityWindowView.stopAllButtonLabel == "Stop All")
    }

    // MARK: - Scenario: layout sizes

    @Test func workspaceLayoutScenariosPreferredAndMinimumSizes() async throws {
        let mounted = try await workspace()

        // Preferred size (plan §"Window behavior"): the workspace's surfaces
        // are reachable and the layout never exceeds the content width.
        let preferredSelector = await waitUntil {
            surfaceSelector(in: mounted.rootView) != nil
        }
        #expect(preferredSelector, "Workspace selector reachable at the preferred size")
        let preferredFits = mounted.rootView.fittingSize.width
            <= QueueWorkspaceMetrics.Window.preferredWidth + 1
        #expect(preferredFits,
                "Content must fit the preferred width (got \(mounted.rootView.fittingSize.width))")
        #expect(mounted.window.title == "Agent Queue")

        // Existing usability minimum (640×400): resize the SAME window — the
        // surfaces stay reachable and the layout never explodes.
        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.minWidth,
            height: QueueWorkspaceMetrics.Window.minHeight))
        await settle(6)
        let minimumSelector = await waitUntil {
            surfaceSelector(in: mounted.rootView) != nil
        }
        #expect(minimumSelector, "Workspace selector reachable at the minimum size")
        #expect(toolbarLabels(of: mounted.window).contains("Pause Queue"),
                "The pause control stays in the toolbar at the minimum size")
        let minimumFits = mounted.rootView.fittingSize.width
            <= QueueWorkspaceMetrics.Window.minWidth + 1
        #expect(minimumFits,
                "Content must fit the minimum width (got \(mounted.rootView.fittingSize.width))")

        // Accessibility: the bridgeable controls expose names — segment
        // labels on the selector, a title on the Filter popup. (The icon-only
        // row buttons carry explicit accessibility labels at the SwiftUI
        // layer — covered by the presentation-level suites.)
        let selector = try #require(
            surfaceSelector(in: mounted.rootView),
            "Selector present for the accessibility check")
        for segment in 0..<selector.segmentCount {
            #expect(!(selector.label(forSegment: segment) ?? "").isEmpty,
                    "Selector segments must be named for assistive technology")
        }
        let filterTitled = popupButtons(in: mounted.rootView)
            .contains { $0.title == "Filter" }
        #expect(filterTitled, "The Filter menu button carries a visible title")

        // Restore the preferred size for the remaining scenarios.
        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight))
        await settle(4)
    }

    // MARK: - Scenario: large inventory reachability

    @Test func largeInventoryLastTargetReachable() async throws {
        let mounted = try await workspace()
        // The completed 300-target job arrives in Recent; select it through
        // the deep-link seam. Its durable report drives the Overview.
        select(QueueItemID(rawValue: "large"), on: mounted)

        // The lazy inventory holds the FULL 300-row model — laziness never
        // truncates the recorded inventory.
        let tableFound = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows >= 300 } },
            attempts: 40)
        #expect(tableFound, "The 300-target inventory must mount")
        let inventory = try #require(
            tables(in: mounted.rootView).first { $0.numberOfRows >= 300 })
        // 300 target rows + the two trailing boundary rows (divider + Run
        // Details disclosure).
        #expect(inventory.numberOfRows == 300 + 2,
                "The full inventory is present in the list's model")

        // Local search appears at ≥ 12 rows.
        let searchable = await waitUntil {
            placeholders(in: mounted.rootView).contains("Find in Sources")
        }
        #expect(searchable, "Large inventories surface the local search field")

        // The last row is NOT materialized yet (lazy list, scrolled to top)…
        #expect(inventory.rowView(atRow: 299, makeIfNecessary: false) == nil,
                "A lazy 300-row list must not pre-materialize its last row")

        // …and becomes reachable by scrolling the list itself.
        inventory.scrollRowToVisible(299)
        let lastRowVisible = await waitUntil(
            { inventory.rowView(atRow: 299, makeIfNecessary: false) != nil },
            attempts: 40,
            label: "last inventory row")
        #expect(lastRowVisible, "The last target row must be reachable by scrolling")
    }

    // MARK: - Scenario: Run Details disclosure keeps the workspace stable

    /// Regression for the live bug: expanding Run Details blanked the center
    /// pane (the inventory List starved to zero height below the expanded
    /// disclosure) and the sidebar scrolled under the traffic lights (the
    /// workspace's unbounded height demand collapsed the window-toolbar inset
    /// from #835). Pins the disclosure expanded through the real tree (the
    /// same expanded layout the disclosure click produces) and asserts both
    /// columns' geometry stays inside the window.
    @Test func runDetailsDisclosureKeepsWorkspaceLayoutStable() async throws {
        let mounted = try await workspace()
        // The completed 300-target job: a real inventory plus recorded run
        // facts, selected through the real deep-link seam.
        select(QueueItemID(rawValue: "large"), on: mounted)
        let tableFound = await waitUntil(
            { largestTable(in: mounted.rootView)?.numberOfRows ?? 0 >= 300 },
            attempts: 40)
        #expect(tableFound, "The 300-target inventory must mount for the disclosure scenario")

        let contentTop = mounted.window.contentLayoutRect.minY

        // Baseline (collapsed): sidebar rows start below the window's content
        // layout rect — never under the traffic lights.
        if let sidebar = sidebarTable(in: mounted.rootView) {
            let frame = sidebar.convert(sidebar.bounds, to: nil)
            #expect(frame.minY >= contentTop - 1,
                    "Sidebar rows stay below the toolbar collapsed (minY \(frame.minY), content top \(contentTop))")
        }

        // Pin the disclosure expanded through the real tree. Swapping the
        // hosting controller's root value keeps the window and view identity
        // (all @State — selection, filters, transcripts — persists).
        mounted.host.rootView = ActivityWindowView(
            queue: .ingestion,
            queueEngine: mounted.client,
            activityTracker: mounted.tracker,
            sessionManager: nil,
            runDetailsPinnedExpanded: true)
        await settle(8)

        // Expanded: the inventory keeps its rows AND a finite, visible scroll
        // region — the blank-pane regression.
        let inventory = try #require(
            largestTable(in: mounted.rootView),
            "The inventory table must stay mounted with Run Details expanded")
        #expect(inventory.numberOfRows >= 300,
                "The inventory keeps its rows with Run Details expanded")
        #expect(
            inventory.bounds.height
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "Expanded Run Details must not starve the inventory (height \(inventory.bounds.height))")

        // …and the sidebar still starts below the toolbar.
        if let sidebar = sidebarTable(in: mounted.rootView) {
            let frame = sidebar.convert(sidebar.bounds, to: nil)
            #expect(frame.minY >= contentTop - 1,
                    "Sidebar rows stay below the toolbar with Run Details expanded (minY \(frame.minY), content top \(contentTop))")
        }

        // The hosted workspace itself stays inside the window vertically —
        // no unbounded demand escaping the detail column.
        let contentHeight = mounted.window.contentView?.bounds.height ?? 0
        let rootFrame = mounted.host.view.frame
        #expect(rootFrame.minY >= -1 && rootFrame.maxY <= contentHeight + 1,
                "The workspace stays inside the window (root \(rootFrame), content height \(contentHeight))")

        // Expanded details at the usability minimum (640×400): the inventory
        // keeps its floor and its rows — never a blank pane — and the sidebar
        // still starts below the titlebar.
        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.minWidth,
            height: QueueWorkspaceMetrics.Window.minHeight))
        await settle(6)
        let minimumInventory = try #require(
            largestTable(in: mounted.rootView),
            "The inventory table stays mounted at the minimum size")
        #expect(minimumInventory.numberOfRows >= 300,
                "The inventory keeps its rows at 640×400")
        #expect(
            minimumInventory.bounds.height
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "Expanded Run Details keeps the inventory visible at 640×400 (height \(minimumInventory.bounds.height))")
        if let sidebar = sidebarTable(in: mounted.rootView) {
            let frame = sidebar.convert(sidebar.bounds, to: nil)
            #expect(frame.minY >= contentTop - 1,
                    "Sidebar rows stay below the titlebar at the minimum size (minY \(frame.minY), content top \(contentTop))")
        }

        // Restore the preferred size, then lift the pin so later scenarios
        // see the production default.
        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight))
        await settle(4)
        mounted.host.rootView = ActivityWindowView(
            queue: .ingestion,
            queueEngine: mounted.client,
            activityTracker: mounted.tracker,
            sessionManager: nil)
        await settle(2)
    }

    // MARK: - Scenario: per-job overview state isolation

    /// A selection change resets the workspace's per-job Overview state
    /// (the `.id(itemID)` identity on `workspaceContent`): expanded
    /// inventory rows from one job never leak into another job's workspace,
    /// while the Overview/Activity switch itself keeps both surfaces mounted.
    /// Drives the REAL cell-hosted chevron buttons (same mechanism as the
    /// navigator row actions) and the real deep-link selection seam.
    @Test func selectionChangeResetsOverviewRowDisclosureState() async throws {
        let mounted = try await workspace()
        select(QueueItemID(rawValue: "large"), on: mounted)
        let tableFound = await waitUntil(
            { largestTable(in: mounted.rootView)?.numberOfRows ?? 0 >= 300 },
            attempts: 40)
        #expect(tableFound, "The 300-target inventory must mount for the isolation scenario")

        /// The tallest materialized target row — the observable signal that
        /// a row's disclosed detail block is showing. Re-finds the bridged
        /// table on every call: a selection change remounts the Overview
        /// (`.id(itemID)`), replacing the NSTableView.
        func tallestTargetRowHeight() -> CGFloat {
            guard let table = largestTable(in: mounted.rootView),
                  table.numberOfRows > 2 else { return 0 }
            return (0..<table.numberOfRows)
                .compactMap { table.rowView(atRow: $0, makeIfNecessary: false)?.frame.height }
                .max() ?? 0
        }

        // Expand a target row through its real cell-hosted chevron button.
        let chevron = try #require(
            await waitForInventoryChevron(in: mounted.rootView),
            "The inventory rows must host their disclosure chevron buttons")
        let collapsedHeight = tallestTargetRowHeight()
        chevron.performClick(nil)
        await settle(4)
        let expandedHeight = tallestTargetRowHeight()
        #expect(expandedHeight > collapsedHeight + 8,
                "The chevron click expands the target row (collapsed \(collapsedHeight), expanded \(expandedHeight))")

        // Switch to another job and back through the real selection seam:
        // the Overview's per-job state reset, so the row is collapsed again.
        select(Self.running.id, on: mounted)
        let switched = await waitUntil(
            { largestTable(in: mounted.rootView)?.numberOfRows == 15 + 2 },
            attempts: 40,
            label: "switched job inventory")
        #expect(switched, "Selecting the other job remounts its inventory")
        select(QueueItemID(rawValue: "large"), on: mounted)
        let back = await waitUntil(
            { largestTable(in: mounted.rootView)?.numberOfRows ?? 0 >= 300 },
            attempts: 40,
            label: "re-selected job inventory")
        #expect(back, "Selecting the first job back remounts its inventory")
        let afterResetHeight = tallestTargetRowHeight()
        #expect(afterResetHeight <= collapsedHeight + 2,
                "Per-job state resets on selection change — the expanded row must not leak across jobs (got \(afterResetHeight), collapsed baseline \(collapsedHeight))")
    }

    /// Bounded wait for an inventory row's chevron button: a real NSButton
    /// in a List row cell (detail column), labeled "Show details for …".
    private func waitForInventoryChevron(in root: NSView) async -> NSButton? {
        for _ in 0..<30 {
            if let button = inventoryChevronButtons(in: root).first {
                return button
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return inventoryChevronButtons(in: root).first
    }

    private func inventoryChevronButtons(in root: NSView) -> [NSButton] {
        // The inventory rows' chevron buttons: cell-hosted buttons in the
        // DETAIL column — at or right of the navigator table's trailing
        // edge. SwiftUI's accessibility labels do not bridge onto these
        // NSButtons, so position (not label) is the reliable disambiguator.
        // The Run Details disclosure's own toggle is the List's trailing
        // row, below the lazy fold at these fixture sizes, so the visible
        // detail-column cell buttons are the target rows' chevrons.
        guard let sidebar = sidebarTable(in: root) else { return [] }
        let columnMaxX = sidebar.convert(sidebar.bounds, to: nil).maxX
        return allSubviews(of: root).compactMap { $0 as? NSButton }.filter { button in
            guard isInListRowCell(button) else { return false }
            return button.convert(button.bounds, to: nil).minX >= columnMaxX
        }
    }
}

// MARK: - Scripted engine

/// A `QueueEngineClient` that serves a MUTABLE snapshot plus per-item
/// reports, and records every command the workspace invokes — the hosted
/// scenarios' engine side. ``update(snapshot:)`` swaps the served snapshot
/// and yields a `.runStateChanged` event so the view model refreshes through
/// the real event path.
private final class ScriptedQueueEngineClient: QueueEngineClient, @unchecked Sendable {
    private let currentSnapshot: Mutex<QueueSnapshot>
    private let reports: [QueueItem.ID: QueueReportLoadResult]
    private let eventContinuation: AsyncStream<QueueEvent>.Continuation
    private let commandLog = Mutex<[String]>([])
    private let stream: AsyncStream<QueueEvent>
    private let summaries: [QueueItem.ID: QueueReportSummary]

    /// Commands invoked by the hosted view, in order ("cancelItem:<id>").
    var recordedCommands: [String] {
        commandLog.withLock { $0 }
    }

    private func record(_ command: String) {
        commandLog.withLock { $0.append(command) }
    }

    init(
        snapshot: QueueSnapshot,
        reports: [QueueItem.ID: QueueReportLoadResult] = [:],
        summaries: [QueueItem.ID: QueueReportSummary] = [:]
    ) {
        self.currentSnapshot = Mutex(snapshot)
        self.reports = reports
        self.summaries = summaries
        (stream, eventContinuation) = AsyncStream<QueueEvent>.makeStream()
    }

    /// Swap the served snapshot and nudge subscribers through the event path.
    func update(snapshot: QueueSnapshot) {
        currentSnapshot.withLock { $0 = snapshot }
        eventContinuation.yield(.runStateChanged(queue: .ingestion, state: .running))
    }

    var events: AsyncStream<QueueEvent> { stream }

    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID {
        record("enqueue")
        return QueueItemID(rawValue: "unused")
    }

    func cancelItem(_ id: QueueItem.ID) async throws {
        record("cancelItem:\(id.rawValue)")
    }

    func cancelAllInFlight() async throws -> Int {
        record("cancelAllInFlight")
        return 0
    }

    func retryItem(_ id: QueueItem.ID) async throws {
        record("retryItem:\(id.rawValue)")
    }

    func pause(_ queue: QueueKind) async throws {
        record("pause:\(queue)")
    }

    func resume(_ queue: QueueKind) async throws {
        record("resume:\(queue)")
    }

    func halt(_ queue: QueueKind) async throws {
        record("halt:\(queue)")
    }

    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async throws {
        record("reorderItem:\(id.rawValue)")
    }

    func snapshot() async throws -> QueueSnapshot {
        currentSnapshot.withLock { $0 }
    }

    func hasActiveWork(for wikiID: WikiID) async throws -> Bool { false }

    func waitForCompletion(of id: QueueItem.ID) async throws -> Result<Void, Error> {
        .success(())
    }

    func loadTranscript(for itemID: QueueItem.ID) async throws -> [ChatTranscriptItem] { [] }

    func loadAllActivitySnapshots() async throws -> [QueueItem.ID: QueueEngine.ActivitySnapshot] {
        [:]
    }

    func loadQueueReport(for itemID: QueueItem.ID) async -> QueueReportLoadResult {
        reports[itemID] ?? .notReported
    }

    func loadQueueReportSummaries(for itemIDs: [QueueItem.ID]) async -> QueueReportSummariesResult {
        .loaded(summaries)
    }
}
#endif
