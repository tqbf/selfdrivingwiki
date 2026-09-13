import Foundation

/// Removal policy for the known ACP skill-description budget preamble.
///
/// - `streamingPrefixAware`: hides the complete warning AND a still-streaming
///   proper prefix of it, so a warning-only reply never flashes before the
///   sentence finishes arriving. Reserved for assistant rows that are
///   currently streaming in the normal chat surface.
/// - `completeOnly`: removes only the COMPLETE known warning. A final text
///   that is merely a proper prefix of the warning is preserved verbatim,
///   because a finished message that short is content we cannot explain
///   away. Used for final rows, Markdown exports, summaries, and cached
///   outline text.
public enum AgentPresentationPreambleWarningPolicy: Hashable, Sendable {
    case streamingPrefixAware
    case completeOnly
}

/// Pure cleanup of the one known agent preamble: the ACP skills-budget
/// warning that some backends prepend to assistant text.
///
/// Scope discipline (plans/chat-tool-call-summary.md):
/// - Only the exact known warning family is removed — a line that starts with
///   `Warning: Skill descriptions were shortened to fit the 2% skills context
///   budget.` Any other `Warning:` line is unrelated content and is preserved.
/// - A complete match removes the warning line plus the blank lines that
///   follow it; substantive text after the warning is preserved.
/// - A warning-only message cleans to `nil` (no visible text), so callers can
///   drop the row instead of rendering a blank block.
/// - Neither policy ever mutates durable events, diagnostics, or the Activity
///   transcript; callers opt in at presentation and export boundaries only.
public enum AgentPresentationPreamble {

    /// The exact opening sentence of the known warning. A line matching this
    /// prefix belongs to the known family even when trailing bytes (a
    /// trailing space, or a provider-specific suffix) follow the sentence.
    public static let knownWarningSentence =
        "Warning: Skill descriptions were shortened to fit the 2% skills context budget."

    /// Returns the text with the known warning removed under `policy`, or nil
    /// when no visible text remains. PURE.
    public static func visibleText(
        _ text: String,
        policy: AgentPresentationPreambleWarningPolicy
    ) -> String? {
        guard text.isEmpty == false else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let firstContentIndex = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty == false
        }) else {
            // Whitespace-only text has nothing visible under either policy.
            return nil
        }

        let firstContentLine = lines[firstContentIndex].trimmingCharacters(in: .whitespaces)

        // Near-miss canary: a line that OPENS like the skills-budget banner
        // but is not the exact known sentence means the vendor reworded it.
        // Surface it in diagnostics instead of silently preserving new banner
        // text in titles, summaries, and exports.
        if firstContentLine.hasPrefix("Warning: Skill descriptions"),
           !firstContentLine.hasPrefix(knownWarningSentence) {
            DebugLog.chatLive("AgentPresentationPreamble: unrecognized 'Warning: Skill descriptions' variant — the banner may have been reworded; preserved verbatim: \(firstContentLine.prefix(140))")
        }

        if firstContentLine.hasPrefix(knownWarningSentence) {
            return remainder(afterWarningLineAt: firstContentIndex, in: lines)
        }

        if policy == .streamingPrefixAware,
           knownWarningSentence.hasPrefix(firstContentLine),
           lines[(firstContentIndex + 1)...].allSatisfy({ line in
               line.trimmingCharacters(in: .whitespaces).isEmpty
           }) {
            // The reply is still arriving and currently spells a proper
            // prefix of the warning. Suppress it so the warning never
            // flashes; once the sentence completes (or content follows), the
            // complete-match and preservation rules above take over.
            return nil
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text after a complete warning line: drop the leading blank lines that
    /// follow it, trim surrounding whitespace, and collapse to nil when
    /// nothing substantive remains.
    private static func remainder(
        afterWarningLineAt warningIndex: Int,
        in lines: [String]
    ) -> String? {
        var remaining = lines[(warningIndex + 1)...]
        while let first = remaining.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty {
            remaining = remaining.dropFirst()
        }
        let joined = remaining.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
