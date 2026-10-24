import Foundation
import WikiFSMarkdown

/// The ten named audit steps every selected-page run must perform and report
/// (REQ-29 — the numbered list, not the draft outline's stale nine-count).
public enum LintAuditStep: String, CaseIterable, Sendable {
    case readBodyAndHead
    case auditBlockBoundaries
    case auditMarkdownStructure
    case auditEveryReference
    case auditContentIntegrity
    case auditHistoryRegression
    case auditMetadata
    case chooseMinimalRepairs
    case writeAndVerify
    case logAndReport

    /// The user-facing check name used in prompts and reports.
    public var title: String {
        switch self {
        case .readBodyAndHead: return "Read current body and head"
        case .auditBlockBoundaries: return "Audit block boundaries"
        case .auditMarkdownStructure: return "Audit Markdown structure"
        case .auditEveryReference: return "Audit every reference"
        case .auditContentIntegrity: return "Audit content integrity"
        case .auditHistoryRegression: return "Audit regression against the previous head"
        case .auditMetadata: return "Audit applicable metadata"
        case .chooseMinimalRepairs: return "Choose minimal repairs"
        case .writeAndVerify: return "Write and verify"
        case .logAndReport: return "Log and report"
        }
    }

    /// The one-line instruction the lint-page prompt carries for this step.
    public var instruction: String {
        switch self {
        case .readBodyAndHead:
            return "Read the current body and head; record the exact snapshot you audited."
        case .auditBlockBoundaries:
            return "Check fences, whole-body wrap, code context, truncated endings, and leaked prose."
        case .auditMarkdownStructure:
            return "Check tables, list membership, headings, and broken inline constructs."
        case .auditEveryReference:
            return "Check all wiki namespaces, source identity, aliases, anchors, pins, embeds, footnotes, media, and reference labels."
        case .auditContentIntegrity:
            return "Check accidental residue, duplication, encoding and escaping damage, meta-text leakage, and pasted active content."
        case .auditHistoryRegression:
            return "Check for unexplained shrinkage and dropped tables, citations, sections, and footnotes."
        case .auditMetadata:
            return "Record that no page metadata contract applies in v1."
        case .chooseMinimalRepairs:
            return "Emit hunks with defect classes; reject editorial changes; list report-only candidates without rewriting them; record unresolved cases."
        case .writeAndVerify:
            return "Submit hunks through the patch write under CAS; the app re-runs pre-flight on the written head; your readback provides context only."
        case .logAndReport:
            return "Account for each inventory item, finding, and audit step in the required report."
        }
    }

    /// The kebab-case token the fixed report format uses for this step.
    public var reportToken: String {
        rawValue.replacingOccurrences(of: "([A-Z])", with: "-$1", options: .regularExpression)
            .lowercased()
    }
}

/// One audit step's recorded outcome. Exactly one per step; a step may never
/// claim `repaired` (that outcome belongs to findings, not to checks).
public struct LintAuditStepOutcome: Equatable, Sendable {
    public let step: LintAuditStep
    public let outcome: LintFindingOutcome

    public init(step: LintAuditStep, outcome: LintFindingOutcome) {
        self.step = step
        self.outcome = outcome
    }

    /// A step outcome is valid when it is not `repaired` and every
    /// reason-bearing outcome actually carries a reason.
    var isValid: Bool {
        switch outcome {
        case .repaired:
            return false
        case .validAsWritten(let reason), .unresolved(let reason),
             .outsideLintScope(let reason), .checkBlocked(let reason):
            return reason.trimmingCharacters(in: .whitespaces).isEmpty == false
        }
    }
}

// MARK: - Run report text (fixed-format, harness-parseable)

/// The fixed plain-text format of the agent's per-page audit report (plan
/// §5.6): fixed section lines with stable labels, one outcome line per
/// inventory item and finding. Durable wiki logs stay plain text — this adds
/// no machine-readable fields to the log, it is the strict format the
/// coverage harness parses.
public enum LintRunReportText {

    /// The format revision marker on the first line.
    public static let formatMarker = "lint-run-report v1"

