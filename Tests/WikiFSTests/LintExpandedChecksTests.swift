import Foundation
import Testing
import WikiFSMarkdown
import WikiFSCore
import WikiFSTypes

/// AC.2 / AC.5 / AC.6 — the deterministic checks added with resource and
/// content evidence: footnote integrity, table structure, and history-loss
/// candidates. Positive and negative matrices run against the pure APIs.
struct LintExpandedChecksTests {

    // MARK: - Footnotes (AC.2)

    private func footnoteFindings(
        _ body: String, recipes: LintAnalyzer.RecipeLookup = .none
    ) -> [LintFinding] {
        LintFootnoteCheck.findings(
            stepID: LintStepID(rawValue: "builtin-footnotes"), body: body, recipes: recipes)
    }

    @Test func footnoteIntegrityMatchesRenderedLabels() {
        // Undefined reference: reported; the reader renders it as plain text.
        let undefined = "Body text with a missing note[^ghost].\n"
        let undefinedFindings = footnoteFindings(undefined)
        #expect(undefinedFindings.contains {
            $0.ruleID?.rawValue == "footnote-reference-undefined"
        })

        // Conflicting duplicates: same label, different content —
        // report-only, no repair.
        let conflicting = "Text[^a].\n\n[^a]: first version\n\nMore.\n\n[^a]: second version\n"
        let conflictFindings = footnoteFindings(conflicting)
        let conflict = conflictFindings.first {
            $0.ruleID?.rawValue == "footnote-definition-conflict"
        }
        #expect(conflict != nil)
        #expect(conflict?.repairOptions.isEmpty == true)

        // Identical duplicates: the redundant copy offers the exact
        // deletion; the retained definition stays untouched.
        let identical = "Text[^a].\n\n[^a]: the shared content\n\nLater.\n\n[^a]: the shared content\n"
        let duplicateFindings = footnoteFindings(identical)
        let redundant = duplicateFindings.first {
            $0.ruleID?.rawValue == "footnote-definition-redundant"
        }
        #expect(redundant != nil)
        #expect(redundant?.repairOptions.isEmpty == true) // report-only sans recipe
        let fix = redundant?.builtinFix
        #expect(fix != nil)
        let bytes = identical.utf8
        let lower = bytes.index(bytes.startIndex, offsetBy: fix!.range.lowerBound)
        let upper = bytes.index(bytes.startIndex, offsetBy: fix!.range.upperBound)
        let deleted = String(decoding: bytes[lower..<upper], as: UTF8.self)
        // The exact deletion removes the SECOND definition block, newline
        // included, and leaves the retained definition and the reference.
        #expect(deleted == "[^a]: the shared content\n")
        let repaired = identical.replacingCharacters(
            in: identical.index(identical.startIndex, offsetBy: fix!.range.lowerBound)
                ..< identical.index(identical.startIndex, offsetBy: fix!.range.upperBound),
            with: fix!.insertText)
        // The blank separator line before the deleted block remains — the
        // deletion is exactly the redundant definition and its newline.
        #expect(repaired == "Text[^a].\n\n[^a]: the shared content\n\nLater.\n\n")
        // The reference survives; no reference is ever removed.
        #expect(repaired.contains("Text[^a]."))

        // Unused definition: informational, never proof of lost content.
        let unused = "No references here.\n\n[^lonely]: defined but unused\n"
        let unusedFindings = footnoteFindings(unused)
        let info = unusedFindings.first {
            $0.ruleID?.rawValue == "footnote-definition-unused"
        }
        #expect(info?.severity == .info)
        #expect(info?.repairOptions.isEmpty == true)
    }

    @Test func redundantFootnoteRepairPreservesReferencesAndOtherBytes() {
        // Multiline definitions compare by their FULL authored content.
        let body = """
        Intro[^a] text[^b].

        [^a]: shared multiline
             continued line

        Middle paragraph.

        [^a]: shared multiline
             continued line

        [^b]: other note
        """
        let findings = footnoteFindings(body)
        let redundant = findings.filter {
            $0.ruleID?.rawValue == "footnote-definition-redundant"
        }
        #expect(redundant.count == 1)
        // Applying the deletion changes nothing else: every other byte,
        // including the reference and the retained definition, is intact.
        let fix = redundant[0].builtinFix!
        let bytes = Array(body.utf8)
        var patched = bytes
        patched.replaceSubrange(
            fix.range.lowerBound..<fix.range.upperBound,
            with: Array(fix.insertText.utf8))
        let repaired = String(decoding: patched, as: UTF8.self)
        #expect(repaired.contains("Intro[^a] text[^b]."))
        #expect(repaired.components(separatedBy: "[^a]: shared multiline").count == 2)
    }

    @Test func footnoteExamplesRemainProtected() {
        // Footnote-shaped text inside a fenced example is literal content.
        let body = """
        Real text[^real].

        [^real]: defined

        ```text
        [^ghost]: a fenced example, not a footnote
        see [^ghost] reference-shaped text
        ```
        """
        let findings = footnoteFindings(body)
        #expect(findings.isEmpty)

        // Inline code protection too.
        let inline = "Use `[^x]: not real` in prose.\n"
        #expect(footnoteFindings(inline).isEmpty)
    }

    // MARK: - Tables (AC.5)

    private func tableFindings(_ body: String) -> [LintFinding] {
        LintTableCheck.findings(
            stepID: LintStepID(rawValue: "builtin-table-structure"), body: body)
    }

    @Test func tableAliasDamageMatchesProductionRenderer() {
        // The alias pipe survives reader linkification and then splits the
        // GFM cell — real rendering damage (PR #1473 shape, re-authored).
        let damaged = """
        | Page | Notes |
        |------|-------|
        | [[Index|Home|alias]] | second cell text |
        """
        let findings = tableFindings(damaged)
        #expect(findings.contains { $0.ruleID?.rawValue == "table-alias-pipe" })
        #expect(findings.contains { $0.ruleID?.rawValue == "table-column-mismatch" })
        // Report-only: no repair invents table structure.
        #expect(findings.allSatisfy { $0.repairOptions.isEmpty })

        // Declared-column mismatch alone: extra cells are padded/dropped.
        let mismatched = """
        | A | B |
        |---|---|
        | one | two | three |
        """
        let mismatchFindings = tableFindings(mismatched)
        #expect(mismatchFindings.count == 1)
        #expect(mismatchFindings[0].ruleID?.rawValue == "table-column-mismatch")
        #expect(mismatchFindings[0].message.contains("3 cells"))
        #expect(mismatchFindings[0].message.contains("2 columns"))
    }

    @Test func validTablePipesAndCodeAreNotFindings() {
        // Escaped alias pipes are correct encoding.
        let escaped = """
        | Page | Notes |
        |------|-------|
        | [[Index\\|Home]] | intact |
        """
        #expect(tableFindings(escaped).isEmpty)

        // Regular pipes in cells are the table syntax itself.
        let plain = """
        | A | B |
        |---|---|
        | one | two |
        | three | four |
        """
        #expect(tableFindings(plain).isEmpty)

        // Pipes inside fenced code are not table syntax.
        let fenced = """
        ```text
        | not | a | table |
        |-----|---|-------|
        ```
        """
        #expect(tableFindings(fenced).isEmpty)
    }

    @Test func nonAsciiLinesBeforeTableDoNotDriftRowAnchors() {
        // Regression: line offsets were computed in UTF-16 units but finding
        // ranges address UTF-8 bytes — every curly quote / non-ASCII line
        // before the table shifted the anchors EARLIER, anchoring a real
        // table finding onto an unrelated earlier paragraph (operator report:
        // a "table row has 4 cells" finding rendered on a prose paragraph
        // full of ’ characters).
        let prose = "The Director’s invitation and the Playwright’s response are "
            + "presented encounters — ’“”-shaped punctuation throughout.¹²¹⁴\n"
        let table = """
        | A | B |
        |---|---|
        | one | two | three | four |
        """
        let body = prose + table
        let findings = tableFindings(body)
        #expect(findings.count == 1)
        // The anchor must address the ACTUAL mismatched row line.
        let anchor = findings[0].passageRanges.first
        #expect(anchor?.expectedText == "| one | two | three | four |")
    }

    // MARK: - History loss (AC.6)

    private func historySnapshot(body: String, parent: LintCapturedParentVersion?) -> LintPageSnapshot {
        LintPageSnapshot(
            wikiID: WikiID(rawValue: "w"), pageID: PageID(rawValue: "p"),
            title: "T", body: body, headVersionID: PageVersionID(rawValue: "head"),
            strategyRevision: nil, strategyContext: "",
            relatedResources: .empty, parent: parent)
    }

    private func capturedParent(_ text: String) -> LintCapturedParentVersion {
        LintCapturedParentVersion(
            status: .captured, parentVersionID: PageVersionID(rawValue: "parent-1"),
            bodyDigest: LintSnapshotDigest.digest(of: text), text: text,
            completeness: .complete)
    }

    @Test func historyLossUsesActualParentAndReportsOnly() {
        let parentBody = """
        # Report

        | A | B |
        |---|---|
        | 1 | 2 |

        See [[source:01M58TQS3ZHJC1YCDPJ327AYW2#"evidence"|old alias]] and more text here.
        """
        // The edit removes the table and the citation, keeps everything else.
        let currentBody = """
        # Report

        See more text here.
        """
        let findings = LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: currentBody, parent: capturedParent(parentBody)))
        #expect(findings.count == 1)
        #expect(findings[0].scope == .page)
        #expect(findings[0].ruleID?.rawValue == "history-loss-candidate")
        #expect(findings[0].message.contains("table block"))
        #expect(findings[0].message.contains("citation occurrence"))
        // Names the parent version; offers NO restoration.
        #expect(findings[0].evidence?.contains("parent-1") == true)
        #expect(findings[0].repairOptions.isEmpty)

        // Cosmetic alias change is NOT a removal: citation identity keeps
        // target + pin + fragment, not the alias.
        let aliasSwap = """
        # Report

        | A | B |
        |---|---|
        | 1 | 2 |

        See [[source:01M58TQS3ZHJC1YCDPJ327AYW2#"evidence"|NEW alias]] and more text here.
        """
        #expect(LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: aliasSwap, parent: capturedParent(parentBody))
        ).isEmpty)
    }

    @Test func historyLimitsAndIntentionalChangesRemainQualified() {
        // A small edit (under both reduction thresholds) is silent.
        let parentSmall = String(repeating: "word ", count: 100) + "\n"
        let currentSmall = String(repeating: "word ", count: 90) + "\n"
        #expect(LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: currentSmall, parent: capturedParent(parentSmall))
        ).isEmpty)

        // A proportional reduction under the absolute floor is silent.
        let parentFloor = String(repeating: "x", count: 500)
        let currentFloor = String(repeating: "x", count: 300) // >50% but < 256 scalars
        #expect(LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: currentFloor, parent: capturedParent(parentFloor))
        ).isEmpty)

        // Growth is never a loss.
        let parentShort = "short\n"
        let currentLong = String(repeating: "grown ", count: 400) + "\n"
        #expect(LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: currentLong, parent: capturedParent(parentShort))
        ).isEmpty)

        // First version: not a failure, silent.
        let first = LintCapturedParentVersion(
            status: .firstVersion, parentVersionID: nil, bodyDigest: nil,
            text: nil, completeness: nil)
        #expect(LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: "anything", parent: first)
        ).isEmpty)

        // Missing parent row: unavailable history, NEVER an empty parent
        // (which would read as total loss).
        let unavailable = LintCapturedParentVersion(
            status: .unavailable, parentVersionID: PageVersionID(rawValue: "gone"),
            bodyDigest: nil, text: nil, completeness: nil)
        let findings = LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: "tiny", parent: unavailable))
        #expect(findings.count == 1)
        #expect(findings[0].ruleID?.rawValue == "history-comparison-incomplete")
        #expect(!findings[0].message.contains("removes"))

        // A PREFIX capture cannot back complete counts or a size verdict.
        let prefix = LintCapturedParentVersion(
            status: .captured, parentVersionID: PageVersionID(rawValue: "parent-1"),
            bodyDigest: nil, text: String(repeating: "old ", count: 500),
            completeness: .prefix(originalByteCount: 100_000))
        let prefixFindings = LintHistoryCheck.findings(
            stepID: LintStepID(rawValue: "builtin-history"),
            snapshot: historySnapshot(body: "new", parent: prefix))
        #expect(prefixFindings.count == 1)
        #expect(prefixFindings[0].ruleID?.rawValue == "history-comparison-incomplete")
    }

    // MARK: - Quote projection (shared AC.4 primitive)

    @Test func citationTextProjectionPreservesLiteralSymbols() {
        // Emphasis markers are stripped ONLY where they form pairs; literal
        // asterisks/underscores in identifiers survive.
        let projected = WikiQuoteProjection.project(
            "A *real emphasis* and snake_case_name and a literal \\* star.")
        #expect(projected.state == .text)
        let text = projected.text
        #expect(text.contains("real emphasis"))
        #expect(text.contains("snake_case_name"))
        #expect(text.contains("* star"))

        // HTML inline emphasis renders its inner text.
        let html = WikiQuoteProjection.project("before <em>possessed</em> after")
        #expect(html.state == .text)
        #expect(html.text.contains("possessed"))
        #expect(!html.text.contains("<em>"))

        // Entities decode.
        let entity = WikiQuoteProjection.project("Tom &amp; Jerry &lt;3")
        #expect(entity.state == .text)
        #expect(entity.text.contains("Tom & Jerry"))

        // Unsupported constructs are UNAVAILABLE, never guessed.
        let image = WikiQuoteProjection.project("![alt](image.png)")
        #expect(image.state == .unavailable)
    }

    @Test func quoteComparisonMirrorsReaderFallback() {
        let source = WikiQuoteProjection.project(
            "Minutes: the committee reviewed the proposal. Then adjourned.")
        // Full match.
        #expect(WikiQuoteProjection.compare(
            quote: "the committee reviewed the proposal",
            projected: source) == .fullMatch)
        // Partial: a >= 4-word run matches; the whole quote does not.
        #expect(WikiQuoteProjection.compare(
            quote: "the committee reviewed the proposal with unusual care yesterday",
            projected: source) == .partialMatch)
        // No match at all.
        #expect(WikiQuoteProjection.compare(
            quote: "nothing here appears anywhere",
            projected: source) == .noMatch)
        // Empty needle: the reader's search is a no-op → unavailable.
        #expect(WikiQuoteProjection.compare(quote: "   ", projected: source) == .unavailable)
        // Typography normalization on both sides (curly quotes, dashes,
        // ellipsis) mirrors highlightJS. The quote arrives WITHOUT its
        // boundary quotes (the parser strips them).
        let curly = WikiQuoteProjection.project("…wholly independent atemporal beings…")
        #expect(WikiQuoteProjection.compare(
            quote: "wholly independent atemporal beings", projected: curly) == .fullMatch)
    }
}
