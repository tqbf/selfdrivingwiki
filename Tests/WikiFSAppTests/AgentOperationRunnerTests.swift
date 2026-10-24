#if os(macOS)
import Foundation
import WikiFSEngine
import Testing
import WikiFSEngine
@testable import WikiFSCore
@testable import WikiFS
@testable import WikiFSEngine

@MainActor
struct AgentOperationRunnerTests {

    private func tempStore() throws -> (WikiStoreModel, GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-aor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    // MARK: - runLintPages combination logic

    @Test func singlePagePreflightReturnsEmptyBrokenLinks() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Test Page")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        // A fresh page with no broken links should have an empty broken list.
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    @Test func multiplePagePreflightsAreIndependent() throws {
        let (model, store) = try tempStore()
        let a = try store.createPage(title: "A")
        let b = try store.createPage(title: "B")
        // Create a link from A to a non-existent page so preflight
        // detects a broken link.
        try store.updatePage(id: a.id, title: "A", body: "[[MissingOne]]")
        try store.updatePage(id: b.id, title: "B", body: "[[MissingTwo]]")
        model.reloadFromStore()

        let pa = model.preflightLint(pageID: a.id)
        let pb = model.preflightLint(pageID: b.id)

        // Each page detects its own broken links independently.
        #expect(pa?.brokenPageLinks == ["MissingOne"])
        #expect(pb?.brokenPageLinks == ["MissingTwo"])
    }

    // MARK: - Coordinator dispatch (plan §5.2/§5.4 — replaces title-join tests)

    /// The shared plan builder carries the TYPED page identity (never joined
    /// titles) and stages the pre-flight + run-report artifacts.
    @Test func lintPagePlanCarriesTypedIdentityAndStagesArtifacts() async throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Alpha")
        try store.updatePage(id: page.id, title: "Alpha", body: "See [[source:Smith2023]].\n")
        _ = model

        let plan = try #require(await AgentOperationRunner.makeLintPagePlan(
            store: store, pageID: page.id, stateMarkdown: "# state\n"))
        // Typed identity — the exact page, not a joined title.
        guard case .lintPage(let identity, _, _, _, _, _) = plan.request else {
            Issue.record("expected a .lintPage request")
            return
        }
        #expect(identity.pageID == page.id)
        #expect(identity.title == "Alpha")
        // The request stages both artifacts and the state file.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let op = try plan.request.stage(into: scratch)
        guard case .lintPage(_, _, _, let reportPath, let runReportPath, _) = op else {
            Issue.record("expected a staged .lintPage operation")
            return
        }
        let preflight = try String(contentsOfFile: reportPath, encoding: .utf8)
        #expect(preflight.contains("sourceCitation-1"), "the worklist inventories every occurrence")
        let skeleton = try String(contentsOfFile: runReportPath, encoding: .utf8)
        #expect(skeleton.hasPrefix(LintRunReportText.formatMarker))
        #expect(skeleton.contains("finding D07-1 pending"), "the broken citation is a finding to account for")
    }

    /// The launcher derives the managed-run policy from the request alone
    /// (review C1): repair-authorized lintPage → repair lease on that page,
    /// unauthorized lintPage → report-only lease on that page, `.lint` →
    /// whole-wiki report-only, everything else ordinary.
    @Test func managedRunPolicyDerivesFromRequest() {
        let page = LintPageIdentity(
            pageID: PageID(rawValue: "01HZPAGE00000000000000000A"),
            title: "P", headVersionID: nil)
        func request(_ repairAuthorized: Bool) -> OperationRequest {
            .lintPage(
                page: page, repairAuthorized: repairAuthorized, gateReason: "g",
                preflightReportMarkdown: "# p\n", runReportMarkdown: "r\n",
                stateMarkdown: "# s\n")
        }
        #expect(AgentLauncher.managedRunPolicy(for: request(true))
            == .lintSelectedPageRepair(pageID: page.pageID))
        #expect(AgentLauncher.managedRunPolicy(for: request(false))
            == .lintSelectedPageReportOnly(pageID: page.pageID))
        #expect(AgentLauncher.managedRunPolicy(for: .lint(stateMarkdown: "# s\n"))
            == .lintWholeWikiReportOnly)
        #expect(AgentLauncher.managedRunPolicy(
            for: .ingest(sources: [], stateMarkdown: "# s\n")) == .ordinaryManaged)
        #expect(AgentLauncher.managedRunPolicy(
            for: .query(question: "q", stateMarkdown: "# s\n")) == .ordinaryManaged)
    }

    /// A page deleted or renamed before its run is SKIPPED with a reason —
    /// never an empty clean audit (AC.9).
    @Test func missingPagePlanIsNil() async throws {
        let (_, store) = try tempStore()
        let ghost = PageID(rawValue: "01HZGHOST0000000000000000009")
        let plan = await AgentOperationRunner.makeLintPagePlan(
            store: store, pageID: ghost, stateMarkdown: "# state\n")
        #expect(plan == nil)
    }

    /// The verification gate's change observation: prefix/suffix trim to the
    /// changed middle, from the store's own bytes.
    @Test func observedChangeRangesTrimToTheChangedMiddle() {
        // Identical bytes: no change region.
        #expect(AgentOperationRunner.observedChangeRanges(
            before: "# Same\n", after: "# Same\n").isEmpty)
        // A middle edit: the region covers exactly the changed span (the
        // trailing newline is a common suffix).
        let ranges = AgentOperationRunner.observedChangeRanges(
            before: "# T\n\nold text\n", after: "# T\n\nnew text here\n")
        #expect(ranges.count == 1)
        #expect(ranges[0].startByte == 5)
        #expect(ranges[0].endByte == "# T\n\nold text\n".utf8.count - 1)
        // An append: the region is empty on the old side.
        let appended = AgentOperationRunner.observedChangeRanges(
            before: "# T\n", after: "# T\n\nmore\n")
        #expect(appended.count == 1 && appended[0].startByte == 4)
        #expect(appended[0].endByte == 4)
    }

    // MARK: - Canonical ULID links are not false positives

    @Test func canonicalULIDPageLinkIsNotBroken() throws {
        let (model, store) = try tempStore()
        let target = try store.createPage(title: "Target Page")
        let page = try store.createPage(title: "Linker")
        // A canonical [[page:<ULID>|alias]] link should NOT be reported broken.
        try store.updatePage(id: page.id, title: "Linker",
            body: "See [[page:\(target.id.rawValue)#Intro|Target Page]].")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    // MARK: - Links inside code spans are not checked

    @Test func linksInsideCodeSpansAreNotBroken() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Docs")
        // `[[Like This]]` inside backticks is example text, not a real link.
        try store.updatePage(id: page.id, title: "Docs",
            body: "Use `[[Like This]]` to link pages.")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    @Test func linksInsideFencedBlocksAreNotBroken() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Docs")
        try store.updatePage(id: page.id, title: "Docs", body: """
        Example:

        ```
        [[Nonexistent Page]]
        ```
        """)
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenPageLinks.isEmpty == true)
    }

    // MARK: - Source links are checked

    @Test func brokenSourceLinkIsDetected() throws {
        let (model, store) = try tempStore()
        let page = try store.createPage(title: "Citing Page")
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[^1]: [[source:Nonexistent Source#\"quote\"]]\n\nText.[^1]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.contains("Nonexistent Source") == true)
    }

    @Test func resolvedSourceLinkIsNotBroken() throws {
        let (model, store) = try tempStore()
        _ = try store.addSource(filename: "Guide.md", data: Data("# Guide".utf8))
        let page = try store.createPage(title: "Citing Page")
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[^1]: [[source:Guide#\"intro\"]]\n\nText.[^1]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.isEmpty == true)
    }

    @Test func legacySourceProjectionLinkIsNotBroken() throws {
        let (model, store) = try tempStore()
        let source = try store.addSource(filename: "ScalaTestingWithSpecs2.md", data: Data("source".utf8))
        let page = try store.createPage(title: "Citing Page")
        let projection = "\(source.filename)–\(source.id.rawValue).md"
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[[source:\(projection)#\"quoted passage\"]]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.isEmpty == true)
    }

    @Test func stagedSourceProjectionLinkRequiresLintRepair() throws {
        let (model, store) = try tempStore()
        let source = try store.addSource(filename: "Guide.md", data: Data("source".utf8))
        let page = try store.createPage(title: "Citing Page")
        let staged = "guide--\(source.id.rawValue).md"
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[^1]: [[source:\(staged)#\"intro\"]]\n\nText.[^1]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.contains(staged) == true)
    }

    @Test func sourceLinkWithDashMismatchIsNotBroken() throws {
        let (model, store) = try tempStore()
        let src = try store.addSource(filename: "Guide.md", data: Data("# Guide".utf8))
        try store.renameSource(id: src.id, to: "Self-Driving Wiki \u{2014} User Guide")
        let page = try store.createPage(title: "Citing Page")
        // Agent cited the name without the em dash — looseMatchKey should resolve it.
        try store.updatePage(id: page.id, title: "Citing Page",
            body: "[^1]: [[source:Self-Driving Wiki User Guide#\"intro\"]]\n\nText.[^1]")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.brokenSourceLinks.isEmpty == true)
    }
}
#endif
