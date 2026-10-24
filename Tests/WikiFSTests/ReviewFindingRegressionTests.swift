import Foundation
import Testing
import WikiFSTypes
import WikiLintEval
@testable import WikiFSCore

/// Independent-review regression pins (plans/independent-review-opus55.md):
/// C2 masked-regex offset drift, C3 composer order-dependence, M2 untouched
/// skeleton rejection.
struct ReviewFindingRegressionTests {

    // MARK: - C2: masked-regex offsets with non-ASCII protected code

    /// Production finding (lint 01M5QY0GWWR9S270DDGRJ7TQ0B, confirmed by the
    /// operator: the table does not render correctly): a GFM table whose body
    /// rows carry `[[page:X|alias]]` links IS damaged — the raw alias pipe is
    /// a real cell delimiter at parse time (wiki links are transformed only
    /// at render, after truncation), so the rows have more cells than the
    /// header and the link is severed. D03 must fire.
    @Test func wikiLinkAliasPipesInsideTablesAreDamage() throws {
        let body = """
        | Installment | Reader state |
        | --- | --- |
        | [[page:01M5ATYXK1A76HSRMN9Q9W9EPQ|158: Fate Inescapable]] | She qualifies her nature. |
        | [[page:01M5AVQY2H9NZGV60B6VEDMW6W|164: Fate Inescapable]] | She warns Su about rash bargaining. |
        """
        let snapshot = LintPageSnapshot(
            pageID: PageID(rawValue: "01HZPAGE00000000000000000A"),
            title: "T", headVersionID: nil, body: body, sourceInputs: [])
        let report = LintPagePreflight.scan(
            snapshot: snapshot, resolution: LintResolutionFacts())
        let d03 = report.sections.first { $0.section == .markdownStructure }?
            .findings.filter { $0.defectClass == .tableDamage } ?? []
        #expect(d03.count == 2,
            "both alias-piped rows are genuine damage: \(d03.map(\.message))")
        // The honest agent outcome is unresolved — the repair (removing the
        // alias or escaping the pipe) risks the link's meaning.
        for finding in d03 {
            #expect(finding.candidateRepair == nil,
                "no mechanical repair for alias-piped rows")
        }
    }

    /// A regex-detected marker AFTER protected non-ASCII code must report
    /// the correct authored range and evidence. The old code converted the
    /// match's UTF-16 range against the SOURCE (whose UTF-16 indexing
    /// diverges from the masked text), shifting the range and crashing with
    /// NSRangeException when the drift passed EOF.
    @Test func maskedRegexOffsetsSurviveNonASCIIProtectedCode() {
        let body = "```\n漢字漢字漢字\n```\nSee the TODO marker now\n"
        let parsed = ParsedMarkdownDocument(parsing: body)
        let protectedUTF16 = WikiFootnoteMarkdown.utf16Ranges(of: parsed.codeProtection, in: body)
        let protectedUTF8 = protectedUTF16.compactMap { LintPagePreflight.utf8Range($0, in: body) }
        let masked = LintPagePreflight.byteMasked(body, protectedUTF8: protectedUTF8)

        let findings = LintPagePreflight.placeholderCandidates(
            maskedBody: masked, source: body)
        #expect(findings.count == 1, "the TODO after the CJK fence must be found")
        guard let finding = findings.first, let r = finding.range else {
            Issue.record("finding must carry a range")
            return
        }
        #expect(finding.evidence == "TODO")
        // The range must decode to the actual authored "TODO" bytes.
        let bytes = Array(body.utf8)
        let slice = String(decoding: bytes[r.lowerBound..<r.upperBound], as: UTF8.self)
        #expect(slice == "TODO", "range must land on the authored TODO, got \(slice)")
    }

    /// The reviewer's crash shape: enough masked multi-byte content that the
    /// drifted UTF-16 range passes EOF. Must not trap (uncatchable
    /// NSRangeException); any reported range decodes to real content.
    @Test func maskedRegexDriftPastEOFFindsNothingAndDoesNotTrap() {
        let body = "```\n" + String(repeating: "漢字", count: 20) + "\n```\nTODO\n"
        let parsed = ParsedMarkdownDocument(parsing: body)
        let protectedUTF16 = WikiFootnoteMarkdown.utf16Ranges(of: parsed.codeProtection, in: body)
        let protectedUTF8 = protectedUTF16.compactMap { LintPagePreflight.utf8Range($0, in: body) }
        let masked = LintPagePreflight.byteMasked(body, protectedUTF8: protectedUTF8)
        // Before the fix this raised an uncatchable NSRangeException.
        let findings = LintPagePreflight.placeholderCandidates(
            maskedBody: masked, source: body)
        let bytes = Array(body.utf8)
        for finding in findings {
            guard let r = finding.range, r.upperBound <= bytes.count else { continue }
            let slice = String(decoding: bytes[r.lowerBound..<r.upperBound], as: UTF8.self)
            #expect(slice.contains("TODO"))
        }
    }

    // MARK: - C3: composer order-dependence

    /// An insertion and a replacement sharing one offset were applied in
    /// submission-dependent order, committing bytes that differ from the
    /// validated edit. Both orders now REJECT (ambiguous shared start), and
    /// the composer is concatenation (order-independent).
    @Test func insertionPlusReplacementAtOneOffsetIsRejected() throws {
        let body = "abcdefgh"
        func patch(_ hunks: [PagePatchHunk]) -> PagePatch {
            PagePatch(
                pageID: PageID(rawValue: "01HZPAGE00000000000000000A"),
                expectHead: PageVersionID(rawValue: "01HZHEAD00000000000000000001"),
                hunks: hunks,
                defectClasses: hunks.map { _ in .fenceBoundaryDamage })
        }
        let ins = PagePatchHunk(startByte: 3, endByte: 3, oldText: "", newText: "X", reason: "ins")
        let repl = PagePatchHunk(startByte: 3, endByte: 6, oldText: "def", newText: "", reason: "del")
        // Submission order 1: insertion first.
        #expect(throws: PagePatchValidationError.self) {
            _ = try PagePatchValidator.composedBody(applying: patch([ins, repl]), to: body)
        }
        // Submission order 2: replacement first.
        #expect(throws: PagePatchValidationError.self) {
            _ = try PagePatchValidator.composedBody(applying: patch([repl, ins]), to: body)
        }
        // The concatenation composer itself is order-independent for
        // NON-ambiguous hunks: reversed submission, same result. (Uses the
        // shipped `composedBody` composer — the same algorithm the oracle
        // mirrors.)
        let a = PagePatchHunk(startByte: 0, endByte: 1, oldText: "a", newText: "A", reason: "r1")
        let b = PagePatchHunk(startByte: 3, endByte: 4, oldText: "d", newText: "D", reason: "r2")
        let forward = try PagePatchValidator.composedBody(
            applying: patch([a, b]), to: body)
        let backward = try PagePatchValidator.composedBody(
            applying: patch([b, a]), to: body)
        #expect(forward == "AbcDefgh")
        #expect(backward == forward)
    }

    // MARK: - M2: the untouched skeleton must not validate

    @Test func untouchedSkeletonIsRejected() throws {
        let snapshot = LintPageSnapshot(
            pageID: PageID(rawValue: "01HZPAGE00000000000000000A"),
            title: "T", headVersionID: PageVersionID(rawValue: "01HZHEAD00000000000000000001"),
            body: "# T\n", sourceInputs: [])
        var resolution = LintResolutionFacts()
        resolution.knownPageTitles = ["T"]
        let preflight = LintPagePreflight.scan(snapshot: snapshot, resolution: resolution)
        let skeleton = LintRunReportText.render(snapshot: snapshot, preflight: preflight)
        // The UNFILLED skeleton is a parse error, never a passing report.
        #expect(throws: LintRunReportParseError.self) {
            _ = try LintRunReportParser.parse(skeleton)
        }
    }
}
