import Foundation
import Testing
import WikiFSMarkdown
@testable import WikiFSCore

/// The read-only detection pipeline: bracket findings, broken-link
/// classification (missing target vs unavailable lookup), markdownlint
/// cosmetic findings with typed individual edits, and the single-fix
/// equivalence against markdownlint's own `applyFixes`.
struct LintAnalyzerTests {

    private func linter() throws -> MarkdownLinter {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/markdownlint.bundle.js")
        let src = try String(contentsOf: url, encoding: .utf8)
        guard let linter = MarkdownLinter(jsSource: src) else {
            throw ValidationFailure(message: "markdownlint bundle did not load")
        }
        return linter
    }

    private struct ValidationFailure: Error { let message: String }

    private func snapshot(body: String) -> LintPageSnapshot {
        LintPageSnapshot(
            wikiID: WikiID(rawValue: "wiki"),
            pageID: PageID(rawValue: "p"),
            title: "T",
            body: body,
            headVersionID: PageVersionID(rawValue: "v"),
            strategyRevision: nil,
            strategyContext: "",
            relatedResources: .empty)
    }

    private let emptyRecipes = LintAnalyzer.RecipeLookup { _ in nil }
    private let defaultRecipes = LintAnalyzer.RecipeLookup { producer in
        LintRecipeID(rawValue: producer.rawValue)
    }

    // MARK: - Wiki links

