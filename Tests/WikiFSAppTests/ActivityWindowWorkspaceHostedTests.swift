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
/// - the toolbar's remaining Run Details control,
/// - the segmented Overview/Activity selector (`NSSegmentedControl` labels),
/// - the navigator's Filter popup button (real title),
/// - editable `NSTextField`s — the Overview's local search placeholder
///   ("Find in Inputs" / "Find in Pages"), the workspace's kind-specific
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
        // The test helper runs as an accessory-policy app. When a scenario
        // ends with no active field editor (the toolbar search no longer
        // re-focuses on a resize-driven expansion, per M-2), AppKit's
        // automatic termination decides the idle process should exit and
        // calls exit(0) — silently killing the runner BEFORE swift-testing
        // flushes its results. disableAutomaticTermination alone is not
        // enough because AppKit's own enable/disable calls are refcounted
        // and re-enable termination mid-run; a userInitiated activity
        // assertion holds for the suite's whole lifetime.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "hosted Activity window scenarios")
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "hosted Activity window scenarios")
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

    /// An extraction job sharing the served snapshot. Extraction has its own
    /// window: this job must NEVER surface in the Agent Queue's navigator —
    /// the strict window-scope filter (`ActivityWindowView.windowContains`)
    /// is asserted by the `agentQueueNeverListsExtractionJobs` scenario.
    private static let extractionJob = QueueItem(
        id: QueueItemID(rawValue: "shared-extraction"),
        queue: .extraction,
        wikiID: WikiID(rawValue: "workspace-wiki"),
        payload: QueueItemPayload(
            sourceIDs: (0..<5).map { SourceID(rawValue: "xs\($0)") }),
        state: .running,
        orderingKey: 500,
        attempt: 0,
        createdAt: 0,
        startedAt: Int64(Date().timeIntervalSince1970 * 1000) - 30_000)

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
    /// state-transitioned variant of itself (the action scenarios). Always
    /// carries the extraction job alongside the ingestion jobs.
    private static func fixtures(
        runningVariant: QueueItem? = nil
    ) -> QueueSnapshot {
        QueueSnapshot(
            activeItems: [runningVariant ?? running, lintPages, wholeWiki, extractionJob],
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
            sessionManager: nil,
            // Closed-wiki name resolution stays hermetic here: the fixtures
            // have no real wiki database, so the read-only fallback load
            // must not touch the production App Group container.
            closedWikiDatabaseURLProvider: { _ in nil })
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight))
        // AppKit's window-restoration machinery reacts to the scenario's
        // resize/restore churn by rebuilding window UI state; in the test
        // helper that path has been observed to terminate the process
        // mid-run. The suite drives every size explicitly — opt this window
        // out of restoration entirely.
        window.isRestorable = false
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
    /// List also hosts cell-backed buttons (the target-row name links), and
    /// at the sidebar's ideal width those sit under any constant bound.
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

    /// Toolbar item labels used to verify removed controls stay absent.
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
        // Overview/Activity selector, and the Run Details toolbar toggle.
        // Queue controls live in the navigator header; value tests pin their
        // labels because SwiftUI buttons do not bridge reliably in this host.
        let selectorFound = await waitUntil {
            surfaceSelector(in: mounted.rootView) != nil
        }
        #expect(selectorFound, "The Overview/Activity selector must be visible")
        #expect(mounted.window.title == "Agent Queue")
        let toolbarLabels = toolbarLabels(of: mounted.window)
        #expect(!toolbarLabels.contains("Queue Actions"),
                "Queue Actions must not remain in the toolbar")
        // The Run Details toggle is an ICON-ONLY toolbar control (design
        // change 7, now a plain SwiftUI Button — design change 12): its
        // accessibility label is the name VoiceOver reads. SwiftUI re-derives
        // item labels asynchronously, so the customization-palette name is
        // not mount-time observable and not asserted here.
        let runDetailsPresent = await waitUntil {
            runDetailsToggleContent(in: mounted.window) != nil
        }
        #expect(runDetailsPresent,
                "The Run Details inspector toggle must be a visible toolbar control")
        // (The toolbar ITEM label "Run Details" — the customization-palette
        // name the coordinator re-asserts — is written on a later runloop
        // tick and SwiftUI re-derives item labels asynchronously, so it is
        // not mount-time observable and not asserted here.)
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
        #expect(!toolbarLabels(of: mounted.window).contains("Queue Actions"),
                "Queue actions stay out of the toolbar")
    }

    // MARK: - Scenario: one shared workspace across operations
    //
    // Kind-specific language asserted through the Overview's local-search
    // placeholder — the bridgeable surface where "Inputs" vs "Pages"
    // reaches AppKit. Jobs are selected through the deep-link seam.

    @Test func sharedWorkspaceAcrossOperationsIngestUsesInputsLanguage() async throws {
        let mounted = try await workspace()
        select(Self.running.id, on: mounted)
        let ingestSearch = await waitUntil {
            placeholders(in: mounted.rootView).contains("Find in Inputs")
        }
        #expect(ingestSearch, "Ingestion batches surface 'Find in Inputs'")
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
        #expect(placeholders(in: mounted.rootView).contains("Find in Inputs") == false,
                "The lint workspace never claims the ingestion inputs language")
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
        // marker. The workspace never enumerates the wiki's pages.
        let oneRowTable = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows == 1 } },
            attempts: 60)
        #expect(oneRowTable,
                "Whole-wiki lint shows exactly one scope row, never an enumeration")
        #expect(surfaceSelector(in: mounted.rootView) != nil,
                "Shared selector present for whole-wiki lint")
    }

    // MARK: - Scenario: Stop All confirmation semantics

    @Test func queueStopConfirmationSemantics() async throws {
        let mounted = try await workspace()

        #expect(!toolbarLabels(of: mounted.window).contains("Queue Actions"),
                "Separate queue controls replace the toolbar menu")

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
        #expect(!toolbarLabels(of: mounted.window).contains("Queue Actions"),
                "Queue actions stay in the sidebar at the minimum size")
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

    // MARK: - Scenario: trailing Run Details toolbar control

    /// The Run Details toggle stays at the trailing toolbar edge after the
    /// queue controls move into the navigator. At the preferred size and the
    /// 640×400 usability minimum:
    /// - the icon control remains hosted with a visible frame;
    /// - Queue Actions is absent from the toolbar;
    /// - the Run Details NSButton's real frame carries the shared toolbar
    ///   icon-button width (`Toolbar.iconButtonSide`, 28pt — the main
    ///   window's standard toolbar Button metrics) instead of the bare
    ///   glyph footprint an unsized borderless button collapses to, with
    ///   the toolbar row imposing its hosted height above the square;
    /// - the Run Details toggle still opens and closes the inspector at
    ///   640×400.
    ///
    /// Runs ungated: unlike the search-field scenarios it touches no field
    /// editor — the sandbox runner-session hazard is specific to live
    /// search-editing churn (see the suite header).
    @Test(.timeLimit(.minutes(1)))
    func runDetailsToolbarControlPinnedRightVisibleAndToggling() async throws {
        let mounted = try await workspace()

        // A completed job selected through the deep-link seam so the Run
        // Details toggle has facts to show when clicked at 640×400.
        select(QueueItemID(rawValue: "large"), on: mounted)
        let inventoryReady = await waitUntil(
            { largestTable(in: mounted.rootView)?.numberOfRows ?? 0 >= 300 },
            attempts: 40)
        #expect(inventoryReady, "Preamble: the selected job's inventory mounts")

        // Preferred size first, then the usability minimum: BOTH widths must
        // keep the icon group hosted, ordered, and out of the overflow.
        for (width, height) in [
            (QueueWorkspaceMetrics.Window.preferredWidth,
             QueueWorkspaceMetrics.Window.preferredHeight),
            (QueueWorkspaceMetrics.Window.minWidth,
             QueueWorkspaceMetrics.Window.minHeight),
        ] {
            mounted.window.setContentSize(NSSize(width: width, height: height))
            await settle(6)
            let sizeNote = "\(width)×\(height)"

            #expect(!toolbarLabels(of: mounted.window).contains("Queue Actions"),
                    "Queue Actions stays out of the toolbar at \(sizeNote)")
            let runDetails = try #require(
                await waitForRunDetailsToggle(in: mounted.window),
                "Run Details stays a hosted toolbar control at \(sizeNote)")

            // Hosted, not overflowed: the control renders with a real frame
            // pinned to the window's trailing edge.
            let contentWidth = mounted.window.contentView?.bounds.width ?? width
            let detailsFrame = runDetails.convert(runDetails.bounds, to: nil)
            #expect(detailsFrame.width > 0,
                    "Run Details renders with a real frame at \(sizeNote) (got \(detailsFrame))")
            #expect(detailsFrame.maxX >= contentWidth - 80,
                    "Run Details pins to the trailing edge at \(sizeNote) (maxX \(detailsFrame.maxX) of \(contentWidth))")

            // Sized to the shared toolbar icon-button square (28pt — the
            // main window's standard toolbar Button metrics): the image
            // carries the shared square as its frame, so the bridged
            // control measures the square and the glyph lands centered
            // within it. Measured 23.5×18.5 (the bare glyph footprint)
            // before the frame assist — the squish the former representable
            // fixed, back without it.
            let side = QueueWorkspaceMetrics.Toolbar.iconButtonSide
            #expect(((side - 2)...(side + 16)).contains(detailsFrame.width)
                    && ((side - 2)...(side + 8)).contains(detailsFrame.height),
                    "Run Details renders at the toolbar icon-button square \(side)×\(side) at \(sizeNote) (got \(detailsFrame))")

            // Icon-only Run Details with its identity intact (design
            // change 12): the trailing item hosts no text — the
            // "sidebar.right" glyph carries the rendering, and the
            // accessibility label/tooltip live in the SwiftUI layer (not
            // NSView-readable in this host — suite header).
            if let lastView = mounted.window.toolbar?.items.last?.view {
                #expect(allSubviews(of: lastView).first(where: { $0 is NSTextField }) == nil,
                        "Run Details renders icon-only at \(sizeNote)")
            }

            // Search and queue actions belong to the navigator. Run Details is
            // the only custom control that remains in the toolbar.
            let toolbarHasSearch = (mounted.window.toolbar?.items ?? []).contains { item in
                guard let view = item.view else { return false }
                return allSubviews(of: view).contains { $0 is NSSearchField }
            }
            #expect(!toolbarHasSearch,
                    "Search stays out of the toolbar at \(sizeNote)")
            #expect(!toolbarLabels(of: mounted.window).contains("Queue Actions"),
                    "Queue Actions stays out of the toolbar at \(sizeNote)")
        }

        // The window is at 640×400 here. The toggle still works: pressing it
        // mounts the inspector's facts table (7 rows for the `large`
        // fixture) — the @State seam, observable through the facts table —
        // and flipping it back with `.help` swaps the tooltip text
        // ("Show Run Details" ↔ "Hide Run Details"); pressing again closes
        // the panel. (The center inventory's width is NOT the close signal
        // at this size: with the inspector closed the navigator re-expands
        // and keeps the reclaimed width, so no width-growth signal exists —
        // the facts table unmount is the honest state read.)
        _ = try #require(
            await waitForRunDetailsToggle(in: mounted.window),
            "Run Details reachable for the toggle check")
        #expect(pressRunDetailsToggle(in: mounted.window),
                "Run Details pressable at 640×400")
        let factsMounted = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows == 7 } },
            label: "inspector facts table at minimum size")
        #expect(factsMounted,
                "The toggle still opens the Run Details inspector at 640×400")
        #expect(pressRunDetailsToggle(in: mounted.window),
                "Run Details pressable for the close check")
        let inspectorClosed = await waitUntil({
            !tables(in: mounted.rootView).contains { $0.numberOfRows == 7 }
        }, label: "inspector facts table unmounts")
        #expect(inspectorClosed,
                "Closing the toggle removes the inspector's facts table")

        // Restore the preferred size for the remaining scenarios.
        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight))
        await settle(4)
    }

    // MARK: - Scenario: sidebar job search

    /// Search stays out of the toolbar after it moves into the navigator.
    /// The navigator controls and job rows remain usable at minimum width.
    @Test(.timeLimit(.minutes(1)))
    func sidebarSearchPlacementAndMinimumWidth() async throws {
        let mounted = try await workspace()

        let toolbarHasSearch = (mounted.window.toolbar?.items ?? []).contains { item in
            guard let view = item.view else { return false }
            return allSubviews(of: view).contains { $0 is NSSearchField }
        }
        #expect(!toolbarHasSearch, "The window toolbar does not host job search")

        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.minWidth,
            height: QueueWorkspaceMetrics.Window.minHeight))
        await settle(4)

        let filterReachable = await waitUntil {
            popupButtons(in: mounted.rootView).contains { $0.title == "Filter" }
        }
        #expect(filterReachable, "The navigator filter remains reachable below search")

        let rowsReachable = await waitUntil {
            (sidebarTable(in: mounted.rootView)?.numberOfRows ?? 0) >= 6
        }
        #expect(rowsReachable, "Navigator rows remain reachable at minimum width")

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

        // The lazy inventory holds the FULL 300-row input model — laziness
        // never truncates the recorded inventory.
        let tableFound = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows >= 300 } },
            attempts: 40)
        #expect(tableFound, "The 300-target inventory must mount")
        let inventory = try #require(
            tables(in: mounted.rootView).first { $0.numberOfRows >= 300 })
        // The list carries the 300 input rows PLUS the ingestion Outputs
        // section in the same list (fa843ebd): the section's bridged header
        // row and one honest status row — the section renders exactly one
        // trailing row in every outputs state (loading / failed / resolved
        // empty), and this fixture mounts no store, so the load honestly
        // reports it couldn't load. Run Details itself lives in the
        // inspector panel now, not as trailing rows.
        let expectedRows = 302
        #expect(inventory.numberOfRows == expectedRows,
                "The full inventory is present: 300 inputs + Outputs header + outputs status row (got \(inventory.numberOfRows))")

        // Local search appears at ≥ 12 rows.
        let searchable = await waitUntil {
            placeholders(in: mounted.rootView).contains("Find in Inputs")
        }
        #expect(searchable, "Large inventories surface the local search field")

        // The last row is NOT materialized yet (lazy list, scrolled to top;
        // row 299 is the last input row — the Outputs rows trail at 300–301)…
        #expect(inventory.rowView(atRow: 299, makeIfNecessary: false) == nil,
                "A lazy list must not pre-materialize its last input row")

        // …and becomes reachable by scrolling the list itself.
        inventory.scrollRowToVisible(299)
        let lastRowVisible = await waitUntil(
            { inventory.rowView(atRow: 299, makeIfNecessary: false) != nil },
            attempts: 40,
            label: "last inventory row")
        #expect(lastRowVisible, "The last target row must be reachable by scrolling")
    }

    // MARK: - Scenario: Run Details inspector (optional, toolbar-toggled)

    /// The Run Details inspector is an optional trailing panel opened/closed
    /// by the REAL toolbar toggle (a plain SwiftUI Button — design change
    /// 10). Drives the bridged control end to end through the accessibility
    /// press / state seam:
    /// - clicking "Run Details" mounts the inspector, whose facts list
    ///   bridges as a table with EXACTLY the job's `QueueRunDetailsFacts`
    ///   entry rows (same public omission rules the window applies);
    /// - the CENTER inventory stays mounted, full-row, and above its visible
    ///   height floor while the inspector is open (the blank-pane regression
    ///   the disclosure-era test pinned);
    /// - closing the inspector changes NOTHING else: the same job stays
    ///   selected (its inventory and local search remain) and the engine
    ///   receives no commands (queue state untouched);
    /// - at the usability minimum (640×400) WITH THE INSPECTOR OPEN, the
    ///   facts table stays mounted, the inventory keeps its visible height
    ///   floor, and the workspace stays inside the window.
    ///
    /// The unmount is observed through the CENTER COLUMN's live geometry:
    /// when the 280pt inspector panel unmounts, the workspace's inventory
    /// reclaims that width. (Table *existence* is not a reliable unmount
    /// signal — AppKit-backed SwiftUI retains retired List tables in the
    /// view tree with stale frames.)
    @Test func runDetailsInspectorToggleKeepsCenterInventoryVisible() async throws {
        let mounted = try await workspace()
        // The completed 300-target job: a real inventory plus recorded run
        // facts, selected through the real deep-link seam.
        select(QueueItemID(rawValue: "large"), on: mounted)
        let tableFound = await waitUntil(
            { largestTable(in: mounted.rootView)?.numberOfRows ?? 0 >= 300 },
            attempts: 40)
        #expect(tableFound, "The 300-target inventory must mount for the inspector scenario")

        let commandsBefore = mounted.client.recordedCommands.count

        // Open: press the REAL toolbar toggle (the bridged SwiftUI control).
        _ = try #require(
            await waitForRunDetailsToggle(in: mounted.window),
            "The Run Details toolbar toggle must bridge to a pressable control")
        #expect(pressRunDetailsToggle(in: mounted.window),
                "The Run Details toolbar toggle must be pressable")
        await settle(8)

        // The inspector's facts list mounts as a bridged table with a
        // LITERAL row count (test integrity: a count recomputed from
        // `QueueRunDetailsFacts.entries` would pass even if `entries`
        // dropped a row). For the `large` fixture the window's mapping
        // yields exactly seven rows: Job ID (the item's raw ULID — present
        // for every job), Enqueued, Started, Finished (the epoch-ms
        // 0 timestamps still count as present), Duration; attempt 0 is
        // omitted; the report header has no provider/model and no usage
        // snapshot exists (recorded or live), so their resolution falls
        // through to the two "Not Reported" placeholders and NO usage rows
        // render (usage is one labeled row per PRESENT field — Input,
        // Output, Cached, Thought, Cost — and a zero/absent field never
        // renders). The omission rules themselves are covered at value
        // level in `QueueWorkspacePresentationTests`.
        let expectedFactRows = 7
        let inspectorMounted = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows == expectedFactRows } },
            label: "inspector facts table")
        #expect(inspectorMounted,
                "The inspector must mount the job's run facts (\(expectedFactRows) rows)")

        // The CENTER inventory remains visible while the inspector is open.
        let inventory = try #require(
            largestTable(in: mounted.rootView),
            "The inventory table must stay mounted with the inspector open")
        #expect(inventory.numberOfRows >= 300,
                "The inventory keeps its rows with the inspector open")
        #expect(
            inventory.bounds.height
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "The open inspector must not starve the inventory (height \(inventory.bounds.height))")

        // Close: the inspector unmounts and NOTHING else changes — same job
        // selected (inventory + local search remain), no engine commands.
        _ = try #require(
            await waitForRunDetailsToggle(in: mounted.window),
            "The Run Details toolbar toggle must stay reachable after re-render")
        #expect(pressRunDetailsToggle(in: mounted.window),
                "The Run Details toolbar toggle must stay pressable after re-render")
        let widthWithInspectorOpen = inventory
            .convert(inventory.bounds, to: nil).width
        let inspectorGone = await waitUntil({
            let current = largestTable(in: mounted.rootView)
            guard let current else { return false }
            let width = current.convert(current.bounds, to: nil).width
            return width
                >= widthWithInspectorOpen + QueueWorkspaceMetrics.Inspector.width - 20
        }, label: "inspector unmount (center widens)")
        #expect(inspectorGone, "Closing the toggle must remove the inspector")
        let inventoryAfterClose = try #require(
            largestTable(in: mounted.rootView),
            "The inventory must stay mounted after closing the inspector")
        #expect(inventoryAfterClose.numberOfRows >= 300,
                "Closing the inspector must not change the selection — the same job's inventory stays")
        #expect(placeholders(in: mounted.rootView).contains("Find in Inputs"),
                "The same job's Overview (its local search) stays after closing")
        #expect(mounted.client.recordedCommands.count == commandsBefore,
                "Toggling the inspector must not run queue commands")

        // Minimum size (640×400) WITH THE INSPECTOR OPEN: re-open the
        // inspector first, then resize. The facts table stays mounted, the
        // inventory keeps its rows and its visible height floor, and the
        // workspace stays inside the window.
        _ = try #require(
            await waitForRunDetailsToggle(in: mounted.window),
            "The Run Details toolbar toggle must be reachable for the minimum-size pass")
        #expect(pressRunDetailsToggle(in: mounted.window),
                "The Run Details toolbar toggle must be pressable for the minimum-size pass")
        await settle(4)
        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.minWidth,
            height: QueueWorkspaceMetrics.Window.minHeight))
        await settle(6)
        let minimumFactsMounted = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows == expectedFactRows } },
            label: "inspector facts table at minimum size")
        #expect(minimumFactsMounted,
                "The facts table stays mounted at 640×400 with the inspector open")
        let minimumInventory = try #require(
            largestTable(in: mounted.rootView),
            "The inventory table stays mounted at the minimum size")
        #expect(minimumInventory.numberOfRows >= 300,
                "The inventory keeps its rows at 640×400")
        #expect(
            minimumInventory.bounds.height
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "The inventory stays visible at 640×400 (height \(minimumInventory.bounds.height))")
        let contentHeight = mounted.window.contentView?.bounds.height ?? 0
        let rootFrame = mounted.host.view.frame
        #expect(rootFrame.minY >= -1 && rootFrame.maxY <= contentHeight + 1,
                "The workspace stays inside the window (root \(rootFrame), content height \(contentHeight))")

        // Restore the preferred size and close the inspector so the later
        // scenarios start from the suite's default presentation.
        mounted.window.setContentSize(NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight))
        await settle(4)
        _ = try #require(
            await waitForRunDetailsToggle(in: mounted.window),
            "The Run Details toolbar toggle must stay reachable after the minimum-size pass")
        #expect(pressRunDetailsToggle(in: mounted.window),
                "The Run Details toolbar toggle must stay pressable after the minimum-size pass")
        await settle(4)
    }

    // MARK: - Run Details toggle seam (design change 12)

    /// The Run Details toggle's clickable content: the trailing toolbar item
    /// hosts the bridged SwiftUI `Button`, whose image carries the shared
    /// ``QueueWorkspaceMetrics/Toolbar/iconButtonSide`` square — the one
    /// ≈28pt-wide view in the item's tree.
    ///
    /// Why this seam: the hosted tree carries NO NSButton (verified:
    /// ToolbarItemHostingView → ContainerView → FocusRing/KeyView proxies),
    /// so `performClick` and NSView-level accessibility probes cannot reach
    /// the control, and the system AX API is unavailable in this harness
    /// (attribute reads return api-disabled without an Accessibility TCC
    /// grant — verified). The harness therefore (a) reads the
    /// geometry-parity frame from the square-sized content view and (b)
    /// drives the toggle with synthesized mouse events at that frame's
    /// center — the real event path a user's click takes. The "Run Details"
    /// accessibility label and the flipping `.help` tooltip are set in the
    /// view code (SwiftUI surfaces both to VoiceOver in the real app) but
    /// are not NSView-level readable here (see the suite header).
    private func runDetailsToggleContent(in window: NSWindow) -> NSView? {
        guard let trailing = window.toolbar?.items.last?.view else { return nil }
        let side = QueueWorkspaceMetrics.Toolbar.iconButtonSide
        return allSubviews(of: trailing).first { sub in
            let frame = sub.convert(sub.bounds, to: nil)
            return ((side - 2)...(side + 16)).contains(frame.width)
                && ((side - 2)...(side + 16)).contains(frame.height)
        }
    }

    /// Bounded wait because SwiftUI materializes the item's hosted view
    /// asynchronously after mount.
    private func waitForRunDetailsToggle(in window: NSWindow) async -> NSView? {
        for _ in 0..<30 {
            if let content = runDetailsToggleContent(in: window) { return content }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return runDetailsToggleContent(in: window)
    }

    /// Press the toggle with a synthesized mouse click at its content
    /// frame's center — the real event path. The state seam itself (the
    /// inspector's facts table mounting/unmounting) stays the honest
    /// assertion — a press that flips nothing fails the scenario's waits.
    @discardableResult
    private func pressRunDetailsToggle(in window: NSWindow) -> Bool {
        guard let content = runDetailsToggleContent(in: window) else { return false }
        let bounds = content.convert(content.bounds, to: nil)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
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

    // MARK: - Scenario: inventory rows are non-collapsible name links

    /// The inventory rows carry no disclosure control: the target NAME is
    /// the clickable link (native `.link` style) performing the row's
    /// navigation action. Selects the whole-wiki lint job — its one scope
    /// row's "Browse Pages" action is the one action the hosted tree can
    /// resolve without a live session (name-resolution-dependent page/source
    /// actions stay covered by the row-level hosted suite) — and drives the
    /// REAL cell-hosted button. With no session the click logs and no-ops
    /// (safe by design); the assertions pin that the link EXISTS in the row
    /// cell and the click neither wedges the window nor disturbs state.
    @Test func inventoryNameIsTheClickableLink() async throws {
        let mounted = try await workspace()
        select(QueueItemID(rawValue: "shared-whole"), on: mounted)
        let oneRow = await waitUntil(
            { tables(in: mounted.rootView).contains { $0.numberOfRows == 1 } },
            attempts: 60)
        #expect(oneRow, "The whole-wiki job's scope row must mount")

        let link = try #require(
            await waitForInventoryLinkButton(in: mounted.rootView),
            "The target row's name must host a clickable link button")
        let commandsBefore = mounted.client.recordedCommands.count
        link.performClick(nil)
        await settle(4)
        // The link routes navigation only: no engine command, selection
        // unchanged (the same one-row scope inventory stays).
        #expect(mounted.client.recordedCommands.count == commandsBefore,
                "The name link must not run queue commands")
        #expect(
            tables(in: mounted.rootView).contains { $0.numberOfRows == 1 },
            "The same job's inventory stays after the link click")
    }

    /// Bounded wait for an inventory row's name-link button: a real NSButton
    /// in a List row cell (detail column), at or right of the navigator
    /// table's trailing edge.
    private func waitForInventoryLinkButton(in root: NSView) async -> NSButton? {
        for _ in 0..<30 {
            if let button = inventoryLinkButtons(in: root).first {
                return button
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return inventoryLinkButtons(in: root).first
    }

    /// The inventory rows' name-link buttons: cell-hosted buttons in the
    /// DETAIL column — at or right of the navigator table's trailing edge.
    /// SwiftUI's accessibility labels do not bridge onto these NSButtons, so
    /// position (not label) is the reliable disambiguator.
    private func inventoryLinkButtons(in root: NSView) -> [NSButton] {
        guard let sidebar = sidebarTable(in: root) else { return [] }
        let columnMaxX = sidebar.convert(sidebar.bounds, to: nil).maxX
        return allSubviews(of: root).compactMap { $0 as? NSButton }.filter { button in
            guard isInListRowCell(button) else { return false }
            return button.convert(button.bounds, to: nil).minX >= columnMaxX
        }
    }

    // MARK: - Scenario: strict queue scope (extraction never in Agent Queue)

    /// Extraction has its own window: an extraction job in the shared
    /// snapshot must never surface in the Agent Queue's navigator. The
    /// fixture snapshot already carries one extraction job; this adds a
    /// SECOND one through the real event path and pins that the navigator's
    /// bridged row count does not change (differential, so section-header
    /// bridging details cannot skew the count).
    @Test func agentQueueNeverListsExtractionJobs() async throws {
        let mounted = try await workspace()
        let sidebarBefore = try #require(
            sidebarTable(in: mounted.rootView),
            "The navigator table must be mounted")
        let rowsBefore = sidebarBefore.numberOfRows

        let extraExtraction = QueueItem(
            id: QueueItemID(rawValue: "extra-extraction"),
            queue: .extraction,
            wikiID: WikiID(rawValue: "workspace-wiki"),
            payload: QueueItemPayload(
                sourceIDs: (0..<3).map { SourceID(rawValue: "ys\($0)") }),
            state: .running,
            orderingKey: 100,
            attempt: 0,
            createdAt: 0,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000) - 5_000)
        mounted.client.update(snapshot: QueueSnapshot(
            activeItems: [Self.running, Self.lintPages, Self.wholeWiki, Self.extractionJob, extraExtraction],
            recentItems: [Self.large],
            runStates: [.ingestion: .running]))
        await settle(6)

        let sidebarAfter = try #require(
            sidebarTable(in: mounted.rootView),
            "The navigator table must stay mounted")
        #expect(sidebarAfter.numberOfRows == rowsBefore,
                "Extraction jobs must never appear in the Agent Queue navigator (rows \(rowsBefore) → \(sidebarAfter.numberOfRows))")
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
