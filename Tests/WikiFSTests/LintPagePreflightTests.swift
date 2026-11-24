import Foundation
import Testing
@testable import WikiFSCore

/// Issue #1461 — the single-page lint worklist beyond broken links. Covers the
/// two factual pre-flight scans (`LintPreflightScanner`), the
/// `LintPagePreflight` transport (whose array-literal conformance keeps
/// `brokenLinks: []` call sites compiling), the sections they render into the
/// lint task prompt, and the `WikiStoreModel.preflightLint` integration.
/// Pure detection: every scan lists facts, none fixes anything.
@Suite struct LintPagePreflightTests {

    // MARK: - Raw external URLs (scanner)

    @Test func urlInProseIsListedWithLineNumber() {
        let findings = LintPreflightScanner.rawExternalURLs(
            in: """
            Intro paragraph.

            See https://example.com/lady for details.
            """)
        #expect(findings == ["line 3: https://example.com/lady"])
    }

    @Test func urlInsideMarkdownLinkIsNotListed() {
        let findings = LintPreflightScanner.rawExternalURLs(
            in: "The [official docs](https://example.com/docs) cover this.")
        #expect(findings.isEmpty)
    }

    @Test func urlInAngleAutolinkIsNotListed() {
        let findings = LintPreflightScanner.rawExternalURLs(
            in: "See <https://example.com/autolink> for more.")
        #expect(findings.isEmpty)
    }

    @Test func urlInCodeSpanIsNotListed() {
        let findings = LintPreflightScanner.rawExternalURLs(
            in: "Run `curl https://example.com/api` first.")
        #expect(findings.isEmpty)
    }

    @Test func urlInFencedBlockIsNotListed() {
        let findings = LintPreflightScanner.rawExternalURLs(
            in: """
            Text before.

            ```
            curl https://example.com/fenced
            ```

            Text after.
            """)
        #expect(findings.isEmpty)
    }

    @Test func noURLsMeansEmptyList() {
        #expect(LintPreflightScanner.rawExternalURLs(in: "No links here at all.").isEmpty)
    }

    @Test func trailingSentencePunctuationIsTrimmed() {
        let findings = LintPreflightScanner.rawExternalURLs(in: "Visit https://example.com/x.")
        #expect(findings == ["line 1: https://example.com/x"])
    }

    @Test func linkedURLIsSkippedButBareURLIsListed() {
        let findings = LintPreflightScanner.rawExternalURLs(
            in: "First https://a.example.com/one, then [linked](https://b.example.com/two).")
        #expect(findings == ["line 1: https://a.example.com/one"])
    }

    // MARK: - Malformed tables (scanner)

    @Test func wellFormedTableIsNotReported() {
        let findings = LintPreflightScanner.malformedTables(
            in: """
            | Name | Count |
            | --- | --- |
            | a | 1 |
            | b | 2 |
            """)
        #expect(findings.isEmpty)
    }

    @Test func missingSeparatorRowIsReported() {
        let findings = LintPreflightScanner.malformedTables(
            in: """
            | Name | Count |
            | a | 1 |
            | b | 2 |
            """)
        #expect(findings.count == 1)
        #expect(findings[0].hasPrefix("line 1:"))
        #expect(findings[0].contains("no valid separator row"))
    }

    @Test func inconsistentColumnCountsAreReported() {
        let findings = LintPreflightScanner.malformedTables(
            in: """
            | Name | Count | Note |
            | --- | --- | --- |
            | a | 1 |
            | b | 2 | extra | cells |
            """)
        #expect(findings.count == 1)
        #expect(findings[0].hasPrefix("line 1:"))
        #expect(findings[0].contains("inconsistent column counts"))
        #expect(findings[0].contains("(3, 3, 2, 4)"))
    }

    @Test func malformedTableInsideFencedBlockIsNotReported() {
        let findings = LintPreflightScanner.malformedTables(
            in: """
            Before.

            ```
            | a | b |
            | c | d |
            ```

            After.
            """)
        #expect(findings.isEmpty)
    }

    @Test func singlePipeLineIsNotATable() {
        #expect(LintPreflightScanner.malformedTables(in: "| just one line |").isEmpty)
    }

    // MARK: - LintPagePreflight transport

