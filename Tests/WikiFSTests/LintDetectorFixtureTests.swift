import Foundation
import Testing
import WikiFSTypes
import WikiFSMarkdown
@testable import WikiFSCore

/// AC.4: every enabled detector class has positive, negative, and boundary
/// coverage; ordered sections distinguish empty/blocked/not-evaluated/
/// truncated states; the injected-facts checks (D09/D11/D27/D28) fail
/// honestly when their store or package inputs are absent.
struct LintDetectorFixtureTests {

    private let resolution: LintResolutionFacts = {
        var facts = LintResolutionFacts()
        facts.knownPageTitles = ["Calvin Cycle"]
        facts.knownPageIDs = ["01HZPAGE00000000000000000A"]
        facts.knownSourceIDs = ["01HZSRC1000000000000000001", "01HZSRC2000000000000000002"]
        facts.sourceIDsByLooseName = [
            "smith2023": [SourceID(rawValue: "01HZSRC1000000000000000001")],
            "shared name": [
                SourceID(rawValue: "01HZSRC1000000000000000001"),
                SourceID(rawValue: "01HZSRC2000000000000000002"),
            ],
        ]
        facts.knownChatTitles = ["Design Chat"]
        facts.knownChatIDs = ["01HZCHAT0000000000000000001"]
        return facts
    }()

    private let sourceID = SourceID(rawValue: "01HZSRC1000000000000000001")

    private func scan(
        _ body: String,
        citations: LintCitationFacts? = nil,
        originURLs: LintOriginURLFacts? = nil,
        history: LintHistoryFacts? = nil,
        fenceValidation: LintFenceValidationFacts? = nil
    ) -> LintPreflightReport {
        let snapshot = LintPageSnapshot(
            pageID: PageID(rawValue: "01HZPAGE00000000000000000A"),
            title: "Calvin Cycle",
            headVersionID: PageVersionID(rawValue: "01HZHEAD00000000000000000001"),
            body: body,
            sourceInputs: [])
        return LintPagePreflight.scan(
            snapshot: snapshot, resolution: resolution,
            citations: citations, originURLs: originURLs,
            history: history, fenceValidation: fenceValidation)
    }

    private func findings(_ report: LintPreflightReport, _ section: LintScanSection) -> [LintFinding] {
        report.sections.first { $0.section == section }?.findings ?? []
    }

    private func allFindings(_ report: LintPreflightReport) -> [LintFinding] {
        report.sections.flatMap(\.findings)
    }

    // MARK: - The class matrix (AC.4)

    /// One positive and one negative fixture per pure-detector class.
    struct Fixture: Sendable {
        let defectClass: LintDefectClass
        let positive: String
        let negative: String

        init(_ defectClass: LintDefectClass, _ positive: String, _ negative: String) {
            self.defectClass = defectClass
            self.positive = positive
            self.negative = negative
        }
    }

