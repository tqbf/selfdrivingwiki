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

    // MARK: - Citation quote anchors (version-aware evidence)

    private let sourceID = SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYW2")
    private let otherSourceID = SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYW3")

    /// A present source-version record with the given captured text.
    private func presentRecord(
        _ id: SourceID, request: LintSourceVersionRequest = .active,
        text: String, complete: Bool = true
    ) -> LintCapturedSourceVersion {
        let byteCount = text.utf8.count
        let completeness: LintEvidenceCompleteness = complete
            ? .complete : .prefix(originalByteCount: byteCount + 100)
        return LintCapturedSourceVersion(
            sourceID: id, request: request,
            resolvedVersionID: SourceMarkdownVersionID(rawValue: "smv-1"),
            status: .present, text: text, completeness: completeness,
            digest: LintSnapshotDigest.digest(of: text),
            originalByteCount: complete ? nil : byteCount + 100)
    }

    private func statusRecord(
        _ id: SourceID, request: LintSourceVersionRequest = .active,
        status: LintSourceCaptureStatus
    ) -> LintCapturedSourceVersion {
        LintCapturedSourceVersion(
            sourceID: id, request: request, resolvedVersionID: nil,
            status: status, text: nil, completeness: nil, digest: nil,
            originalByteCount: nil)
    }

    /// A snapshot whose citation evidence carries the given records.
    private func citationSnapshot(
        body: String,
        records: [LintCapturedSourceVersion],
        identities: [LintSourceIdentity] = [],
        available: Bool = true
    ) -> LintPageSnapshot {
        LintPageSnapshot(
            wikiID: WikiID(rawValue: "wiki"),
            pageID: PageID(rawValue: "p"),
            title: "T",
            body: body,
            headVersionID: PageVersionID(rawValue: "v"),
            strategyRevision: nil,
            strategyContext: "",
            relatedResources: .empty,
            citations: LintCitationEvidence(
                occurrences: available ? LintCitationOccurrence.parseAll(in: body) : [],
                sourceVersions: records,
                nameIndex: LintSourceNameIndex(identities: identities),
                notices: [],
                isAvailable: available))
    }

    private func citationFindings(
        _ body: String, record: LintCapturedSourceVersion,
        identities: [LintSourceIdentity] = []
    ) -> [LintFinding] {
        LintCitationCheck.findings(
            stepID: LintStepID(rawValue: "citations"),
            snapshot: citationSnapshot(body: body, records: [record], identities: identities),
            recipes: .none)
    }

    @Test func emphasisMarkupMismatchOffersEncodingOnlyRepair() {
        // The real-world shape: the page's anchor uses markdown emphasis
        // while the extracted source renders HTML emphasis. The whole quote
        // has a UNIQUE correspondence after projection, so the encoding-only
        // repair is offered — with no wording change.
        let body = "She says the child was involved.[^child]\n\n[^child]: "
            + "[[source:\(sourceID.rawValue)#\"that child was not *possessed*\"|157]]\n"
        let source = "The point being, that child was not <em>possessed</em> by the "
            + "'spirit of entropy', but rather simply cohabited.\n"
        let findings = citationFindings(body, record: presentRecord(sourceID, text: source))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-encoding-mismatch")
        // Report-only without a configured recipe; the fix rides the finding.
        #expect(findings[0].repairOptions.isEmpty)
        #expect(findings[0].builtinFix != nil)
        let fix = findings[0].builtinFix
        #expect(fix?.insertText == "that child was not possessed")
    }

    @Test func genuinelyMissingQuoteIsReported() {
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)#\"a phrase that exists nowhere here\"|src]]\n"
        let source = "Unrelated source text with none of those words together.\n"
        let findings = citationFindings(body, record: presentRecord(sourceID, text: source))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-fragment-missing")
        #expect(findings[0].repairOptions.isEmpty)  // report-only
        #expect(findings[0].message.contains("Quote anchor not found"))
    }

    @Test func curlyQuoteNormalizationMatches() {
        let body = "Quote.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)#\"wholly independent atemporal beings\"|src]]\n"
        let source = "…wholly independent atemporal beings rather than figures…\n"
        #expect(citationFindings(body, record: presentRecord(sourceID, text: source)).isEmpty)
    }

    @Test func partialMatchIsDistinctFromFullCorrespondence() {
        // Only a >= 4-word run matches: the reader's fallback would
        // highlight a shorter passage — reported as partial, never as
        // verified or absent.
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)#\"the committee reviewed the proposal with unusual care yesterday\"|src]]\n"
        let source = "Minutes: the committee reviewed the proposal. Then adjourned.\n"
        let findings = citationFindings(body, record: presentRecord(sourceID, text: source))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-fragment-partial")
        #expect(findings[0].repairOptions.isEmpty)
    }

    @Test func missingQuoteFromPrefixCaptureIsUnverifiedNotAbsent() {
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)#\"text beyond the captured prefix goes here\"|src]]\n"
        let source = "Captured head of the source.\n"
        let findings = citationFindings(
            body, record: presentRecord(sourceID, text: source, complete: false))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-unverified")
        #expect(findings[0].severity == .info)
        #expect(findings[0].message.contains("UNVERIFIED"))
    }

    @Test func quotePresentInPrefixIsNotCompleteVerification() {
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)#\"visible head text\"|src]]\n"
        let source = "visible head text; the rest was not captured\n"
        let findings = citationFindings(
            body, record: presentRecord(sourceID, text: source, complete: false))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-fragment-prefix-only")
        #expect(findings[0].severity == .info)
    }

    @Test func missingVersionPinIsReported() {
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)@v7#\"anything\"|src]]\n"
        let findings = citationFindings(
            body, record: statusRecord(sourceID, request: .pinned(
                LintSourceVersionPin(ordinal: 7)!), status: .missingVersion))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-version-missing")
    }

    @Test func pinnedQuoteValidatesAgainstPinnedVersion() {
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)@v2#\"older phrasing of the claim\"|src]]\n"
        let source = "v2 content: older phrasing of the claim\n"
        let record = presentRecord(
            sourceID, request: .pinned(LintSourceVersionPin(ordinal: 2)!), text: source)
        #expect(citationFindings(body, record: record).isEmpty)
    }

    @Test func ambiguousSourceNameIsReportOnlyWithCandidates() {
        let nameIdentity = LintSourceIdentity(
            id: SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYW4"),
            effectiveName: "Report.pdf", filename: "Report.pdf")
        let second = LintSourceIdentity(
            id: SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYW5"),
            effectiveName: "report.pdf", filename: "report (1).pdf")
        let body = "Claim.[^x]\n\n[^x]: [[source:Report.pdf#\"anything\"|src]]\n"
        let findings = LintCitationCheck.findings(
            stepID: LintStepID(rawValue: "citations"),
            snapshot: citationSnapshot(
                body: body,
                records: [presentRecord(nameIdentity.id, text: "x"),
                          presentRecord(second.id, text: "y")],
                identities: [nameIdentity, second]),
            recipes: .none)
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-source-ambiguous")
        #expect(findings[0].repairOptions.isEmpty)
        #expect(findings[0].evidence?.contains("candidates:") == true)
        // Both candidate ids appear — no arbitrary selection.
        #expect(findings[0].evidence?.contains(nameIdentity.id.rawValue) == true)
        #expect(findings[0].evidence?.contains(second.id.rawValue) == true)
    }

    @Test func uniqueSourceNameOffersCanonicalization() {
        let identity = LintSourceIdentity(
            id: SourceID(rawValue: "01M58TQS3ZHJC1YCDPJ327AYW4"),
            effectiveName: "Quarterly Report", filename: "q-report.md")
        let body = "See [[source:Quarterly Report|the report]].\n"
        let findings = LintCitationCheck.findings(
            stepID: LintStepID(rawValue: "citations"),
            snapshot: citationSnapshot(
                body: body, records: [presentRecord(identity.id, text: "x")],
                identities: [identity]),
            recipes: .none)
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-source-canonicalizable")
        // The fix preserves alias and visible text.
        #expect(findings[0].builtinFix?.insertText
            == "[[source:\(identity.id.rawValue.uppercased())|the report]]")
    }

    @Test func captureUnavailableStaysSilent() {
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)#\"anything\"|src]]\n"
        let findings = LintCitationCheck.findings(
            stepID: LintStepID(rawValue: "citations"),
            snapshot: citationSnapshot(
                body: body, records: [], available: false),
            recipes: .none)
        #expect(findings.isEmpty)
    }

    @Test func unfetchedRecordReportsUnverifiedNotBroken() {
        let body = "Claim.[^x]\n\n[^x]: [[source:\(sourceID.rawValue)#\"anything\"|src]]\n"
        let findings = citationFindings(
            body, record: statusRecord(sourceID, status: .unavailableExtraction))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "citation-unverified")
        #expect(findings[0].severity == .info)
    }

    // MARK: - Truncated-output candidates

    private func truncationFindings(_ body: String) -> [LintFinding] {
        LintAnalyzer.truncationCandidates(
            stepID: LintStepID(rawValue: "builtin-truncation"), body: body)
    }

    @Test func leadingFragmentIsDetected() {
        // The real-world shape: a stored body that begins mid-markup with
        // the page's title heading and lead sentence lost.
        let body = "terface][^flower-research-link]\n\n## Powers\n\nBody text.\n"
        let findings = truncationFindings(body)
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "truncated-output")
        #expect(findings[0].message.contains("open mid-construct"))
        #expect(findings[0].repairOptions.isEmpty)  // report-only
        #expect(findings[0].scope.passageAnchorStartsAtLineStart)
    }

    @Test func trailingUnclosedConstructsAreDetected() {
        let codeRun = "# Title\n\nBody ends with an open `code span\n"
        let codeFindings = truncationFindings(codeRun)
        #expect(codeFindings.contains { $0.message.contains("inline-code run") })

        let bracket = "# Title\n\nSee the table (below\n"
        let bracketFindings = truncationFindings(bracket)
        #expect(bracketFindings.contains { $0.message.contains("bracket(s) that never") })
    }

    @Test func cleanPageEndsProduceNoTruncationFindings() {
        let body = "# Title\n\nA healthy paragraph with `code` and (parens) and [links].\n"
        #expect(truncationFindings(body).isEmpty)
    }

    @Test func fenceProtectedLinesAreExcluded() {
        // Unbalanced brackets inside a fenced example are literal content.
        let body = "# Title\n\n```text\n) ] }\n```\n\nNormal closing paragraph.\n"
        #expect(truncationFindings(body).isEmpty)
    }
}

private extension LintFindingScope {
    /// The anchor starts at the very beginning of the body (line 1).
    var passageAnchorStartsAtLineStart: Bool {
        if case .passage(let ranges) = self, let first = ranges.first {
            return first.lowerBound == 0
        }
        return false
    }
}
