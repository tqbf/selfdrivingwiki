import Foundation

/// A small, pure shell-word splitter/joiner for the Agents Settings command
/// field (Phase 3 of `plans/acp-multi-provider.md`). Users type a single
/// command line (e.g. `bun x @agentclientprotocol/claude-agent-acp`) and we
/// store it as `AgentProvider.command: [String]?` argv. NOT a full POSIX shell
/// parser — no globbing, no `$VAR` expansion, no command substitution — just
/// enough quoting/escaping to let an executable path or argument contain a
/// space (`"/path with spaces/bin" --flag`).
///
/// Rules:
/// - Whitespace (space/tab/newline) separates words, except inside quotes.
/// - Single quotes (`'…'`) take everything literally — no escapes recognized.
/// - Double quotes (`"…"`) allow `\"` and `\\` escapes; other backslashes are
///   literal.
/// - Outside quotes, a backslash escapes the next character (including a
///   space, letting `\ ` embed a space in an unquoted word).
/// - An unterminated quote consumes to end of input (best-effort; never
///   throws — this is a Settings text field, not a validator).
public enum ShellWords {

    /// Split a single command-line string into argv words.
    public static func split(_ input: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasCurrent = false
        var iterator = input.makeIterator()

        enum Quote { case none, single, double }
        var quote: Quote = .none

        func flush() {
            if hasCurrent {
                words.append(current)
                current = ""
                hasCurrent = false
            }
        }

        while let ch = iterator.next() {
            switch quote {
            case .none:
                if ch == " " || ch == "\t" || ch == "\n" {
                    flush()
                } else if ch == "'" {
                    quote = .single
                    hasCurrent = true
                } else if ch == "\"" {
                    quote = .double
                    hasCurrent = true
                } else if ch == "\\" {
                    if let next = iterator.next() {
                        current.append(next)
                        hasCurrent = true
                    }
                } else {
                    current.append(ch)
                    hasCurrent = true
                }
            case .single:
                if ch == "'" {
                    quote = .none
                } else {
                    current.append(ch)
                }
            case .double:
                if ch == "\"" {
                    quote = .none
                } else if ch == "\\" {
                    if let next = iterator.next() {
                        if next == "\"" || next == "\\" {
                            current.append(next)
                        } else {
                            current.append(ch)
                            current.append(next)
                        }
                    } else {
                        current.append(ch)
                    }
                } else {
                    current.append(ch)
                }
            }
        }
        flush()
        return words
    }

    /// Join argv words back into a single display/editable string, quoting any
    /// word that contains whitespace or a quote character so a round-trip
    /// through `split` reproduces the same argv. Pure inverse of `split` for
    /// the common (no pre-existing escapes) case.
    public static func join(_ words: [String]) -> String {
        words.map { word -> String in
            guard word.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\"" || $0 == "'" }) else {
                return word
            }
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }
}