    static let matrix: [Fixture] = [
        // D01 — a 3-backtick line cannot close a 4-backtick block.
        Fixture(.fenceBoundaryDamage, "````swift\n```\ninner\n````\n", "```swift\ncode\n```\n"),
        // D02 — odd bold delimiter run.
        Fixture(.delimiterDamage, "A **bold start\n", "A **bold** span.\n"),
        // D03 — header declares 2 cells, separator declares 3: no parse.
        Fixture(.tableDamage, "| A | B |\n| --- | --- | --- |\n", "| A | B |\n| --- | --- |\n| 1 | 2 |\n"),
        // D04 — 4-space item jump under a `- ` marker.
        Fixture(.listNestingDamage, "- a\n    - b\n", "- a\n  - b\n"),
        // D05 — level jump and a duplicate heading.
        Fixture(.headingDamage, "# One\n\n#### Deep\n\n# One\n", "# One\n\n## Two\n"),
        // D06 — an opener that never closes at EOF.
        Fixture(.malformedWikiLink, "Unclosed at EOF: [[Broken Link\n", "[[Calvin Cycle]]\n"),
        // D07 — unresolvable page target.
        Fixture(.brokenTarget, "[[Nowhere Page]]\n", "[[Calvin Cycle]]\n"),
        // D08 — display name resolving to exactly one source.
        Fixture(.noncanonicalSourceTarget, "[[source:Smith2023]]\n", "[[source:01HZSRC1000000000000000001]]\n"),
        // D10 — embed of a non-source target.
        Fixture(.unsupportedEmbed, "![[Calvin Cycle]]\n", "![[source:01HZSRC1000000000000000001]]\n"),
        // D14 — reviewed placeholder marker.
        Fixture(.placeholderResidue, "TODO fix the table\n", "Fix the table soon.\n"),
        // D15 — conflict markers.
        Fixture(.duplicateBlocksOrMergeResidue, "<<<<<<< HEAD\n\nOriginal heading\n\n>>>>>>> feature\n", "clean prose\n"),
        // D17 — replacement character.
        Fixture(.encodingDamage, "broken \u{FFFD} here\n", "clean prose here\n"),
        // D18 — inline event handler outside code.
        Fixture(.pastedActiveContent, "Click <a onclick=\"evil()\">here</a>\n", "Click `<a onclick=\"evil()\">` protected.\n"),
        // D20 — undefined reference label and relative media.
        Fixture(.missingMediaReference, "See [text][missing] and ![pic](photo.png)\n", "See [text][ok] and ![pic](https://example.org/p.png)\n\n[ok]: https://example.org\n"),
        // D22 — undefined footnote reference.
        Fixture(.footnoteDamage, "A ref.[^ghost]\n", "A ref.[^real]\n\n[^real]: yes\n"),
        // D23 — unclosed bracket on the final line.
        Fixture(.truncatedOutput, "The list starts (and never\n", "The list starts (and closes).\n"),
        // D24 — tool-output marker and meta-text phrase.
        Fixture(.metaTextLeakage, "<tool_use>result</tool_use>\n\nAs an AI example.\n", "The tool produced a result table.\n"),
        // D25 — whole-body wrap.
        Fixture(.wholeBodyFenceWrap, "```markdown\n# Wrapped\n[[Link]]\n```\n", "# Fine\n\n[[Calvin Cycle]]\n"),
        // D26 — double-escaped entity and bidi control.
        Fixture(.escapingLayerDamage, "entity &amp;amp; here and \u{202E}override\n", "entity &amp; here\n"),
    ]

    /// AC.4 `classMatrix`: every in-scope pure-detector class fires on its
    /// positive fixture and stays silent on its negative fixture.
    @Test("every class has positive and negative coverage", arguments: matrix)
    func classMatrix(_ fixture: Fixture) {
        let positives = allFindings(scan(fixture.positive))
            .filter { $0.defectClass == fixture.defectClass }
        #expect(positives.isEmpty == false, "expected ≥1 \(fixture.defectClass.rawValue) finding on the positive fixture")
        let negatives = allFindings(scan(fixture.negative))
            .filter { $0.defectClass == fixture.defectClass }
        #expect(negatives.isEmpty, "expected no \(fixture.defectClass.rawValue) findings on the negative fixture")
    }

    /// Out-of-scope classes (D12/D13/D16/D19/D21) never appear in a scan.
    @Test func outOfScopeClassesNeverReport() {
        let bodies = Self.matrix.map(\.positive) + Self.matrix.map(\.negative)
        for body in bodies {
            let outOfScope = allFindings(scan(body)).filter {
                $0.defectClass.repairPolicy == .outOfScope
            }
            #expect(outOfScope.isEmpty, "out-of-scope classes reported for: \(body)")
        }
    }

    // MARK: - Boundary fixtures