    @Test func arrayLiteralFillsBrokenLinksOnly() {
        let findings: LintPagePreflight = ["[[Missing]]"]
        #expect(findings.brokenLinks == ["[[Missing]]"])
        #expect(findings.rawExternalURLs.isEmpty)
        #expect(findings.malformedTables.isEmpty)
    }

    @Test func emptyArrayLiteralKeepsLegacyCallSitesCompiling() {
        let findings: LintPagePreflight = []
        #expect(findings == LintPagePreflight())
    }

    // MARK: - Prompt rendering

    @Test func lintPagePromptRendersAllThreeWorklistSections() {
        let findings = LintPagePreflight(
            brokenLinks: ["[[Missing Page]]"],
            rawExternalURLs: ["line 4: https://example.com/ref"],
            malformedTables: ["line 9: markdown table has inconsistent column counts (3, 2)"])
        let prompt = WikiOperation.lintPage(
            pageTitle: "The Lady",
            brokenLinks: findings,
            stateFilePath: "/scratch/WIKI_STATE.md"
        ).prompt(wikiRoot: "/wiki")
        #expect(prompt.contains("Broken wiki links (targets not found in the wiki):"))
        #expect(prompt.contains("  - [[Missing Page]]"))
        #expect(prompt.contains("Raw external URLs (bare http(s) links in the body — listed as facts):"))
        #expect(prompt.contains("  - line 4: https://example.com/ref"))
        #expect(prompt.contains(
            "Malformed markdown tables (missing/invalid separator row or inconsistent column counts):"))
        #expect(prompt.contains("  - line 9: markdown table has inconsistent column counts (3, 2)"))
        // A clean report can never end the audit — the named steps are present.
        #expect(prompt.contains("the START of the audit"))
        #expect(prompt.contains("Audit every raw external URL"))
        #expect(prompt.contains("Audit every markdown table"))
    }

    @Test func lintPagePromptRendersNoneDetectedWhenClean() {
        let prompt = WikiOperation.lintPage(
            pageTitle: "Clean",
            brokenLinks: [],
            stateFilePath: "/scratch/WIKI_STATE.md"
        ).prompt(wikiRoot: "/wiki")
        #expect(prompt.contains("Broken wiki links: none detected."))
        #expect(prompt.contains("Raw external URLs: none detected."))
        #expect(prompt.contains("Malformed markdown tables: none detected."))
    }

    @Test func lintPagePromptHasNoUnfilledPlaceholders() {
        let prompt = WikiOperation.lintPage(
            pageTitle: "X",
            brokenLinks: [],
            stateFilePath: "/scratch/WIKI_STATE.md"
        ).prompt(wikiRoot: "/wiki")
        #expect(!prompt.contains("{{"))
    }

    // MARK: - preflightLint integration

    @MainActor
    private func tempModelAndStore() throws -> (WikiStoreModel, GRDBWikiStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lintpreflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try GRDBWikiStore(databaseURL: dir.appendingPathComponent("WikiFS.sqlite"))
        return (WikiStoreModel(store: store), store)
    }

    @MainActor
    @Test func preflightListsRawURLsAndMalformedTables() throws {
        let (model, store) = try tempModelAndStore()
        let page = try store.createPage(title: "The Lady")
        try store.updatePage(
            id: page.id, title: "The Lady",
            body: """
            The lady of the lake.

            Source: https://example.com/lady-legend

            | Name | Realm |
            | Nimue | The lake |
            """)
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.rawExternalURLs == ["line 3: https://example.com/lady-legend"])
        #expect(preflight?.malformedTables.count == 1)
        #expect(preflight?.malformedTables[0].contains("no valid separator row") == true)
    }

    @MainActor
    @Test func preflightCleanPageHasEmptyContentScans() throws {
        let (model, store) = try tempModelAndStore()
        let page = try store.createPage(title: "Clean")
        try store.updatePage(
            id: page.id, title: "Clean",
            body: "A proper [linked citation](https://example.com) and no tables.")
        model.reloadFromStore()

        let preflight = model.preflightLint(pageID: page.id)
        #expect(preflight?.rawExternalURLs.isEmpty == true)
        #expect(preflight?.malformedTables.isEmpty == true)
    }
}
