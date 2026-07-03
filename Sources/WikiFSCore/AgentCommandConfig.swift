import Foundation

/// Configurable agent invocation — executable, prefix arguments, model override,
/// and extra environment variables. App-wide, not per-wiki: a property of the
/// user's environment, like `ZoteroConfig`.
///
/// Follows the same `Codable` + atomic JSON-in-App-Group-container pattern as
/// `ZoteroConfig` and `WikiRegistry`. Loaded fresh at spawn time so Settings
/// changes apply on the next run without a restart.
public struct AgentCommandConfig: Codable, Equatable, Sendable {

    /// Binary or wrapper script (default `"claude"`). Resolved on the login-shell
    /// PATH, or used directly if absolute / `./` / `../`; `~` is expanded.
    public var executable: String

    /// Args inserted BEFORE the standard flags. Covers `sandbox-exec -f profile.sb
    /// claude` without needing a wrapper script. Stored as a single string
    /// (shell-tokenized at use time); non-nil so Codable round-trips cleanly.
    public var prefixArguments: String

    /// Model override, e.g. `"haiku"`. Blank means use the per-op alias.
    public var modelOverride: String

    /// Extra environment variables as `KEY=VALUE` lines. Merged into the spawned
    /// process environment; app-owned keys (`WIKI_ROOT`, `WIKI_DB`) always win.
    public var extraEnvironment: String

    public init(
        executable: String = "claude",
        prefixArguments: String = "",
        modelOverride: String = "",
        extraEnvironment: String = ""
    ) {
        self.executable = executable
        self.prefixArguments = prefixArguments
        self.modelOverride = modelOverride
        self.extraEnvironment = extraEnvironment
    }

    /// The default config reproduces today's hardcoded `claude -p …` invocation
    /// exactly. Used when no `agent-command-config.json` exists yet.
    public static let `default` = AgentCommandConfig()

    /// The config's JSON filename inside the App Group container.
    public static let fileName = "agent-command-config.json"

    // MARK: - Persistence

    /// Load from `agent-command-config.json` in `directory`. Missing or corrupt
    /// file degrades to `.default` rather than throwing — same fresh-install
    /// behavior as `ZoteroConfig.load`.
    public static func load(from directory: URL) -> AgentCommandConfig {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return .default }
        guard let config = try? JSONDecoder().decode(AgentCommandConfig.self, from: data) else {
            DebugLog.config("AgentCommandConfig: corrupt \(fileName), starting default")
            return .default
        }
        return config
    }

    /// Persist to `agent-command-config.json` in `directory`, atomically,
    /// pretty-printed + sorted keys.
    public func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(AgentCommandConfig.fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Derived values

    /// Resolve the executable: expand `~`, return directly if absolute or
    /// `./`/`../`, otherwise leave as-is for PATH resolution (handled by
    /// `PathPreflight.resolveOnLoginShell`).
    public func resolvedExecutable() -> String {
        Self.expandTilde(executable.isEmpty ? "claude" : executable)
    }

    /// Tokenize `prefixArguments` into an argv array. Empty string → `[]`.
    public func tokenizedPrefixArgs() -> [String] {
        AgentCommandConfig.tokenize(prefixArguments)
    }

    /// Parse `extraEnvironment` into a `[String: String]` dictionary, accepting
    /// bash-style assignment lines:
    ///
    /// - A leading `export ` keyword is stripped (`export FOO=bar` ≡ `FOO=bar`).
    /// - One surrounding layer of quotes is removed: double quotes (`FOO="a b"`)
    ///   or unquoted values get `$VAR`/`${VAR}` expansion; single quotes
    ///   (`FOO='$HOME'`) are taken literally (no expansion), like bash.
    /// - `$NAME` and `${NAME}` references expand against the app process
    ///   environment (bash-style: a referenced-but-unset variable → empty string).
    /// - Lines without `=` and blank lines are skipped.
    ///
    /// App-owned keys (`WIKI_ROOT`, `WIKI_DB`) are not filtered here — the spawn
    /// site merges this dictionary under the app-owned keys so they always win.
    public func parsedExtraEnv() -> [String: String] {
        var env: [String: String] = [:]
        for rawLine in extraEnvironment.components(separatedBy: "\n") {
            var trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Strip a leading `export` keyword. Require whitespace after it so a
            // key literally named `export` (e.g. `export=foo`, a normal
            // assignment) is not mangled.
            if trimmed.hasPrefix("export"),
               let firstAfter = trimmed.dropFirst("export".count).first,
               firstAfter.isWhitespace {
                trimmed = trimmed.dropFirst("export".count)
                    .trimmingCharacters(in: .whitespaces)
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            // One layer of surrounding quotes. Single-quoted → literal; double-
            // quoted / unquoted → expand variable references.
            let expand: Bool
            if value.count >= 2, value.first == "'", value.last == "'" {
                value = String(value.dropFirst().dropLast())
                expand = false
            } else if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
                expand = true
            } else {
                expand = true
            }
            if expand {
                value = Self.expandEnvironmentVariables(in: value)
            }
            env[key] = value
        }
        return env
    }

    /// Expand `$NAME` and `${NAME}` references against the current process
    /// environment, bash-style. A reference whose variable is unset expands to
    /// the empty string (matching `export FOO=$UNSET` → `FOO=`). Names follow the
    /// shell rule: start with a letter or `_`, continue with letters/digits/`_`.
    private static func expandEnvironmentVariables(in value: String) -> String {
        let env = ProcessInfo.processInfo.environment
        var output = ""
        var i = value.startIndex
        while i < value.endIndex {
            let ch = value[i]
            guard ch == "$" else {
                output.append(ch)
                i = value.index(after: i)
                continue
            }
            let afterDollar = value.index(after: i)
            if afterDollar < value.endIndex, value[afterDollar] == "{" {
                // ${NAME}
                let nameStart = value.index(after: afterDollar)
                var nameEnd = nameStart
                while nameEnd < value.endIndex, isShellNameChar(value[nameEnd], isStart: false) {
                    nameEnd = value.index(after: nameEnd)
                }
                if nameEnd < value.endIndex, value[nameEnd] == "}", nameStart < nameEnd {
                    let name = String(value[nameStart..<nameEnd])
                    output.append(env[name] ?? "")
                    i = value.index(after: nameEnd)   // consume the '}'
                } else {
                    // Malformed `${…` — emit the '$' literally and continue.
                    output.append("$")
                    i = afterDollar
                }
            } else {
                // $NAME (greedy run of name chars)
                var nameEnd = afterDollar
                while nameEnd < value.endIndex, isShellNameChar(value[nameEnd], isStart: nameEnd == afterDollar) {
                    nameEnd = value.index(after: nameEnd)
                }
                if nameEnd > afterDollar {
                    let name = String(value[afterDollar..<nameEnd])
                    output.append(env[name] ?? "")
                    i = nameEnd
                } else {
                    // Lone '$' not followed by a name char (e.g. `$$`, `$1`) — literal.
                    output.append("$")
                    i = afterDollar
                }
            }
        }
        return output
    }

    /// Shell variable-name character test: first char is ASCII letter or `_`;
    /// subsequent chars may also be ASCII digits.
    private static func isShellNameChar(_ c: Character, isStart: Bool) -> Bool {
        guard c.isASCII else { return false }
        if c == "_" { return true }
        if c.isLetter { return true }
        return !isStart && c.isNumber
    }

    // MARK: - Tokenizer (public for testing)

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
