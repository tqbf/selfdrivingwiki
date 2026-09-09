#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import WikiFS
import WikiFSCore

/// Focused hosted-layout coverage for the Overview inventory since Run
/// Details moved OUT of the Overview and into the window's optional Run
/// Details inspector panel (opened from the toolbar):
/// - the inventory List's model carries EXACTLY the target rows — no
///   trailing boundary rows (divider + disclosure) anymore;
/// - the bridged inventory table always keeps a finite, visible height
///   (≥ the floor `QueueWorkspaceMetrics.Inventory.minVisibleHeight`) at the
///   workspace's preferred and minimum window sizes — the blank-pane
///   regression the original suite pinned for the disclosure era.
///
/// Hosts the REAL `QueueJobOverviewView` (production component, real
/// List→NSTableView bridging). The inspector panel itself, its toolbar
/// toggle, and the center-inventory-remains-visible guarantee are hosted at
/// the window level in `ActivityWindowWorkspaceHostedTests`.
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

    /// A presentation shaped like a real completed ingestion job: a
    /// multi-target inventory (local search surfaces at ≥ 12 rows).
    private static func presentation(rowCount: Int = 40) -> QueueJobOverviewPresentation {
        let rows = (0..<rowCount).map { index in
            QueueTargetRowValue(
                identity: .source(SourceID(rawValue: "layout-source-\(index)")),
                title: String(format: "Source-%03d.pdf", index),
                status: .planned())
        }
        return QueueJobOverviewPresentation(
            sectionTitle: "Sources",
            countText: String(rowCount),
            rows: rows,
            resultStatement: "3 submitted",
            emptyStateText: "No sources recorded for this job.")
    }

    /// Host the Overview at `size` and measure the bridged inventory table's
    /// row count and height after the layout settles.
    private func measureOverview(size: NSSize) async throws -> (rowCount: Int, height: CGFloat) {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        defer { lease.release() }

        let root = QueueJobOverviewView(Self.presentation())
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
            "the inventory List must mount its table view")
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(50)) }
        return (rowCount: inventory.numberOfRows, height: inventory.bounds.height)
    }

    private func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = firstTableView(in: child) { return table }
        }
        return nil
    }

    /// The inventory row's NAME is the clickable link (no disclosure control,
    /// no visible IDs): hosting the real `QueueTargetRow` in a List and
    /// clicking the bridged name-link button must invoke the row's action —
    /// the same closure seam the window's `openPage` / `revealSource` /
    /// `browsePages` routing plugs into. A dead target (no action) renders
    /// plain text and must host NO button.
    @Test func targetRowNameLinkInvokesRoutingAction() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        defer { lease.release() }

        let performed = Mutex(0)
        let linked = QueueTargetRowValue(
            identity: .page(PageID(rawValue: "link-page")),
            title: "Notes",
            status: .succeeded(),
            actions: [
                QueueWorkspaceAction(label: "Open Page", systemImage: "arrow.up.forward.app") {
                    performed.withLock { $0 += 1 }
                }
            ])
        let dead = QueueTargetRowValue(
            identity: .page(PageID(rawValue: "dead-page")),
            title: "Deleted Page",
            status: .planned())

        let host = NSHostingController(rootView: List {
            QueueTargetRow(value: linked)
            QueueTargetRow(value: dead)
        })
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 640, height: 200))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // Wait for the List to bridge and materialize its row buttons.
        var buttons: [NSButton] = []
        for _ in 0..<30 {
            buttons = allButtons(in: host.view)
            if !buttons.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Exactly one clickable control: the live target's name link. The
        // dead target's plain-text name hosts no button.
        #expect(buttons.count == 1,
                "Only the resolvable target's name is a link (got \(buttons.count) buttons)")
        let link = try #require(buttons.first, "The name link must bridge to a real button")
        link.performClick(nil)
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(performed.withLock { $0 } == 1,
                "Clicking the name link must run the row's routing action")
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        var out: [NSButton] = []
        if let button = view as? NSButton { out.append(button) }
        for child in view.subviews {
            out.append(contentsOf: allButtons(in: child))
        }
        return out
    }

    @Test func inventoryKeepsFloorAndExactRowModel() async throws {
        let preferred = NSSize(
            width: QueueWorkspaceMetrics.Window.preferredWidth,
            height: QueueWorkspaceMetrics.Window.preferredHeight)
        let minimum = NSSize(
            width: QueueWorkspaceMetrics.Window.minWidth,
            height: QueueWorkspaceMetrics.Window.minHeight)

        let preferredMeasurement = try await measureOverview(size: preferred)
        let minimumMeasurement = try await measureOverview(size: minimum)

        // The list model is exactly the target inventory: Run Details no
        // longer rides as the List's trailing boundary rows.
        #expect(
            preferredMeasurement.rowCount == 40,
            "the Overview list carries exactly its 40 target rows (got \(preferredMeasurement.rowCount))")

        // The floor: the inventory always keeps a finite, visible scroll
        // region — the blank-pane regression.
        #expect(
            preferredMeasurement.height
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "inventory keeps the floor at the preferred size (got \(preferredMeasurement.height))")
        #expect(
            minimumMeasurement.height
                >= QueueWorkspaceMetrics.Inventory.minVisibleHeight - 1,
            "inventory keeps the floor at the minimum window height (got \(minimumMeasurement.height))")
    }
}
#endif
