import Foundation
import WikiFSLinks

// MARK: - History-loss candidate check (report-only)
//
// Compares the captured page body against its CAPTURED PARENT VERSION (the
// head's declared parent — never "the second row of history"). For a
// COMPLETE parent capture it counts candidate losses:
// - lost table blocks (a GFM table present in the parent, absent now),
// - removed source-citation OCCURRENCES, compared by citation IDENTITY
//   (target id/name + version request + fragment) so cosmetic alias edits
//   never count as removals,
// - a substantial body reduction: at least 50 percent AND at least 256
//   non-whitespace Unicode scalars (named constants).
//
// The result is ONE page-scoped review candidate with concrete counts and
// the parent version — a candidate, never proof of damage, and NEVER an
// offered restoration. An incomplete parent capture cannot support complete
// counts or a global size verdict, so it marks the comparison incomplete
// (info) instead. A first version is not a failure — it is simply not
// comparable, and stays silent.

public enum LintHistoryCheck {

    enum Rule: String {
        case lossCandidate = "history-loss-candidate"
        case comparisonIncomplete = "history-comparison-incomplete"
    }

    /// The named reduction thresholds (plan-mandated constants).
    public enum Limits {
        /// Minimum relative reduction to qualify as substantial.
        public static let substantialReductionRatio = 0.5
        /// Minimum absolute reduction, in non-whitespace Unicode scalars.
        public static let minimumReductionScalars = 256
    }

    public static func findings(stepID: LintStepID, snapshot: LintPageSnapshot) -> [LintFinding] {
        guard let parent = snapshot.parent else { return [] }
        switch parent.status {
        case .firstVersion:
            // Nothing to compare; not a failure, no finding.
            return []
        case .captured:
            break
        case .unavailable:
            return [infoFinding(
                stepID: stepID, rule: .comparisonIncomplete, snapshot: snapshot,
                message: "History comparison unavailable — the previous version's row or "
                    + "content is missing from the wiki. This is not treated as a loss.")]
        case .readFailed:
            return [infoFinding(
                stepID: stepID, rule: .comparisonIncomplete, snapshot: snapshot,
                message: "History comparison unavailable — reading the previous version "
                    + "failed.")]
        case .budgetOmitted:
            return [infoFinding(
                stepID: stepID, rule: .comparisonIncomplete, snapshot: snapshot,
                message: "History comparison unavailable — the capture budget was exhausted "
                    + "before the previous version was read.")]
        }

        // An incomplete parent capture cannot support complete counts or a
        // global size verdict for this first implementation.
        guard parent.completeness?.isComplete == true,
              let parentBody = parent.text else {
            return [infoFinding(
                stepID: stepID, rule: .comparisonIncomplete, snapshot: snapshot,
                message: "History comparison incomplete — only the first "
                    + "\(parent.text?.utf8.count ?? 0) bytes of the previous version were "
                    + "captured, so no complete loss counts are claimed.")]
        }

        // Citation identities (order-insensitive occurrence counts).
        let currentCitations = citationIdentities(in: snapshot.body)
        let parentCitations = citationIdentities(in: parentBody)
        var removedCitations = 0
        var pool = currentCitations
        for identity in parentCitations {
            if let at = pool.firstIndex(of: identity) {
                pool.remove(at: at)
            } else {
                removedCitations += 1
            }
        }

        // Table blocks.
        let parentTables = tableBlockCount(in: parentBody)
        let currentTables = tableBlockCount(in: snapshot.body)
        let lostTables = max(0, parentTables - currentTables)

        // Substantial body reduction.
        let parentScalars = nonWhitespaceScalarCount(parentBody)
        let currentScalars = nonWhitespaceScalarCount(snapshot.body)
        let reduction = max(0, parentScalars - currentScalars)
        let ratio = parentScalars > 0
            ? Double(reduction) / Double(parentScalars)
            : 0
        let substantial = ratio >= Limits.substantialReductionRatio
            && reduction >= Limits.minimumReductionScalars

        guard lostTables > 0 || removedCitations > 0 || substantial else { return [] }

        var parts: [String] = []
        if lostTables > 0 { parts.append("\(lostTables) table block(s) removed") }
        if removedCitations > 0 {
            parts.append("\(removedCitations) source citation occurrence(s) removed")
        }
        if substantial {
            parts.append(String(
                format: "body reduced by %d of %d non-whitespace characters (%.0f%%)",
                reduction, parentScalars, ratio * 100))
        }
        let version = parent.parentVersionID.map { $0.rawValue } ?? "(unknown)"
        return [LintFinding(
            id: LintFindingID(rawValue: "history-loss-1"),
            stepID: stepID,
            ruleID: LintRuleID(rawValue: Rule.lossCandidate.rawValue),
            severity: .info,
            message: "Compared with the previous version, this edit removes: "
                + parts.joined(separator: "; ") + ". This is a review candidate — a "
                + "deliberate edit can look exactly like this. Lint never restores "
                + "content automatically.",
            evidence: "parent version: \(version)",
            scope: .page,
            repairOptions: [])]
    }

    // MARK: - Comparisons

    /// Citation identities in document order: (target, version request,
    /// fragment) triples. Alias and visible text are deliberately NOT part
    /// of identity — renaming an alias must not look like a removal.
    static func citationIdentities(in body: String) -> [String] {
        LintCitationOccurrence.parseAll(in: body).map { occurrence -> String in
            let target: String
            if let canonical = occurrence.canonicalSourceID {
                target = canonical.uppercased()
            } else if let name = occurrence.sourceName {
                target = name.lowercased()
            } else {
                target = ""
            }
            let request: String
            switch occurrence.request {
            case .active: request = "active"
            case .pinned(let pin): request = "v\(pin.ordinal)"
            case .invalidPin(let literal): request = "invalid:\(literal)"
            }
            let fragment = occurrence.quote ?? occurrence.headingFragment ?? ""
            return "\(target)|\(request)|\(fragment)"
        }
    }

    /// The number of GFM table blocks (a header row + a delimiter row).
    static func tableBlockCount(in body: String) -> Int {
        let lines = body.components(separatedBy: "\n")
        var count = 0
        var index = 0
        while index + 1 < lines.count {
            let delimiter = LintTableCheck.delimiterColumns(lines[index + 1])
            if delimiter != nil,
               lines[index].trimmingCharacters(in: .whitespaces).contains("|"),
               LintTableCheck.cellCount(lines[index]) == delimiter {
                count += 1
                // Skip the table's body rows.
                index += 2
                while index < lines.count,
                      isTableRowCandidate(lines[index]) {
                    index += 1
                }
                continue
            }
            index += 1
        }
        return count
    }

    /// A candidate table body row: any line containing a pipe.
    static func isTableRowCandidate(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).contains("|")
    }

    static func nonWhitespaceScalarCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter { !$0.properties.isWhitespace }.count
    }

    private static func infoFinding(
        stepID: LintStepID, rule: Rule, snapshot: LintPageSnapshot, message: String
    ) -> LintFinding {
        LintFinding(
            id: LintFindingID(rawValue: "history-\(rule.rawValue)-1"),
            stepID: stepID,
            ruleID: LintRuleID(rawValue: rule.rawValue),
            severity: .info,
            message: message,
            evidence: nil,
            scope: .page,
            repairOptions: [])
    }
}
