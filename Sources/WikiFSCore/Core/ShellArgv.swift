import Foundation

/// Shell-adjacent argv helpers shared by the ACP spawn path: tokenizing a
/// provider's raw args string (`AgentBackendFactory.providerHints`'
/// `acpAgentArgs`, read back by `ACPBackend.resolveSpawnConfig`) and expanding
/// a leading `~` in a PATH-resolvable executable (`AgentLauncher`'s ACP
/// provider spawn resolution). No shell is invoked — these are plain,
/// dependency-free string transforms.
///
/// Split out of the deleted `AgentCommandConfig` (Phase 4 of
/// `plans/acp-multi-provider.md` — the app is ACP-only) since both call sites
/// still need the tokenizer/tilde-expansion, independent of that legacy
/// CLI-backend config type.
public enum ShellArgv {

    /// Tokenize a command-line string into an argv array. Splits on whitespace;
    /// single-quoted (`'…'`), double-quoted (`"…"`), and backslash-escaped
    /// sequences are preserved. No shell is invoked — the result is a plain
    /// `[String]`.
    public static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false

        for ch in s {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" {
                if inSingle {
                    current.append(ch)  // literal backslash inside single quotes
                } else {
                    escape = true
                }
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if ch.isWhitespace && !inSingle && !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        // Flush any trailing escape (literal backslash at end).
        if escape { current.append("\\") }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Expand a leading `~` (or `~user`) to the home directory. Returns the
    /// input unchanged when tilde expansion fails or the path is not tilde-
    /// prefixed.
    public static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return NSString(string: "~").expandingTildeInPath }
        // `~user/rest` or `~/rest` — let Foundation handle both.
        return NSString(string: path).expandingTildeInPath
    }
}
