import Foundation
import Testing
@testable import WikiFS
import WikiFSCore

/// Value-level coverage for the ingestion Overview's recorded-outputs
/// mapping (`QueueWorkspaceMapper.outputsSection` / `outputRow`): legacy,
/// empty, some-pages, deleted-page, and row-cap truncation behavior. Every
/// test is plain values in, plain values out — no hosting or waiting.
@Suite("Queue recorded-outputs mapping")
struct QueueOutputsMappingTests {
    private func nameIndex(_ pages: [(id: String, title: String)]) -> QueueTargetNameIndex {
        var index = QueueTargetNameIndex()
        for page in pages {
            index.recordPage(PageID(rawValue: page.id), title: page.title)
        }
        return index
    }

    private func recorded(_ id: String, _ title: String?) -> QueueRecordedOutputPage {
        QueueRecordedOutputPage(pageID: PageID(rawValue: id), title: title)
    }

    @Test("Loading and unavailable reports keep unknown counts")
    func transientStates() {
        let loading = QueueWorkspaceMapper.outputsSection(
            state: .loading, nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(loading.countText == nil)
        #expect(loading.emptyStateText == "Loading recorded outputs…")

        let unavailable = QueueWorkspaceMapper.outputsSection(
            state: .unavailable, nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(unavailable.countText == nil)
        #expect(unavailable.emptyStateText == "Recorded outputs are unavailable.")
    }

    @Test("Legacy report: unknown count and explicit unrecorded state")
    func notRecordedState() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .notRecorded, nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == nil)
        #expect(section.rows.isEmpty)
        #expect(section.emptyStateText == "Outputs were not recorded for this job.")
    }

    @Test("Loaded with no pages: resolved zero plus truthful empty state")
    func loadedEmpty() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([]), nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == "0")
        #expect(section.rows.isEmpty)
        #expect(section.emptyStateText == "No pages recorded yet.")
    }

    @Test("Loaded with pages: live titles, no status, Open Page links")
    func loadedPages() {
        let index = nameIndex([("p1", "Alpha Page"), ("p2", "Beta Page")])
        var opened: [PageID] = []
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([recorded("p1", "Recorded Alpha"), recorded("p2", nil)]),
            nameIndex: index,
            openPage: { opened.append($0) })

        #expect(section.countText == "2")
        #expect(section.emptyStateText == "No pages recorded yet.")
        // The live name-index seam wins over the recorded store title; the
        // order is the store's (title) order.
        #expect(section.rows.map(\.title) == ["Alpha Page", "Beta Page"])
        #expect(section.rows.compactMap(\.identity) == [
            .page(PageID(rawValue: "p1")),
            .page(PageID(rawValue: "p2")),
        ])
        #expect(section.rows.allSatisfy { $0.status == nil })
        // Every resolvable output's name is an Open Page link.
        #expect(section.rows.allSatisfy { $0.actions.map(\.label) == ["Open Page"] })

        section.rows[0].actions.first?.perform()
        #expect(opened == [PageID(rawValue: "p1")])
    }

    @Test("Full-page load: count is the truncation floor “200+”, never a total-looking 200")
    func fullPageLoadMarksTruncation() {
        // Synthetic full-page state: exactly the store-query row cap
        // (`QueueWorkspaceMetrics.Outputs.maxRows`) of loaded pages. At the
        // cap the store result was truncated, so a bare count would read as
        // a verified total.
        let pages = (0..<QueueWorkspaceMetrics.Outputs.maxRows).map {
            recorded("p\($0)", "Page \($0)")
        }
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded(pages), nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == "\(QueueWorkspaceMetrics.Outputs.maxRows)+")
        // The marker changes nothing else: one row per loaded page, rows
        // still resolve through the recorded titles (empty live index).
        #expect(section.rows.count == QueueWorkspaceMetrics.Outputs.maxRows)
        #expect(section.rows.first?.title == "Page 0")
    }

    @Test("Sub-cap load: count is the exact loaded total, no truncation marker")
    func subCapLoadExactCount() {
        let pages = (0..<QueueWorkspaceMetrics.Outputs.maxRows - 1).map {
            recorded("p\($0)", "Page \($0)")
        }
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded(pages), nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == "\(QueueWorkspaceMetrics.Outputs.maxRows - 1)")
    }

    @Test("Deleted page: honest degraded title, no dead link")
    func deletedPageDegradation() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([recorded("gone", nil)]),
            nameIndex: QueueTargetNameIndex(),
            openPage: { _ in Issue.record("a deleted page must not navigate") })
        #expect(section.countText == "1")
        #expect(section.rows.map(\.title) == ["Deleted page"])
        #expect(section.rows.flatMap(\.actions).isEmpty)
    }

    @Test("Recorded store title survives when the live seam cannot resolve; no action offered")
    func recordedTitleFallback() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([recorded("p9", "Recorded Title")]),
            nameIndex: QueueTargetNameIndex(),
            openPage: { _ in Issue.record("an unresolved page must not navigate") })
        #expect(section.rows.map(\.title) == ["Recorded Title"])
        #expect(section.rows.flatMap(\.actions).isEmpty)
    }

    @Test("Section nouns: Inputs for ingest; extraction and lint unchanged")
    func sectionTitles() {
        #expect(QueueWorkspaceMapper.sectionTitle(for: .ingest, isWholeWiki: false) == "Inputs")
        #expect(QueueWorkspaceMapper.sectionTitle(for: .extract, isWholeWiki: false) == "Sources")
        #expect(QueueWorkspaceMapper.sectionTitle(for: .lint, isWholeWiki: false) == "Pages")
        #expect(QueueWorkspaceMapper.sectionTitle(for: .lint, isWholeWiki: true) == "Scope")
    }

    @Test("Inventory accessibility label: combined only when outputs are present")
    func inventoryAccessibilityLabels() {
        // Ingestion with the Outputs section: the container reads as the
        // combined inventory, not an inputs-only one.
        #expect(QueueJobOverviewView.inventoryAccessibilityLabel(
            sectionTitle: "Inputs", hasOutputs: true) == "Inputs and Outputs inventory")
        // Without outputs (extraction / lint, or ingestion before load):
        // the section noun alone, as before.
        #expect(QueueJobOverviewView.inventoryAccessibilityLabel(
            sectionTitle: "Sources", hasOutputs: false) == "Sources inventory")
        #expect(QueueJobOverviewView.inventoryAccessibilityLabel(
            sectionTitle: "Inputs", hasOutputs: false) == "Inputs inventory")
    }
}
