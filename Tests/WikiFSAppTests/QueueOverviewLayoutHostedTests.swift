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
    /// The userInitiated activity assertion's token. Held for the suite's
    /// whole lifetime: dropping the returned object ENDS the assertion (its
    /// dealloc ends the activity), which would re-arm AppKit's automatic
    /// termination mid-suite. Initialized by ``app``.
    private nonisolated(unsafe) static var userActivityToken: NSObjectProtocol?

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Same guard as ActivityWindowWorkspaceHostedTests: as an accessory-
        // policy app, AppKit's automatic termination can decide the idle
        // helper process should exit mid-suite — silently killing the runner
        // (exit 0, all results lost). disableAutomaticTermination alone is
        // not enough (AppKit's enable/disable calls are refcounted and re-
        // enable termination mid-run — and this suite orders its windows OUT
        // between scenarios, repeatedly going idle-with-no-windows); a
        // userInitiated activity assertion holds for the suite's whole
        // lifetime.
        ProcessInfo.processInfo.disableAutomaticTermination(
            "hosted Overview layout scenarios")
        userActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "hosted Overview layout scenarios")
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

    // MARK: - Ingestion recorded outputs (Inputs / Outputs sections)

    /// An ingestion Overview with recorded provenance: the Inputs section
    /// keeps its name-link (Reveal Source) rows and count, the Outputs
    /// section appears under it, and the provenance-resolved page renders as
    /// a CLICKABLE name link performing Open Page. A cited page that no
    /// longer resolves stays honest plain text — no dead link. The citation
    /// evidence is recorded through the production writer seam
    /// (`appendPageVersion` provenance inputs) into a real GRDB store, then
    /// resolved through the real store API + mapper.
    @Test func ingestionOverviewShowsOutputsSectionWithClickableRows() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        defer { lease.release() }

        // Recorded provenance: one page citing both inputs.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overview-outputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("wiki.sqlite"))
        let page = try store.createPage(title: "Recorded Output")
        let inputOne = try store.addSource(filename: "input-one.txt", data: Data("1".utf8))
        let inputTwo = try store.addSource(filename: "input-two.txt", data: Data("2".utf8))
        let head = try #require(try store.pageHeadVersionID(pageID: page.id))
        _ = try store.appendPageVersion(
            pageID: page.id, title: "Recorded Output", body: "body",
            expectedHeadVersionID: head, lastEditedBy: nil,
            provenance: PageVersionSourceInput.agentIngest(
                sourceIDs: [inputOne.id, inputTwo.id]))

        // Resolve outputs through the real store API…
        let cited = try store.pagesCitingSources(
            sourceIDs: [inputOne.id, inputTwo.id],
            limit: QueueWorkspaceMetrics.Outputs.maxRows)
        #expect(cited.map(\.title) == ["Recorded Output"])
        // …plus one citation edge whose page row is gone: it must degrade
        // honestly (plain text), not render a dead link.
        //
        // NOTE: this nil-title CitedPage is a SYNTHETIC fixture — an orphan
        // citation edge is not producible through public APIs today (a page
        // delete cascades its citation edges away; see
        // `PagesCitingSourcesTests.deletedPageDropsOutOfOutputs`). It
        // simulates the defensive LEFT-JOIN case `pagesCitingSources`
        // guards for: a citation edge that outlived its page row.
        let loadedOutputs = cited
            + [CitedPage(pageID: PageID(rawValue: "vanished-page"), title: nil)]

        // The queue's live-title seam, built the way the window builds it.
        var nameIndex = QueueTargetNameIndex()
        for summary in try store.listPages(sortBy: .titleAZ) {
            nameIndex.recordPage(summary.id, title: summary.title)
        }

        let openSpy = Mutex(0)
        let revealSpy = Mutex(0)
        let inputRows = [inputOne, inputTwo].map { source in
            QueueTargetRowValue(
                identity: .source(source.id),
                title: source.filename,
                status: .succeeded(),
                actions: [QueueWorkspaceAction(
                    label: "Reveal Source", systemImage: "arrow.up.forward.app") {
                    revealSpy.withLock { $0 += 1 }
                }])
        }
        let outputs = QueueWorkspaceMapper.outputsSection(
            state: .loaded(loadedOutputs),
            nameIndex: nameIndex,
            openPage: { _ in openSpy.withLock { $0 += 1 } })
        let presentation = QueueJobOverviewPresentation(
            sectionTitle: QueueWorkspaceMapper.sectionTitle(for: .ingest, isWholeWiki: false),
            countText: "2",
            rows: inputRows,
            resultStatement: nil,
            emptyStateText: "No sources recorded for this job.",
            outputs: outputs)

        let root = QueueJobOverviewView(presentation)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // Exactly three clickable name links: the two unchanged input links
        // and the ONE resolvable output. The vanished page hosts no button.
        var buttons: [NSButton] = []
        for _ in 0..<30 {
            buttons = allButtons(in: host.view)
            if buttons.count == 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(buttons.count == 3,
                "two input links + one resolvable output link expected (got \(buttons.count))")

        // The bridged SwiftUI buttons carry no NSButton.title, so identify
        // them by what they ROUTE: clicking every name link must run exactly
        // one Open Page (the output) and two Reveal Source (the unchanged
        // inputs). A dead output would show up as a missing Open Page click.
        for button in buttons {
            button.performClick(nil)
        }
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(openSpy.withLock { $0 } == 1,
                "exactly the output's page-name link performs Open Page (got \(openSpy.withLock { $0 }))")
        #expect(revealSpy.withLock { $0 } == 2,
                "both input links still perform Reveal Source (got \(revealSpy.withLock { $0 }))")
    }

    /// The empty-inputs edge: an ingestion Overview whose inputs inventory
    /// is EMPTY must still mount the List and show the Outputs section. The
    /// honest inputs edge case renders INSIDE the list (its message as one
    /// row) instead of replacing the whole inventory region — the earlier
    /// behavior, where the `ContentUnavailableView` path meant NO table view
    /// mounted at all and the recorded-outputs section vanished with it.
    @Test func outputsSectionSurvivesEmptyInputsInventory() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        defer { lease.release() }

        // One recorded output with no live resolution: it degrades to its
        // recorded title as plain text (no Open Page link) — same shape the
        // real store path produces for a resolvable-but-not-live page.
        let outputs = QueueWorkspaceMapper.outputsSection(
            state: .loaded([CitedPage(pageID: PageID(rawValue: "recorded-1"), title: "Recorded Output")]),
            nameIndex: QueueTargetNameIndex(),
            openPage: { _ in Issue.record("an unresolved output must not navigate") })
        let presentation = QueueJobOverviewPresentation(
            sectionTitle: QueueWorkspaceMapper.sectionTitle(for: .ingest, isWholeWiki: false),
            countText: nil,
            rows: [],
            resultStatement: nil,
            emptyStateText: "No sources recorded for this job.",
            outputs: outputs)

        let root = QueueJobOverviewView(presentation)
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 640, height: 400))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // The List must bridge even with empty inputs — the regression this
        // test pins is the missing-table-view case — and its row model must
        // still carry the outputs rows alongside the inputs edge-case row
        // (a section header row may also bridge, hence the floor, not an
        // exact count).
        var table: NSTableView?
        for _ in 0..<30 {
            table = firstTableView(in: host.view)
            if table != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let inventory = try #require(
            table,
            "the Outputs-bearing List must mount its table view even with empty inputs")
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(
            inventory.numberOfRows >= 2,
            "the inputs edge-case row and the recorded-outputs rows share one list (got \(inventory.numberOfRows))")
        // The container accessibility label ("Inputs and Outputs inventory")
        // is pinned at the value level
        // (QueueOutputsMappingTests.inventoryAccessibilityLabels): like the
        // SwiftUI-drawn label text noted in this suite's header, the List's
        // accessibilityLabel does not bridge to the NSTableView in a
        // `swift test` host (verified: `accessibilityLabel()` is nil here).
    }
}
#endif
