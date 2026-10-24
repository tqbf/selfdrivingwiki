import Foundation
import Testing
import WikiFSTypes
@testable import WikiFSCore

/// AC.4 (growing through detector phase): the pre-flight report publishes
/// every section in the exact REQ-23 order, distinguishes empty/blocked/not-
/// checked/truncated states, inventories every occurrence, and produces
/// factual findings with candidate repairs where identity is unique.
struct LintPreflightTests {

    private let cleanResolution: LintResolutionFacts = {
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

    private func scan(_ body: String, resolution: LintResolutionFacts? = nil) -> LintPreflightReport {
        let snapshot = LintPageSnapshot(
            pageID: PageID(rawValue: "01HZPAGE00000000000000000A"),
            title: "Calvin Cycle",
            headVersionID: PageVersionID(rawValue: "01HZHEAD00000000000000000001"),
            body: body,
            sourceInputs: [])
        return LintPagePreflight.scan(snapshot: snapshot, resolution: resolution ?? cleanResolution)
    }

    private func findings(_ report: LintPreflightReport, _ section: LintScanSection) -> [LintFinding] {
        report.sections.first { $0.section == section }?.findings ?? []
    }

    // MARK: - Ordered sections and statuses

    /// All nine REQ-23 sections publish, in order, even for a clean page —
    /// an empty section renders as a completed scan with no findings.
    @Test func orderedCoverageStatuses() {
        let report = scan("# Clean\n\nA healthy page with `code` and [[Calvin Cycle]].")
        #expect(report.sections.map(\.section) == LintScanSection.allCases.sorted())
        // Completed sections carry no findings; integrity/history now runs
        // its detectors (REQ-43: an unavailable check never renders clean —
        // a scan without parent-version facts records that limit instead).
        for section in report.sections where section.status.isClean {
            #expect(section.findings.isEmpty)
        }
        let integrity = report.sections.first { $0.section == .integrityAndHistory }
        #expect(integrity?.status.isClean == true)
        #expect(integrity?.dialectLimits.contains(
            "D27 not evaluated: no parent-version facts were supplied to this scan") == true)
        // Metadata records the v1 state: no page metadata contract.
        let metadata = report.sections.first { $0.section == .metadata }
        #expect(metadata?.status.isClean == true)
        #expect(metadata?.dialectLimits.contains("D19: no page metadata contract exists in v1; metadata validation is off") == true)
        // Judgment audits are explicitly not checked, never clean.
        let audits = report.sections.first { $0.section == .judgmentAudits }
        if case .notChecked = audits?.status {} else {
            Issue.record("judgment audits must be notChecked in v1")
        }
        // The detector revision is stamped on the report.
        #expect(report.detectorRevision == LintPreflightReport.detectorRevision)
        // Snapshot fingerprint keys the audit to exact bytes.
        #expect(report.bodyFingerprint == LintPageSnapshot.fingerprint(of: "# Clean\n\nA healthy page with `code` and [[Calvin Cycle]]."))
    }

    /// The inventory identifies EVERY occurrence — tables, citations, raw
    /// URLs, footnote references AND definitions, fences — never deduplicated.
    @Test func inventoryCountsOccurrences() {
        let body = """
        See [[source:Smith2023]] twice: [[source:Smith2023]].

        | A | B |
        |---|---|
        | 1 | 2 |

        Raw: https://example.org/report

        Note.[^fn1]

        [^fn1]: [[source:01HZSRC1000000000000000001#"quoted"]]

        ```mermaid
        flowchart LR
        ```
        """
        let report = scan(body)
        let totals = report.inventoryTotals
        #expect(totals.tables == 1)
        // Three citation occurrences (two in the body + one footnote definition).
        #expect(totals.sourceCitations == 3)
        #expect(totals.rawURLs == 1)
        #expect(totals.footnoteReferences == 1)
        #expect(totals.footnoteDefinitions == 1)
        #expect(totals.fences == 1)
        // Occurrence IDs are stable per-kind, 1-based, source-ordered.
        let citations = report.inventory.filter { $0.kind == .sourceCitation }
        #expect(citations.map(\.occurrenceID) == ["sourceCitation-1", "sourceCitation-2", "sourceCitation-3"])
    }

    // MARK: - D25 whole-body fence wrap

    /// A whole-body ` ```markdown ` wrap yields SEPARATE opening/closing
    /// deletion candidates (the most frequent D01 form, fully mechanical).
    @Test func wholeBodyWrapProducesBothCandidates() {
        let body = """
        ```markdown
        # Title

        See [[Calvin Cycle]].
        ```
        """
        let report = scan(body)
        let wraps = findings(report, .fenceBoundaries).filter { $0.defectClass == .wholeBodyFenceWrap }
        #expect(wraps.count == 2)
        #expect(wraps.allSuggest { if case .deletion = $0.candidateRepair?.change { return true }; return false })
        #expect(wraps[0].occurrenceID != wraps[1].occurrenceID)
        // Both confirmed, critical: the body renders as literal text.
        #expect(wraps.allSuggest { $0.confidence == .confirmed && $0.severity == .critical })
    }

    /// A normal fence with other content is NOT a whole-body wrap; a legal
    /// EOF-closed fence produces no finding at all.
    @Test func legalFencesProduceNoFindings() {
        let withFence = """
        # Title

        ```swift
        let a = 1
        ```

        More prose.
        """
        #expect(findings(scan(withFence), .fenceBoundaries).isEmpty)

        let eofClosed = """
        # Title

        ```text
        still open at EOF
        """
        #expect(findings(scan(eofClosed), .fenceBoundaries).isEmpty)
    }

    // MARK: - D06 attempted expressions

    @Test func attemptedWikiExpressionsAreFindings() {
        let body = """
        Empty target: [[ |alias]]

        Valid: [[Calvin Cycle]] and literal `[[Not Live]]`.

        Unclosed at EOF: [[Broken Link
        """
        let report = scan(body)
        let malformed = findings(report, .wikiReferences).filter { $0.defectClass == .malformedWikiLink }
        #expect(malformed.count == 2, "the unclosed opener and the empty alias are findings; valid and code-protected links are not")
        #expect(malformed.contains { $0.message.contains("Unclosed") })
        #expect(malformed.contains { $0.message.contains("alias") })
        #expect(malformed.allSuggest { $0.confidence == .confirmed })
    }

    // MARK: - D07 / D08 / D10 reference identity

    @Test func missingTargetsAndNamespaceRoles() {
        let body = """
        Missing page: [[Nowhere Page]].

        Missing source: [[source:Ghost2023]].

        Missing chat: [[chat:No Such Chat]].

        Bad embed: ![[Calvin Cycle]].
        """
        let report = scan(body)
        let refs = findings(report, .wikiReferences)
        #expect(refs.filter { $0.defectClass == .brokenTarget }.count == 3)
        let embeds = refs.filter { $0.defectClass == .unsupportedEmbed }
        #expect(embeds.count == 1)
        #expect(embeds[0].evidence.contains("![[Calvin Cycle]]"))
    }

    /// A display name resolving to EXACTLY ONE source yields a candidate
    /// repair that canonicalizes the target while preserving pin, quote,
    /// and alias (REQ-40). An ambiguous name is reported WITHOUT a repair.
    @Test func uniqueSourceNameYieldsCandidateRepair() {
        let body = """
        Unique: [[source:Smith2023@v2#"the effect vanishes"|Smith]].

        Ambiguous: [[source:Shared Name]].

        Canonical already: [[source:01HZSRC1000000000000000001]].
        """
        let report = scan(body)
        let noncanonical = findings(report, .wikiReferences).filter { $0.defectClass == .noncanonicalSourceTarget }
        #expect(noncanonical.count == 2)
        let unique = noncanonical.first { $0.candidateRepair != nil }
        let ambiguous = noncanonical.first { $0.candidateRepair == nil }
        #expect(unique != nil)
        #expect(ambiguous != nil)
        if case .replacement(let text)? = unique?.candidateRepair?.change {
            #expect(text == "[[source:01HZSRC1000000000000000001@v2#\"the effect vanishes\"|Smith]]")
        } else {
            Issue.record("expected a canonicalizing replacement candidate")
        }
        // The canonical citation produces no finding.
        #expect(!noncanonical.contains { $0.evidence.contains("01HZSRC1000000000000000001]]") })
    }

    // MARK: - D22 footnote integrity

    @Test func footnoteDamageDetected() {
        let body = """
        Orphan ref.[^missing] and dup.[^dup]

        [^dup]: First
        [^dup]: Second
        [^lonely]: nobody cites this
        """
        let report = scan(body)
        let footnotes = findings(report, .wikiReferences).filter { $0.defectClass == .footnoteDamage }
        // One undefined reference + one duplicate + one orphan (`[^dup]` is
        // referenced, so it is a duplicate but NOT an orphan).
        #expect(footnotes.count == 3)
        #expect(footnotes.contains { $0.message.contains("never referenced") })
        #expect(footnotes.contains { $0.message.contains("more than once") })
        #expect(footnotes.contains { $0.message.contains("no definition") })
    }
}

extension Array where Element == LintFinding {
    func allSuggest(_ predicate: (LintFinding) -> Bool) -> Bool {
        allSatisfy(predicate)
    }
}
