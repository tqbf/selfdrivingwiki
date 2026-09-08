#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
import WikiFSCore

/// Focused hosted-layout regression for the Run Details disclosure bug:
/// the disclosure rides INSIDE the inventory List (as its trailing rows),
/// so expanding it grows scrollable content instead of contesting a
/// non-scrolling sibling for height — the contest starved the inventory
/// List to zero height (blank center pane) and pushed the workspace past
/// the window, which collapsed the sidebar's window-toolbar inset (sidebar
/// rows scrolling under the traffic lights).
///
/// Hosts the REAL `QueueJobOverviewView` (production component, real
/// List→NSTableView bridging) at the workspace's preferred and minimum
/// window heights, collapsed vs expanded. Expansion is pinned through the
/// `queueRunDetailsPinnedExpanded` environment override — the same expanded
/// layout the disclosure's own toggle produces. The geometry assertions:
/// - the inventory table always keeps a finite, visible height (≥ the floor
///   `QueueWorkspaceMetrics.Inventory.minVisibleHeight`) — the blank-pane
///   regression;
/// - the disclosure's own row is short when collapsed and tall-but-bounded
///   when expanded (≤ the ceiling plus its label row) — expansion is real
///   and scrollable, not skipped and not unbounded.
///
/// Suite discipline mirrors the other hosted suites: serialized,
/// time-limited, one gated window at a time, bounded settle loops with
/// cooperative `Task.sleep`.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct QueueOverviewLayoutHostedTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    /// The measured geometry of one hosted configuration.
    struct LayoutMeasurement: Sendable {
        var inventoryHeight: CGFloat
        var disclosureRowHeight: CGFloat
    }

    /// A presentation shaped like a real completed ingestion job: a
    /// multi-target inventory (local search surfaces at ≥ 12 rows) plus every
    /// Run Details fact recorded, so the expanded disclosure carries the
    /// tallest realistic grid.
    private static func presentation(rowCount: Int = 40) -> QueueJobOverviewPresentation {
        let rows = (0..<rowCount).map { index in
            QueueTargetRowValue(
                identity: .source(SourceID(rawValue: "layout-source-\(index)")),
                title: String(format: "Source-%03d.pdf", index),
                status: .planned())
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return QueueJobOverviewPresentation(
            sectionTitle: "Sources",
            countText: String(rowCount),
            rows: rows,
            resultStatement: "3 submitted",
            runDetails: QueueRunDetailsFacts(
                enqueuedAt: start,
                startedAt: start.addingTimeInterval(2),
                finishedAt: start.addingTimeInterval(92),
                durationText: "1m 30s",
                attempt: 1,
                providerText: "anthropic",
                modelText: "claude-sonnet-4-6",
                usageLines: ["12,345 tokens · $0.0421"]),
            emptyStateText: "No sources recorded for this job.")
    }

    /// Host the Overview at `size`, expanded or collapsed, and measure the
    /// bridged inventory table's height plus the disclosure row's height
    /// (the List's trailing row, materialized by scrolling to it) after the
    /// layout settles.
    private func measureOverview(
        expanded: Bool,
        size: NSSize
    ) async throws -> LayoutMeasurement {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        defer { lease.release() }

        let root = QueueJobOverviewView(Self.presentation())
            .environment(\.queueRunDetailsPinnedExpanded, expanded)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // Wait for the inventory List to bridge to its NSTableView.
        // `Task.sleep` throws only on cancellation; propagate it (`try`, not
        // `try?`) so a cancelled test — e.g. the suite's `.timeLimit` — fails
        // loudly instead of silently swallowing the error and spinning out
        // the remaining attempts (same convention as
        // `PageDetailViewHostedTests`). The defers above still release the
        // gate lease and order out the window on that exit path.
        var table: NSTableView?
        for _ in 0..<30 {
            table = firstTableView(in: host.view)
            if table != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let inventory = try #require(
            table,
            "expanded=\(expanded): the inventory List must mount its table view")
        // Settle, then materialize the trailing (disclosure) row and measure.
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(50)) }
        let lastRow = inventory.numberOfRows - 1
        inventory.scrollRowToVisible(lastRow)
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(50)) }
        let disclosureRow = try #require(
            inventory.rowView(atRow: lastRow, makeIfNecessary: true),
            "expanded=\(expanded): the disclosure row must materialize")
        return LayoutMeasurement(
            inventoryHeight: inventory.bounds.height,
            disclosureRowHeight: disclosureRow.frame.height)
    }

    private func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = firstTableView(in: child) { return table }
        }
        return nil
    }

    @Test func expandedRunDetailsStaysScrollableAndBounded() async throws {
        let preferred = NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight)
        let minimum = NSSize(
            width: QueueWorkspaceMetrics.Window.minWidth,
            height: QueueWorkspaceMetrics.Window.minHeight)

        let collapsedPreferred = try await measureOverview(expanded: false, size: preferred)
        let expandedPreferred = try await measureOverview(expanded: true, size: preferred)
        let expandedMinimum = try await measureOverview(expanded: true, size: minimum)

        // The floor: the inventory always keeps a finite, visible scroll
        // region — the blank-pane regression.
        #expect(
            collapsedPreferred.inventoryHeight
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "collapsed inventory keeps the floor (got \(collapsedPreferred.inventoryHeight))")
        #expect(
            expandedPreferred.inventoryHeight
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "expanded inventory keeps the floor at the preferred size (got \(expandedPreferred.inventoryHeight))")
        #expect(
            expandedMinimum.inventoryHeight
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "expanded inventory keeps the floor at the minimum window height (got \(expandedMinimum.inventoryHeight))")

        // The disclosure row is real: short when collapsed, tall when
        // expanded — and bounded by its ceiling plus the label row.
        #expect(
            collapsedPreferred.disclosureRowHeight < 80,
            "collapsed disclosure row stays compact (got \(collapsedPreferred.disclosureRowHeight))")
        #expect(
            expandedPreferred.disclosureRowHeight > 120,
            "expanded disclosure row grows its content (got \(expandedPreferred.disclosureRowHeight))")
        #expect(
            expandedPreferred.disclosureRowHeight
                <= QueueWorkspaceMetrics.RunDetails.maxExpandedHeight + 80,
            "expanded disclosure row respects its ceiling (got \(expandedPreferred.disclosureRowHeight))")
        #expect(
            expandedMinimum.disclosureRowHeight > 120,
            "expanded disclosure stays laid out at the minimum window height (got \(expandedMinimum.disclosureRowHeight))")
    }
}
#endif
