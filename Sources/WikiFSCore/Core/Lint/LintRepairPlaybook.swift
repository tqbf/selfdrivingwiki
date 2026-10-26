import Foundation

/// The per-class lint repair playbook (`prompts/lint-repair-playbook.md`):
/// one short imperative entry per defect class, keyed by its `### Dxx`
/// heading. A per-finding repair prompt carries ONLY its target class's
/// entry — class-specific rules with explicit never-lines, not generic
/// advice. Repairable classes carry repair rules; report-only and
/// out-of-scope classes carry a report-never-repair rule.
///
/// The prose lives in markdown like every other prompt; this type only
/// splits it by class token. `LintPromptContractTests` pins that every
/// class has an entry, so a class added to `LintDefectClass` without one
/// fails the gate instead of silently rendering no rules.
public enum LintRepairPlaybook {

    /// The heading prefix that opens one class's entry.
    static let entryHeadingPrefix = "### "

    /// The entry for one class (trimmed), or `nil` when the playbook has
    /// none.
    public static func entry(for defectClass: LintDefectClass) -> String? {
        entries(in: GeneratedPrompts.lintRepairPlaybook)[defectClass.rawValue]
    }

    /// Every entry in a playbook text, keyed by class token. Text before
    /// the first entry heading (the file's preamble) belongs to no class.
    static func entries(in text: String) -> [String: String] {
        var entries: [String: String] = [:]
        var token: String?
        var lines: [String] = []
        func close() {
            guard let token else { return }
            let body = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty == false { entries[token] = body }
        }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(entryHeadingPrefix) {
                close()
                token = String(line.dropFirst(entryHeadingPrefix.count))
                    .trimmingCharacters(in: .whitespaces)
                lines = []
            } else if token != nil {
                lines.append(line)
            }
        }
        close()
        return entries
    }
}