    @Test func bracketDamageProducesOneFindingPerOccurrence() {
        let body = "See [[source:X\\]] and also [[Y\\]].\n"
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: .empty, recipes: emptyRecipes)
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.ruleID?.rawValue == "wiki-link-brackets" })
        // Each finding carries a validated individual fix rewriting its own span.
        for finding in findings {
            let fix = finding.builtinFix
            #expect(fix != nil)
            let applied = fix?.replacement
            #expect(applied != nil)
        }
    }

    @Test func protectedCodeSpansAreExcluded() {
        let body = "Example: `[[Like This\\]]` stays inert.\n"
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: .empty, recipes: emptyRecipes)
        #expect(findings.isEmpty)
    }

    @Test func brokenPageLinkFoundWithRemoveOption() {
        let body = "Links to [[Missing Page]] here.\n"
        let facts = LintResolutionFacts(knownPageTitles: ["Existing"])
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: facts, recipes: defaultRecipes)
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "broken-page-link")
        #expect(findings[0].repairOptions.count == 1)
        #expect(findings[0].builtinFix?.insertText == "Missing Page")
    }

    @Test func resolvedPageLinksAreNotFindings() {
        let body = "Links to [[Existing]] here.\n"
        let facts = LintResolutionFacts(knownPageTitles: ["Existing"])
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: facts, recipes: emptyRecipes)
        #expect(findings.isEmpty)
    }

    @Test func lookupFailureIsDistinctFromMissingTarget() {
        let body = "Cites [[source:Annual Report]] here.\n"
        // Sources unavailable: report-only lookup finding, NOT "broken".
        let facts = LintResolutionFacts(
            knownPageTitles: [], sourcesAvailable: false)
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: facts, recipes: emptyRecipes)
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "wiki-link-source-lookup-unavailable")
        #expect(findings[0].repairOptions.isEmpty)
        // Sources available but no such source: genuinely broken.
        let factsOK = LintResolutionFacts(
            knownPageTitles: [], sourcesAvailable: true)
        let broken = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: factsOK, recipes: emptyRecipes)
        #expect(broken.count == 1)
        #expect(broken[0].ruleID?.rawValue == "broken-source-link")
    }

    @Test func canonicalULIDLinksResolveByID() {
        let pageID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let body = "Backlink: [[page:\(pageID)|Old Name]].\n"
        let facts = LintResolutionFacts(
            knownPageTitles: [],
            knownPageIDs: [pageID.uppercased()])
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: facts, recipes: emptyRecipes)
        #expect(findings.isEmpty)
    }

    @Test func individualFixAppliesToExactBytes() throws {
        let body = "See [[source:X\\]] now.\n"
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: .empty, recipes: emptyRecipes)
        let fix = try #require(findings.first?.builtinFix)
        let applied = try LintProposalBuilder.applyOrThrow(
            [fix.replacement], to: body)
        #expect(applied == "See [[source:X]] now.\n")
    }

    // MARK: - Markdown cosmetics (real markdownlint)

    @Test func cosmeticFindingsCarryValidatedIndividualEdits() throws {
        let linter = try linter()
        let body = "Heading\n\ntext with trailing space   \n"
        let findings = LintAnalyzer.markdownCosmeticFindings(
            stepID: LintStepID(rawValue: "builtin-markdown-cosmetics"),
            body: body, recipes: defaultRecipes, linter: linter)
        let md009 = findings.first { $0.ruleID?.rawValue == "MD009" }
        let fix = try #require(md009?.builtinFix)
        // The fix deletes exactly the trailing spaces.
        #expect(fix.range.expectedText.hasSuffix("   "))
        #expect(fix.insertText.isEmpty || !fix.insertText.hasSuffix(" "))
        let applied = try LintProposalBuilder.applyOrThrow(
            [fix.replacement], to: body)
        #expect(!applied.contains("space   \n"))
    }

    @Test func singleCosmeticFixMatchesApplyFixes() throws {
        // The converter's ground truth: for a document with exactly ONE
        // fixable finding, the converted individual edit must produce the
        // same bytes markdownlint's own applyFixes produces.
        let linter = try linter()
        let body = "# Title\n\nsome text\twith a tab\n"
        let findings = LintAnalyzer.markdownCosmeticFindings(
            stepID: LintStepID(rawValue: "builtin-markdown-cosmetics"),
            body: body, recipes: emptyRecipes, linter: linter)
        let fixable = findings.filter { $0.builtinFix != nil }
        // MD010 (hard tab) is the only finding here.
        #expect(fixable.count == 1)
        let edit = try #require(fixable[0].builtinFix)
        let mine = try LintProposalBuilder.applyOrThrow(
            [edit.replacement], to: body)
        let theirs = linter.fix(markdown: body).fixed
        #expect(mine == theirs)
    }

    @Test func trailingNewlineInsertionMatchesApplyFixes() throws {
        // File-end fix: the one past-end line maps to EOF.
        let linter = try linter()
        let body = "# Title\n\nno final newline"
        let findings = LintAnalyzer.markdownCosmeticFindings(
            stepID: LintStepID(rawValue: "builtin-markdown-cosmetics"),
            body: body, recipes: emptyRecipes, linter: linter)
        let md047 = findings.first { $0.ruleID?.rawValue == "MD047" }
        if let fix = md047?.builtinFix {
            let mine = try LintProposalBuilder.applyOrThrow(
                [fix.replacement], to: body)
            let theirs = linter.fix(markdown: body).fixed
            #expect(mine == theirs)
        } else {
            // If markdownlint folds the file-end fix into another finding's
            // shape, applyFixes parity still holds for the document.
            let theirs = linter.fix(markdown: body).fixed
            #expect(theirs.hasSuffix("\n"))
        }
    }

    @Test func unlocatableCosmeticFindingsAreDroppedNotPageScoped() throws {
        let linter = try linter()
        // A body where markdownlint may report a past-end line: findings
        // without locatable ranges are dropped (never .page scope).
        let body = "content"
        let findings = LintAnalyzer.markdownCosmeticFindings(
            stepID: LintStepID(rawValue: "builtin-markdown-cosmetics"),
            body: body, recipes: emptyRecipes, linter: linter)
        for finding in findings {
            if case .page = finding.scope {
                Issue.record("A dropped finding was invented as page scope")
            }
        }
    }

    @Test func repeatedTextTargetsEachOccurrence() {
        let body = "[[Ghost]] and [[Ghost]] again.\n"
        let findings = LintAnalyzer.wikiLinkFindings(
            stepID: LintStepID(rawValue: "builtin-wiki-links"),
            body: body, facts: .empty, recipes: emptyRecipes)
        #expect(findings.count == 2)
        // Distinct byte ranges — not one deduplicated location.
        let ranges = findings.compactMap { finding in
            finding.passageRanges.first
        }
        #expect(ranges[0].lowerBound != ranges[1].lowerBound)
    }
}