    /// Render the report skeleton the agent must fill in: page/head
    /// identity, inventory counts, one line per check, and one prepared line
    /// per inventory occurrence and finding (outcome `unresolved pending` is
    /// NOT valid — the agent replaces `pending` with a real outcome).
    public static func render(
        snapshot: LintPageSnapshot,
        preflight: LintPreflightReport
    ) -> String {
        var lines: [String] = []
        lines.append(formatMarker)
        lines.append("page \(snapshot.pageID.rawValue)")
        lines.append("head \(snapshot.headVersionID?.rawValue ?? "none")")
        lines.append("fingerprint \(snapshot.bodyFingerprint)")
        let totals = preflight.inventoryTotals
        lines.append("inventory tables \(totals.tables)")
        lines.append("inventory source-citations \(totals.sourceCitations)")
        lines.append("inventory raw-urls \(totals.rawURLs)")
        lines.append("inventory footnote-references \(totals.footnoteReferences)")
        lines.append("inventory footnote-definitions \(totals.footnoteDefinitions)")
        lines.append("inventory fences \(totals.fences)")
        for step in LintAuditStep.allCases {
            lines.append("check \(step.reportToken) pending")
        }
        for item in preflight.inventory {
            lines.append("item \(item.occurrenceID) pending")
        }
        for finding in preflight.sections.flatMap(\.findings) {
            lines.append("finding \(finding.occurrenceID) pending")
        }
        lines.append("verification none pending")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// One parsed outcome line from the agent's run report.
public struct LintRunReportEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case check(LintAuditStep)
        case item(String)
        case finding(String)
    }

    public let kind: Kind
    public let outcome: LintFindingOutcome
}

/// The verification line's parsed fields.
public struct LintRunVerificationLine: Equatable, Sendable {
    /// The written head the agent reports (`nil` = it reported `none`).
    public let writtenHead: String?
    /// The agent's verdict token (the harness recomputes it — this is the
    /// agent's claim, never the app-side gate's verdict).
    public let verdict: String

    public init(writtenHead: String?, verdict: String) {
        self.writtenHead = writtenHead
        self.verdict = verdict
    }
}

/// The strictly parsed agent run report.
public struct ParsedLintRunReport: Equatable, Sendable {
    public let pageID: PageID
    public let headVersionID: PageVersionID?
    public let bodyFingerprint: String
    public let inventoryCounts: LintInventoryTotals
    public let entries: [LintRunReportEntry]
    /// The verification line's raw fields; `nil` while unfilled.
    public let verification: LintRunVerificationLine?

    public init(
        pageID: PageID,
        headVersionID: PageVersionID?,
        bodyFingerprint: String,
        inventoryCounts: LintInventoryTotals,
        entries: [LintRunReportEntry],
        verification: LintRunVerificationLine?
    ) {
        self.pageID = pageID
        self.headVersionID = headVersionID
        self.bodyFingerprint = bodyFingerprint
        self.inventoryCounts = inventoryCounts
        self.entries = entries
        self.verification = verification
    }
}

public enum LintRunReportParseError: Equatable, Error {
    case missingFormatMarker
    case malformedLine(line: Int, text: String)
    case duplicateLine(String)
    case missingHead
}

extension LintRunReportParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingFormatMarker:
            return "the report does not begin with the required format marker"
        case .malformedLine(_, let text):
            return "malformed report line: \(text)"
        case .duplicateLine(let key):
            return "duplicate report line for \(key)"
        case .missingHead:
            return "the report is missing its head line"
        }
    }
}

/// The strict parser for ``LintRunReportText`` output. Unknown lines fail —
/// the format is fixed so coverage accounting cannot be evaded with prose.
public enum LintRunReportParser {

