import Foundation
import WikiFSMarkdown

// MARK: - Footnote check
//
// Findings from `WikiFootnoteAnalysis` (the `rendered`-shared parse):
// - Undefined references: report-only (the reader renders them as plain
//   text; content is not lost).
// - Conflicting duplicate definitions (same normalized label, different
//   authored bytes): report-only — the reader renders only one of them, and
//   which one is a rendering fact lint does not second-guess into a rewrite.
// - Identical duplicate definitions (same normalized label AND identical
//   authored definition content): one explicit safe repair — delete the
//   redundant block, exact bytes shown in preview. Offered only when the
//   redundant block's full authored bytes match the retained definition, so
//   deletion can never drop unique content.
// - Unused definitions: informational — NOT proof of lost content.
//
// Footnote label identity is normalized (whitespace-collapsed, casefolded);
// authored bytes are compared verbatim for the safe repair.

public enum LintFootnoteCheck {

    enum Rule: String {
        case undefinedReference = "footnote-reference-undefined"
        case conflictingDuplicate = "footnote-definition-conflict"
        case redundantDuplicate = "footnote-definition-redundant"
        case unusedDefinition = "footnote-definition-unused"
    }

    enum Recipe: String {
        case redundantDeletion = "redundant-footnote-deletion"
    }

    public static func findings(
        stepID: LintStepID,
        body: String,
        recipes: LintAnalyzer.RecipeLookup
    ) -> [LintFinding] {
        let analysis = WikiFootnoteAnalysis.analyze(body)
        var findings: [LintFinding] = []
        var sequence = 0
        func nextID(_ prefix: String) -> LintFindingID {
            sequence += 1
            return LintFindingID(rawValue: "\(prefix)-\(sequence)")
        }
        func passage(_ range: MarkdownSourceRange, expected body: String) -> LintSourceRange? {
            let view = body.utf8
            guard range.upperBound <= view.count else { return nil }
            let lower = view.index(view.startIndex, offsetBy: range.lowerBound)
            let upper = view.index(lower, offsetBy: range.count)
            let text = String(decoding: view[lower..<upper], as: UTF8.self)
            return try? LintSourceRange(
                lowerBound: range.lowerBound, upperBound: range.upperBound,
                expectedText: text, in: body)
        }

        // Undefined references: report-only.
        for reference in analysis.undefinedReferences {
            guard let anchor = passage(reference.range, expected: body) else { continue }
            findings.append(LintFinding(
                id: nextID("fn-undefined"),
                stepID: stepID,
                ruleID: LintRuleID(rawValue: Rule.undefinedReference.rawValue),
                severity: .warning,
                message: "Footnote reference [^\(reference.label)] has no definition — the "
                    + "reader renders it as plain text.",
                evidence: reference.label,
                scope: .passage([anchor]),
                repairOptions: []))
        }

        // Duplicate definitions.
        for group in analysis.duplicateGroups {
            let retained = group[0]
            let redundant = Array(group.dropFirst())
            let identical = redundant.filter { $0.markdown == retained.markdown }
            let conflicting = redundant.filter { $0.markdown != retained.markdown }

            // Conflicting duplicates: report-only.
            for definition in conflicting {
                guard let anchor = passage(definition.range, expected: body) else { continue }
                findings.append(LintFinding(
                    id: nextID("fn-conflict"),
                    stepID: stepID,
                    ruleID: LintRuleID(rawValue: Rule.conflictingDuplicate.rawValue),
                    severity: .warning,
                    message: "Footnote [^\(definition.label)] is defined more than once with "
                        + "DIFFERENT content — the reader renders only one definition. Merge "
                        + "them deliberately; lint does not choose.",
                    evidence: definition.markdown,
                    scope: .passage([anchor]),
                    repairOptions: []))
            }

            // Identical duplicates: one safe repair per redundant copy.
            let recipe = recipes.resolve(.redundantFootnoteDeletion)
            for definition in identical {
                guard let anchor = passage(definition.range, expected: body) else { continue }
                guard let blockAnchor = passage(definition.blockRange, expected: body) else {
                    continue
                }
                let fix = LintIndividualFix(range: blockAnchor, insertText: "")
                findings.append(LintFinding(
                    id: nextID("fn-duplicate"),
                    stepID: stepID,
                    ruleID: LintRuleID(rawValue: Rule.redundantDuplicate.rawValue),
                    severity: .warning,
                    message: "Footnote [^\(definition.label)] is defined again with content "
                        + "identical to the earlier definition — the second definition is "
                        + "redundant and can be removed.",
                    evidence: definition.markdown,
                    scope: .passage([anchor]),
                    repairOptions: recipe.map {
                        [LintRepairOption(
                            id: LintOptionID(rawValue: "fn-del-\($0.rawValue)"),
                            recipeID: $0, label: "Remove redundant footnote")]
                    } ?? [],
                    builtinFix: fix))
            }
        }

        // Unused definitions: informational only.
        for definition in analysis.unusedDefinitions {
            guard let anchor = passage(definition.range, expected: body) else { continue }
            findings.append(LintFinding(
                id: nextID("fn-unused"),
                stepID: stepID,
                ruleID: LintRuleID(rawValue: Rule.unusedDefinition.rawValue),
                severity: .info,
                message: "Footnote [^\(definition.label)] is defined but never referenced. "
                    + "This is informational — it does not mean content was lost.",
                evidence: definition.markdown,
                scope: .passage([anchor]),
                repairOptions: []))
        }
        return findings
    }
}