    /// A parsed table whose body row declares a different cell count is a
    /// candidate — never mechanically reconstructed.
    @Test func parsedTableRowCellMismatchIsCandidate() {
        let rows = findings(scan("| A | B |\n| --- | --- |\n| 1 | 2 | 3 |\n"), .markdownStructure)
            .filter { $0.defectClass == .tableDamage }
        #expect(rows.count == 1)
        #expect(rows[0].confidence == .candidate)
        #expect(rows[0].candidateRepair == nil)
    }

    /// An unfenced (indented) code block directly after prose is a D04
    /// candidate; a fenced block is exempt.
    @Test func accidentalIndentedCodeBlockAfterProse() {
        let positive = findings(scan("Intro paragraph line.\n\n    accidentally code\n"), .markdownStructure)
            .filter { $0.defectClass == .listNestingDamage }
        #expect(positive.count == 1)
        let fencedNegative = findings(scan("Intro paragraph line.\n\n```\nfenced code\n```\n"), .markdownStructure)
            .filter { $0.defectClass == .listNestingDamage }
        #expect(fencedNegative.isEmpty)
    }

    /// Exact duplicate blocks need ≥80 non-whitespace characters.
    @Test func duplicateBlocksNeedEightyCharacters() {
        let long = String(repeating: "contentful sentence here ", count: 5)
        let over = findings(scan("\(long)\n\n\(long)\n"), .integrityAndHistory)
            .filter { $0.defectClass == .duplicateBlocksOrMergeResidue }
        #expect(over.count == 1)
        #expect(over[0].confidence == .candidate)
        let short = String(repeating: "short bit ", count: 3)
        let under = findings(scan("\(short)\n\n\(short)\n"), .integrityAndHistory)
            .filter { $0.defectClass == .duplicateBlocksOrMergeResidue }
        #expect(under.isEmpty)
    }

    /// Protected code never produces findings: active content and encoding
    /// damage inside literal examples are invisible to the detectors.
    @Test func protectedCodeNeverReports() {
        let fenced = findings(scan("```html\n<script>alert(1)</script>\n```\n"), .integrityAndHistory)
            .filter { $0.defectClass == .pastedActiveContent }
        #expect(fenced.isEmpty)
        let inline = findings(scan("Text with \u{FFFD} outside `code \u{FFFD}` span\n"), .integrityAndHistory)
            .filter { $0.defectClass == .encodingDamage }
        #expect(inline.count == 1, "only the unprotected occurrence reports")
    }

    // MARK: - D09 citation fragments (facts-injected)

    private var citationFacts: LintCitationFacts {
        var facts = LintCitationFacts()
        var citation = LintCitationFacts.SourceCitation()
        citation.exists = true
        citation.availablePinOrdinals = [1, 2]
        citation.activeNormalizedText = "the effect vanishes in darkness"
        citation.normalizedTextByPin = [
            1: "v1 text the effect vanishes",
            2: "v2 the effect vanishes in darkness",
        ]
        facts.sources[sourceID.rawValue] = citation
        return facts
    }

    @Test func citationFragmentAvailabilityChecksFacts() {
        // An absent quote is a finding.
        let absent = findings(
            scan("[[source:01HZSRC1000000000000000001#\"absent from the text\"]]", citations: citationFacts),
            .wikiReferences)
            .filter { $0.defectClass == .citationFragmentDamage }
        #expect(absent.count == 1)
        #expect(absent[0].confidence == .confirmed)
        // A pin beyond the chain is a finding naming the pin.
        let badPin = findings(
            scan("[[source:01HZSRC1000000000000000001@v9#\"the effect vanishes\"]]", citations: citationFacts),
            .wikiReferences)
            .filter { $0.defectClass == .citationFragmentDamage }
        #expect(badPin.count == 1)
        #expect(badPin[0].evidence.contains("@v9"))
        // The existing pin with a real quote is clean.
        let good = findings(
            scan("[[source:01HZSRC1000000000000000001@v2#\"the effect vanishes\"]]", citations: citationFacts),
            .wikiReferences)
            .filter { $0.defectClass == .citationFragmentDamage }
        #expect(good.isEmpty)
        // Quote matching is whitespace-normalized.
        let wrapped = findings(
            scan("[[source:01HZSRC1000000000000000001#\"the   effect\tvanishes\"]]", citations: citationFacts),
            .wikiReferences)
            .filter { $0.defectClass == .citationFragmentDamage }
        #expect(wrapped.isEmpty)
    }