    /// Parse the report text. Throws on any deviation from the format.
    public static func parse(_ text: String) throws -> ParsedLintRunReport {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.first == LintRunReportText.formatMarker else {
            throw LintRunReportParseError.missingFormatMarker
        }

        var pageID: PageID?
        var head: PageVersionID?
        var fingerprint: String?
        var totals = LintInventoryTotals()
        var entries: [LintRunReportEntry] = []
        var verification: LintRunVerificationLine?
        var seenKeys: Set<String> = []

        for (index, line) in lines.enumerated().dropFirst() {
            let tokens = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
                .map(String.init)
            guard let label = tokens.first else {
                throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
            }
            switch label {
            case "page":
                guard tokens.count >= 2, pageID == nil else {
                    throw LintRunReportParseError.duplicateLine("page")
                }
                pageID = PageID(rawValue: tokens[1])
            case "head":
                guard tokens.count >= 2, !seenKeys.contains("head") else {
                    throw LintRunReportParseError.duplicateLine("head")
                }
                seenKeys.insert("head")
                head = tokens[1] == "none" ? nil : PageVersionID(rawValue: tokens[1])
            case "fingerprint":
                guard tokens.count >= 2, !seenKeys.contains("fingerprint") else {
                    throw LintRunReportParseError.duplicateLine("fingerprint")
                }
                seenKeys.insert("fingerprint")
                fingerprint = tokens[1]
            case "inventory":
                guard tokens.count >= 3 else {
                    throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
                }
                let key = tokens[1]
                guard !seenKeys.contains("inventory \(key)") else {
                    throw LintRunReportParseError.duplicateLine("inventory \(key)")
                }
                seenKeys.insert("inventory \(key)")
                guard let count = Int(tokens[2]) else {
                    throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
                }
                switch key {
                case "tables": totals.tables = count
                case "source-citations": totals.sourceCitations = count
                case "raw-urls": totals.rawURLs = count
                case "footnote-references": totals.footnoteReferences = count
                case "footnote-definitions": totals.footnoteDefinitions = count
                case "fences": totals.fences = count
                default:
                    throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
                }
            case "check":
                guard tokens.count >= 3,
                      let step = LintAuditStep.allCases.first(where: { $0.reportToken == tokens[1] }) else {
                    throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
                }
                // Duplicate check/item/finding lines are NOT parse errors —
                // they parse and the COVERAGE VALIDATOR rejects them (REQ-31),
                // keeping one authority for accounting failures.
                entries.append(LintRunReportEntry(
                    kind: .check(step),
                    outcome: try parseOutcome(tokens, from: 2, line: line)))
            case "item", "finding":
                guard tokens.count >= 3 else {
                    throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
                }
                let occurrenceID = tokens[1]
                entries.append(LintRunReportEntry(
                    kind: label == "item" ? .item(occurrenceID) : .finding(occurrenceID),
                    outcome: try parseOutcome(tokens, from: 2, line: line)))
            case "verification":
                guard !seenKeys.contains("verification") else {
                    throw LintRunReportParseError.duplicateLine("verification")
                }
                seenKeys.insert("verification")
                guard tokens.count >= 3 else {
                    throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
                }
                let writtenHead = tokens[1] == "none" ? nil : tokens[1]
                verification = LintRunVerificationLine(writtenHead: writtenHead, verdict: tokens[2])
            default:
                throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
            }
        }

        guard let pageID else { throw LintRunReportParseError.malformedLine(line: 0, text: "page") }
        guard seenKeys.contains("head") else { throw LintRunReportParseError.missingHead }
        return ParsedLintRunReport(
            pageID: pageID,
            headVersionID: head,
            bodyFingerprint: fingerprint ?? "",
            inventoryCounts: totals,
            entries: entries,
            verification: verification)
    }

    /// Outcome token: `<name>` or `<name>|<reason>` (reason carries the rest
    /// of the line, `|`-separated so reasons may contain spaces).
    private static func parseOutcome(
        _ tokens: [String],
        from index: Int,
        line: String
    ) throws -> LintFindingOutcome {
        let token = tokens[index]
        let (name, reason): (String, String)
        if let bar = token.firstIndex(of: "|") {
            // The reason is everything after the first `|` and may contain
            // spaces (the line split's last token keeps the remainder).
            name = String(token[token.startIndex..<bar])
            reason = String(token[token.index(after: bar)...])
        } else {
            name = token
            reason = ""
        }
        switch name {
        case "repaired": return .repaired
        case "valid-as-written": return .validAsWritten(reason: reason)
        case "unresolved": return .unresolved(reason: reason)
        case "outside-scope": return .outsideLintScope(reason: reason)
        case "blocked": return .checkBlocked(reason: reason)
        default:
            // Unknown outcome tokens — including the skeleton's own
            // `pending` — are malformed lines. An UNFILLED skeleton must be
            // a parse error, never a silently-accepted report (plan §5.7's
            // checklist-theater defense).
            throw LintRunReportParseError.malformedLine(line: index + 1, text: line)
        }
    }
}

// MARK: - Coverage validation (REQ-31/32)

/// The coverage-verdict the harness computes for one agent report.
public enum LintCoverageVerdict: Equatable, Sendable {
    /// Every inventory item, finding, and audit step has exactly one valid
    /// outcome and the identity matches the audited snapshot.
    case complete
    /// Named accounting failures; the run cannot claim a clean audit.
    case rejected(reasons: [String])
}

