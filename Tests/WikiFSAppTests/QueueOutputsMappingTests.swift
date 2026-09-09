import Foundation
import SQLite3
import Testing
@testable import WikiFS
import WikiFSCore

/// Value-level coverage for the ingestion Overview's recorded-outputs
/// mapping (`QueueWorkspaceMapper.outputsSection` / `outputRow`) and the
/// view-seam load decision (`ActivityWindowView.recordedOutputsLoadState`):
/// the empty, some-pages, deleted-page, and store-failure degradations, plus
/// the row-cap truncation marker. One test reads a real GRDB store (a
/// read-only open on a non-database file, to force a genuine thrown read);
/// everything else is plain values in, plain values out — no hosting, no
/// waiting.
@Suite("Queue recorded-outputs mapping")
struct QueueOutputsMappingTests {
    private func nameIndex(_ pages: [(id: String, title: String)]) -> QueueTargetNameIndex {
        var index = QueueTargetNameIndex()
        for page in pages {
            index.recordPage(PageID(rawValue: page.id), title: page.title)
        }
        return index
    }

    private func cited(_ id: String, _ title: String?) -> CitedPage {
        CitedPage(pageID: PageID(rawValue: id), title: title)
    }

    @Test("Loading: unknown count, quiet loading state")
    func loadingState() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loading, nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == nil)
        #expect(section.rows.isEmpty)
        #expect(section.emptyStateText == "Loading recorded pages…")
    }

    @Test("Store failure: unknown count, honest failure state — never a fake zero")
    func storeFailure() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .failed, nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == nil)
        #expect(section.rows.isEmpty)
        #expect(section.emptyStateText == "Recorded pages couldn’t be loaded.")
    }

    @Test("Loaded with no pages: resolved zero plus truthful empty state")
    func loadedEmpty() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([]), nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == "0")
        #expect(section.rows.isEmpty)
        #expect(section.emptyStateText == "No pages recorded yet.")
    }

    @Test("Loaded with pages: live titles, Recorded status, Open Page links")
    func loadedPages() {
        let index = nameIndex([("p1", "Alpha Page"), ("p2", "Beta Page")])
        var opened: [PageID] = []
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([cited("p1", "Recorded Alpha"), cited("p2", nil)]),
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
        #expect(section.rows.allSatisfy { $0.status == QueueWorkspaceStatus.recorded() })
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
            cited("p\($0)", "Page \($0)")
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
            cited("p\($0)", "Page \($0)")
        }
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded(pages), nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.countText == "\(QueueWorkspaceMetrics.Outputs.maxRows - 1)")
    }

    @Test("Store read throws at the view seam: state is .failed — never an empty success")
    @MainActor
    func storeReadThrowYieldsFailedState() throws {
        // A real GRDB store whose `page_version_sources` b-tree is corrupt:
        // the file stays a VALID SQLite database (so the read-only store
        // constructs — its open runs schema-free PRAGMAs only), but the
        // recorded-outputs READ throws SQLITE_CORRUPT — the production
        // "store can't answer" surface. The writer closes cleanly FIRST so
        // the WAL is checkpointed into the main file (a live WAL would
        // shadow the clobbered page for every reader), and a pre-corruption
        // probe proves the same read returns the citation before the clobber.
        // The clobber itself is applied to the checkpointed main file
        // through a raw handle; no public API can produce it (by design —
        // citation evidence is honest), and Apple's defensive-mode SQLite
        // blocks `writable_schema` writes instead.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("outputs-load-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("wiki.sqlite")
        let sourceID: SourceID
        do {
            let healthy = try GRDBWikiStore(databaseURL: dbURL)
            let source = try healthy.addSource(filename: "input.txt", data: Data("x".utf8))
            let page = try healthy.createPage(title: "Recorded Output")
            let head = try #require(try healthy.pageHeadVersionID(pageID: page.id))
            _ = try healthy.appendPageVersion(
                pageID: page.id, title: "Recorded Output", body: "body",
                expectedHeadVersionID: head, lastEditedBy: nil,
                provenance: PageVersionSourceInput.agentIngest(sourceIDs: [source.id]))
            sourceID = source.id
        }
        // Writer deinited → clean close → WAL checkpointed into the main file.

        // Pre-corruption probe: the same read through the same read-only
        // store construction returns the recorded citation.
        let probe = try GRDBWikiStore(readOnlyURL: dbURL)
        #expect(
            try probe.pagesCitingSources(sourceIDs: [sourceID], limit: 10).count == 1,
            "the fixture must record exactly one citing page before the clobber")

        var raw: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let raw else {
            Issue.record("raw fixture handle failed to open")
            return
        }
        defer { sqlite3_close(raw) }

        // Locate the citation table's root page AND every index rooted on it
        // (schema READS work; schema WRITES are blocked by Apple's
        // defensive-mode system SQLite). The planner may answer through a
        // covering index and never touch the table b-tree, so all of them
        // must go.
        var rootPages: [Int32] = []
        var pageSize: Int32 = 4096
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            raw,
            "SELECT rootpage FROM sqlite_master WHERE rootpage > 1 AND (name = 'page_version_sources' OR tbl_name = 'page_version_sources')",
            -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("rootpage query failed to prepare")
            return
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rootPages.append(sqlite3_column_int(stmt, 0))
        }
        sqlite3_finalize(stmt)
        stmt = nil
        guard sqlite3_prepare_v2(raw, "PRAGMA page_size", -1, &stmt, nil) == SQLITE_OK else {
            Issue.record("page_size query failed to prepare")
            return
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            pageSize = sqlite3_column_int(stmt, 0)
        }
        guard !rootPages.isEmpty else {
            Issue.record("citation table root pages not found")
            return
        }

        // Clobber those root pages in the main file: the database header
        // stays valid, reads of anything else still work, and any access
        // path through the citation table throws SQLITE_CORRUPT.
        let handle = try FileHandle(forWritingTo: dbURL)
        defer { try? handle.close() }
        for rootPage in rootPages {
            try handle.seek(toOffset: UInt64((Int(rootPage) - 1) * Int(pageSize)))
            try handle.write(contentsOf: Data(repeating: 0xDE, count: Int(pageSize)))
        }

        let store = try GRDBWikiStore(readOnlyURL: dbURL)
        let state = ActivityWindowView.recordedOutputsLoadState(
            store: WikiStoreModel(store: store),
            sourceIDs: [sourceID],
            limit: QueueWorkspaceMetrics.Outputs.maxRows)

        // The thrown read degrades to the honest failure state — never
        // `.loaded([])`, which would render "No pages recorded yet." and a
        // resolved zero over a store that simply couldn't answer.
        #expect(state == .failed)
        let section = QueueWorkspaceMapper.outputsSection(
            state: state, nameIndex: QueueTargetNameIndex(), openPage: { _ in })
        #expect(section.emptyStateText == "Recorded pages couldn’t be loaded.")
        #expect(section.countText == nil)
    }

    @Test("Deleted page: honest degraded title, no dead link")
    func deletedPageDegradation() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([cited("gone", nil)]),
            nameIndex: QueueTargetNameIndex(),
            openPage: { _ in Issue.record("a deleted page must not navigate") })
        #expect(section.countText == "1")
        #expect(section.rows.map(\.title) == ["Deleted page"])
        #expect(section.rows.flatMap(\.actions).isEmpty)
    }

    @Test("Recorded store title survives when the live seam cannot resolve; no action offered")
    func recordedTitleFallback() {
        let section = QueueWorkspaceMapper.outputsSection(
            state: .loaded([cited("p9", "Recorded Title")]),
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
