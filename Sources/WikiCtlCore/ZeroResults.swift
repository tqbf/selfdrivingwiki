import Foundation

/// The zero-results notice for wikictl's list/search verbs (issue #1230).
///
/// axi.md principle 5 (definitive empty states): "When the answer is
/// 'nothing', say so explicitly. Ambiguous empty output causes agents to
/// re-run with different flags to verify." A zero-row list or search used to
/// print nothing at all, which an agent cannot tell apart from a silent
/// failure without reasoning about exit codes.
///
/// The notice goes to STDERR (issue #1230's contract, consistent with axi.md
/// principle 6's channel discipline): wikictl's stdout is a parseable TSV /
/// JSON-lines compatibility contract, so stdout keeps its exact bytes — empty
/// on a zero-row TSV run, an empty JSON-lines stream for `--json` — while the
/// notice removes the ambiguity. The exit code stays 0: empty is a success,
/// not an error.
///
/// The notice names what was searched — the kind, plus any filter value that
/// determined the emptiness (the `--query`, the workspace id) — so "0
/// results" is unmistakably the answer, with context.
public enum ZeroResults {

    /// The exact stderr line a zero-result run prints, including the
    /// trailing newline (the same convention as `PageCommand`'s
    /// `head_version_id:` stderr diagnostic — command code returns the
    /// newline-terminated string; the process layer writes it verbatim).
    ///
    /// `commandPhrase` is the verb plus any filter values, e.g.
    /// `page search "electric cars"` — quote free-form values with
    /// `debugDescription` at the call site so any query round-trips.
    public static func note(_ commandPhrase: String) -> String {
        "wikictl: 0 results for \(commandPhrase)\n"
    }
}