/// REQ-31/32 coverage validation: exact item identity, not counts alone.
/// Rejects omitted, duplicated, unknown, wrong-head, and contradictory
/// outcomes, and requires every named audit step.
public enum LintCoverageValidator {

    public static func validate(
        parsed: ParsedLintRunReport,
        snapshot: LintPageSnapshot,
        preflight: LintPreflightReport
    ) -> LintCoverageVerdict {
        var reasons: [String] = []

        // Identity: the report must name THIS page at THIS head.
        if parsed.pageID != snapshot.pageID {
            reasons.append("report names page \(parsed.pageID.rawValue), not the audited \(snapshot.pageID.rawValue)")
        }
        if parsed.headVersionID != snapshot.headVersionID {
            let reported = parsed.headVersionID?.rawValue ?? "none"
            let expected = snapshot.headVersionID?.rawValue ?? "none"
            reasons.append("report names head \(reported), not the inspected \(expected)")
        }

        // Inventory counts must match the pre-flight's complete inventory.
        let expectedTotals = preflight.inventoryTotals
        if parsed.inventoryCounts != expectedTotals {
            reasons.append(
                "inventory counts \(parsed.inventoryCounts.summary) do not match the pre-flight inventory \(expectedTotals.summary)")
        }

        // Every inventory occurrence and every finding needs exactly one
        // outcome; unknown IDs and duplicates are rejections.
        var expectedIDs: Set<String> = Set(preflight.inventory.map(\.occurrenceID))
        for finding in preflight.sections.flatMap(\.findings) {
            expectedIDs.insert(finding.occurrenceID)
        }
        var covered: Set<String> = []
        for entry in parsed.entries {
            switch entry.kind {
            case .check:
                continue
            case .item(let id), .finding(let id):
                guard expectedIDs.contains(id) else {
                    reasons.append("outcome for unknown occurrence \(id)")
                    continue
                }
                guard covered.insert(id).inserted else {
                    reasons.append("duplicate outcome for \(id)")
                    continue
                }
                // Reason-bearing outcomes need their reason on items and
                // findings too — `valid-as-written` with no reason is an
                // unfilled line, not an accounted one.
                if entry.outcome.requiresReason {
                    switch entry.outcome {
                    case .validAsWritten(let r), .unresolved(let r),
                         .outsideLintScope(let r), .checkBlocked(let r):
                        if r.trimmingCharacters(in: .whitespaces).isEmpty {
                            reasons.append("outcome for \(id) requires a reason")
                        }
                    case .repaired: break
                    }
                }
            }
        }
        for missing in expectedIDs.subtracting(covered).sorted() {
            reasons.append("no outcome for \(missing)")
        }

        // The verification line must be FILLED — the skeleton's `pending`
        // verdict is an unfilled form, not a completed audit.
        if let verification = parsed.verification,
           verification.verdict.trimmingCharacters(in: .whitespaces).isEmpty
               || verification.verdict == "pending" {
            reasons.append("verification line is unfilled")
        }

        // Every named audit step, exactly once, with a valid outcome
        // (checks never take `repaired`).
        let checkEntries = parsed.entries.compactMap { entry -> (LintAuditStep, LintFindingOutcome)? in
            if case .check(let step) = entry.kind { return (step, entry.outcome) }
            return nil
        }
        for step in LintAuditStep.allCases {
            let matches = checkEntries.filter { $0.0 == step }
            guard matches.count == 1 else {
                reasons.append("audit step \(step.reportToken) reported \(matches.count) times")
                continue
            }
            let outcome = matches[0].1
            if case .repaired = outcome {
                reasons.append("audit step \(step.reportToken) cannot claim repaired")
            } else if outcome.requiresReason {
                switch outcome {
                case .validAsWritten(let r), .unresolved(let r),
                     .outsideLintScope(let r), .checkBlocked(let r):
                    if r.trimmingCharacters(in: .whitespaces).isEmpty {
                        reasons.append("audit step \(step.reportToken) outcome requires a reason")
                    }
                case .repaired: break
                }
            }
        }

        // Outcomes on report-only classes can never claim repaired.
        for finding in preflight.sections.flatMap(\.findings)
        where finding.defectClass.repairPolicy != .repairable {
            if let entry = parsed.entries.first(where: {
                if case .finding(let id) = $0.kind { return id == finding.occurrenceID }
                return false
            }), case .repaired = entry.outcome {
                reasons.append(
                    "finding \(finding.occurrenceID) is \(finding.defectClass.rawValue) (report-only) and cannot claim repaired")
            }
        }

        if reasons.isEmpty { return .complete }
        return .rejected(reasons: reasons.sorted())
    }
}