    /// AC.4 `missingResourceAndLookupFailureDiffer`: a missing source is a
    /// broken-target finding (not a D09 crash), facts-less scans record an
    /// honest limit, a failed history read BLOCKS its section, and a first
    /// version is recorded as not applicable.
    @Test func missingResourceAndLookupFailureDiffer() {
        // Missing source: D07 speaks; D09 stays silent.
        let ghost = findings(scan("[[source:Ghost2023]]", citations: citationFacts), .wikiReferences)
        #expect(ghost.contains { $0.defectClass == .brokenTarget })
        #expect(ghost.filter { $0.defectClass == .citationFragmentDamage }.isEmpty)

        // Facts not supplied: no D09 findings, limit recorded.
        let noFacts = scan("[[source:01HZSRC1000000000000000001#\"anything\"]]")
        #expect(findings(noFacts, .wikiReferences).filter { $0.defectClass == .citationFragmentDamage }.isEmpty)
        #expect(noFacts.sections.first { $0.section == .wikiReferences }?.dialectLimits.contains {
            $0.contains("D09") && $0.contains("not evaluated")
        } == true)

        // History read failure blocks the section (REQ-43).
        let failed = scan("body", history: LintHistoryFacts(availability: .readFailed(reason: "chain unavailable")))
        if case .blocked(let reason) = failed.sections.first(where: { $0.section == .integrityAndHistory })?.status {
            #expect(reason.contains("could not run"))
        } else {
            Issue.record("a history read failure must block the integrity section")
        }

        // First version: not applicable, section still clean.
        let first = scan("body", history: LintHistoryFacts(availability: .firstVersion))
        let integrity = first.sections.first { $0.section == .integrityAndHistory }
        #expect(integrity?.status.isClean == true)
        #expect(integrity?.dialectLimits.contains { $0.contains("not applicable") } == true)
    }

    // MARK: - D11 raw URLs (facts-injected)

    @Test func rawURLCandidatesRequireOneVerifiedResource() {
        let body = "Doc: https://example.org/report\n"
        guard let identity = URLFetchService.urlIdentity("https://example.org/report") else {
            Issue.record("the URL identity should resolve")
            return
        }
        let sourceB = SourceID(rawValue: "01HZSRC2000000000000000002")

        // Exactly one verified resource → candidate repair to the citation.
        var one = LintOriginURLFacts()
        one.sourcesByIdentity[identity] = [sourceID]
        let single = findings(scan(body, originURLs: one), .rawURLsAndMedia)
            .filter { $0.defectClass == .rawExternalURL }
        guard single.count == 1, let repaired = single.first else {
            Issue.record("expected exactly one D11 finding with a repair, got \(single.count)")
            return
        }
        if case .replacement(let text)? = repaired.candidateRepair?.change {
            #expect(text == "[[source:01HZSRC1000000000000000001]]")
        } else {
            Issue.record("expected a citation replacement candidate")
        }

        // Ambiguity: reported without a repair.
        var two = LintOriginURLFacts()
        two.sourcesByIdentity[identity] = [sourceID, sourceB]
        let ambiguous = findings(scan(body, originURLs: two), .rawURLsAndMedia)
            .filter { $0.defectClass == .rawExternalURL }
        guard ambiguous.count == 1, let unpatched = ambiguous.first else {
            Issue.record("expected exactly one ambiguous D11 finding, got \(ambiguous.count)")
            return
        }
        #expect(unpatched.candidateRepair == nil)
        #expect(unpatched.confidence == .candidate)

        // Zero matches and facts-less scans stay inventory-only.
        #expect(findings(scan(body, originURLs: LintOriginURLFacts()), .rawURLsAndMedia)
            .filter { $0.defectClass == .rawExternalURL }.isEmpty)
        #expect(findings(scan(body), .rawURLsAndMedia)
            .filter { $0.defectClass == .rawExternalURL }.isEmpty)
    }

    // MARK: - D27 history regression (facts-injected)

    @Test func historyRegressionComparesActualParent() {
        let parent = "# Section\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nSee [[source:01HZSRC1000000000000000001]].\n"
        let head = "# Section\n"
        let facts = LintHistoryFacts(availability: .parentAvailable(
            parentVersionID: PageVersionID(rawValue: "01HZPARENT000000000000000001"),
            parentBody: parent))
        let regressions = findings(scan(head, history: facts), .integrityAndHistory)
            .filter { $0.defectClass == .regressionAgainstPreviousHead }
        #expect(regressions.count >= 3)
        #expect(regressions.contains { $0.message.contains("table") })
        #expect(regressions.contains { $0.message.contains("citation") })
        #expect(regressions.contains { $0.message.contains("shrank") })
        // Loss alone never proposes restoration.
        #expect(regressions.allSatisfy { $0.candidateRepair == nil })

        // Identical content is clean.
        let same = findings(scan(parent, history: facts), .integrityAndHistory)
            .filter { $0.defectClass == .regressionAgainstPreviousHead }
        #expect(same.isEmpty)
    }

    // MARK: - D28 rich fences (facts-injected)

    @Test func richFenceRevalidationOutcomes() {
        let body = "```mermaid\nflowchart LR\n```\n"
        func withOutcome(_ outcome: LintFenceValidationFacts.Outcome) -> LintPreflightReport {
            var facts = LintFenceValidationFacts()
            facts.outcomesByFenceIndex[0] = outcome
            return scan(body, fenceValidation: facts)
        }
        // Invalid: confirmed, major, carries the format's own error.
        let invalid = findings(withOutcome(.invalid(errors: ["syntax error at line 1"])), .rawURLsAndMedia)
            .filter { $0.defectClass == .richFenceRevalidation }
        #expect(invalid.count == 1)
        #expect(invalid[0].severity == .major && invalid[0].confidence == .confirmed)
        #expect(invalid[0].message.contains("syntax error at line 1"))
        // Unclaimed: a minor candidate.
        let unclaimed = findings(withOutcome(.unclaimed), .rawURLsAndMedia)
            .filter { $0.defectClass == .richFenceRevalidation }
        #expect(unclaimed.count == 1 && unclaimed[0].confidence == .candidate)
        // Validated: no finding.
        #expect(findings(withOutcome(.validated), .rawURLsAndMedia)
            .filter { $0.defectClass == .richFenceRevalidation }.isEmpty)
        // Suppressed: no finding, but the limit records it.
        let suppressed = withOutcome(.suppressed)
        #expect(findings(suppressed, .rawURLsAndMedia)
            .filter { $0.defectClass == .richFenceRevalidation }.isEmpty)
        #expect(suppressed.sections.first { $0.section == .rawURLsAndMedia }?
            .dialectLimits.contains { $0.contains("suppressed") } == true)
        // Facts-less scans record the not-evaluated limit.
        let unevaluated = scan(body)
        #expect(unevaluated.sections.first { $0.section == .rawURLsAndMedia }?
            .dialectLimits.contains { $0.contains("D28") && $0.contains("not evaluated") } == true)
    }

    /// Same-alias fences map to the validator's per-alias block order.
    @Test func claimedBlockOrdinalFollowsAliasOrder() {
        let two = "```mermaid\na\n```\n\ntext\n\n```mermaid\nb\n```\n"
        let parsed = ParsedMarkdownDocument(parsing: two)
        let ordinals = parsed.fenceFacts.enumerated().map {
            LintFenceValidationFacts.claimedBlockOrdinal(ofFence: $0.offset, fenceFacts: parsed.fenceFacts)
        }
        #expect(ordinals == [0, 1])
    }
}