// MARK: - Pre/post verification (REQ-54)

/// The app-side verification verdict comparing the pre-repair scan with the
/// scan of the WRITTEN immutable version (never whichever head happens to be
/// current afterward).
public struct LintVerification: Equatable, Sendable {

    public enum Status: Equatable, Sendable {
        /// The written head's scan accounts for every claimed repair and
        /// introduces nothing new; all required checks were available.
        case verified
        /// The written version verified, but the current head has moved —
        /// both facts are recorded, never merged.
        case verifiedWrittenHeadDiverged(currentHead: PageVersionID)
        /// Verification failed; `reasons` name every failure fact.
        case failed(reasons: [String])
    }

    public let status: Status
    /// Findings that survive on the written head (fresh-classified).
    public let remainingFindings: [LintFinding]

    public init(status: Status, remainingFindings: [LintFinding]) {
        self.status = status
        self.remainingFindings = remainingFindings
    }

    /// Compare the pre-repair and written-head scans against the hunks the
    /// server actually applied and the repair claims the coverage-validated
    /// report made. A claimed repair whose defect persists on the written
    /// head, a newly introduced defect, or an unavailable required check
    /// prevents a verified verdict. Findings inside changed text get fresh
    /// classification; findings outside changed ranges must persist
    /// identically — a finding that vanishes without a hunk is unattributed.
    public static func compare(
        before: LintPreflightReport,
        written: LintPreflightReport,
        appliedHunks: [PagePatchHunk],
        claimedRepairFindingIDs: Set<String>,
        writtenHead: PageVersionID?,
        currentHead: PageVersionID?,
        requiredChecksAvailable: Bool
    ) -> LintVerification {
        var reasons: [String] = []

        func identity(_ finding: LintFinding) -> String {
            "\(finding.defectClass.rawValue)|\(finding.evidence)"
        }
        let beforeByID = Dictionary(
            before.sections.flatMap(\.findings).map { (identity($0), $0) },
            uniquingKeysWith: { first, _ in first })
        let writtenIdentities = Set(written.sections.flatMap(\.findings).map(identity))

        // Findings inside hunk ranges were legitimately rewritten.
        func insideHunk(_ finding: LintFinding) -> Bool {
            guard let range = finding.authoredRange else { return false }
            return appliedHunks.contains { hunk in
                range.lowerBound < hunk.endByte && hunk.startByte < range.upperBound
            }
        }

        var remaining: [LintFinding] = []
        for (key, original) in beforeByID {
            let persisted = writtenIdentities.contains(key)
            if persisted {
                remaining.append(original)
                if claimedRepairFindingIDs.contains(original.occurrenceID) {
                    reasons.append(
                        "claimed repair for \(original.occurrenceID) but the finding persists on the written head")
                }
            } else if !insideHunk(original) && original.candidateRepair != nil {
                // A finding vanished from text its hunk never touched — the
                // written content changed in an unattributed way.
                reasons.append("finding \(original.occurrenceID) disappeared outside the applied hunks")
            }
        }
        for fresh in written.sections.flatMap(\.findings) where !beforeByID.keys.contains(identity(fresh)) {
            remaining.append(fresh)
            reasons.append("new finding \(fresh.occurrenceID) on the written head: \(fresh.message)")
        }

        if writtenHead == nil {
            reasons.append("no written head to verify")
        }
        if !requiredChecksAvailable {
            reasons.append("a required verification check was unavailable")
        }

        if let currentHead, currentHead != writtenHead {
            if reasons.isEmpty {
                return LintVerification(
                    status: .verifiedWrittenHeadDiverged(currentHead: currentHead),
                    remainingFindings: remaining.sorted { $0.occurrenceID < $1.occurrenceID })
            }
            reasons.append("current head \(currentHead.rawValue) diverges from written \(writtenHead?.rawValue ?? "none")")
        }
        if reasons.isEmpty {
            return LintVerification(
                status: .verified,
                remainingFindings: remaining.sorted { $0.occurrenceID < $1.occurrenceID })
        }
        return LintVerification(
            status: .failed(reasons: reasons.sorted()),
            remainingFindings: remaining.sorted { $0.occurrenceID < $1.occurrenceID })
    }
}
