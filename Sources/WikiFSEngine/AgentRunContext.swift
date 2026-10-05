import Foundation
import WikiFSCore

/// POSIX shell quoting for prompt-injected command lines. One helper so every
/// absolute path / argument the app renders into an agent prompt is quoted the
/// same tested way (`plans/sandbox-agent.md` §"Prompted absolute-command
/// integrity"). Single-quote form: wrap in `'…'` and escape embedded single
/// quotes as `'\''` — safe for every POSIX shell including `/bin/sh`.
public enum ShellQuoting {
    /// Quote `raw` for literal use in a POSIX shell command line.
    public static func quote(_ raw: String) -> String {
        guard !raw.isEmpty else { return "''" }
        guard raw.rangeOfCharacter(from: CharacterSet(charactersIn: "|&;<>()$`\\\"' \t\n*?[#~=%") ) != nil else {
            return raw
        }
        return "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Quote and join a full argv into one shell command line.
    public static func commandLine(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map { quote($0) }.joined(separator: " ")
    }
}

/// Shell-neutral discovery of the user's environment `PATH`.
///
/// The GUI app inherits the launchd-minimal PATH, which usually lacks
/// `/opt/homebrew/bin` and user runtime installs (Bun, uv, rbenv shims). The
/// fix is one login-shell hop — but the shell must be the ACCOUNT'S configured
/// login shell (`SHELL`, else the passwd record), never a hard-coded `/bin/zsh`:
/// a bash or fish user's startup files are the truth for their machine. The
/// hop is ISOLATED to environment discovery — agent scripts never depend on
/// login-shell startup semantics (`plans/sandbox-agent.md`).
///
/// The resolver degrades gracefully: an unknown shell, a failed hop, or an
/// output that is not a plausible PATH (empty, or containing whitespace —
/// e.g. fish renders `$PATH` space-separated) returns nil and the caller falls
/// back to the inherited process PATH. Injectable `runProcess` for tests.
public enum UserEnvironmentPath {
    /// The result of one lookup: the resolved PATH, or nil (caller falls back).
    public static func userPATH(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: uid_t = getuid(),
        runProcess: (AsyncProcessRequest) async throws -> AsyncProcessResult = AsyncProcessRunner.run
    ) async -> String? {
        guard let shell = configuredShell(environment: environment, uid: uid) else {
            return nil
        }
        return await loginShellPATH(shellPath: shell, runProcess: runProcess)
    }

    /// The account's configured login shell: `$SHELL` when set and absolute,
    /// else the passwd record's `pw_shell`. nil when neither names an absolute
    /// path (an absolute path is required to exec it directly).
    public static func configuredShell(
        environment: [String: String],
        uid: uid_t = getuid()
    ) -> String? {
        if let shell = environment["SHELL"], shell.hasPrefix("/") {
            return shell
        }
        #if os(macOS)
        guard let passwd = getpwuid(uid) else { return nil }
        guard let raw = passwd.pointee.pw_shell else { return nil }
        let shell = String(cString: raw)
        return shell.hasPrefix("/") ? shell : nil
        #else
        // Linux diagnostics-only builds: no passwd lookup — $SHELL or nothing.
        return nil
        #endif
    }

    /// Run `<shell> -l -c 'printf %s "$PATH"'` and return the trimmed stdout.
    /// Login mode (`-l`) sources the account's startup files — that is the
    /// PATH the user's interactive shell would have. nil on a non-zero exit,
    /// a throw, or an implausible output (empty / whitespace, which is not a
    /// colon-separated PATH — fish renders `$PATH` space-separated).
    public static func loginShellPATH(
        shellPath: String,
        runProcess: (AsyncProcessRequest) async throws -> AsyncProcessResult = AsyncProcessRunner.run
    ) async -> String? {
        let request = AsyncProcessRequest(
            executableURL: URL(fileURLWithPath: shellPath),
            arguments: ["-l", "-c", "printf %s \"$PATH\""])
        do {
            let result = try await runProcess(request)
            guard result.terminationStatus == 0 else { return nil }
            let path = String(data: result.stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty else { return nil }
            // A plausible PATH is colon-separated with no whitespace. A space
            // (fish list rendering, or a shell error banner) means the output
            // is not usable as PATH.
            guard !path.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }
}

/// The typed per-run capability context for one agent run.
///
/// One value identifies everything a run's scripts and prompts need to be
/// correct WITHOUT trusting the adapter's nested tool cwd or preserved
/// environment:
///
/// - the canonical timestamped scratch directory (the ACP session cwd),
/// - the scratch-local temp roots (`<scratch>/.tmp`, and the optional zsh
///   compatibility prefix `<scratch>/.tmp/zsh`) that `TMPDIR`/`TMPPREFIX`
///   point at,
/// - the active typed wiki id and the trusted absolute `wikictl` helper path,
/// - the effective `PATH` (helper directory first, then the user's resolved
///   environment PATH).
///
/// Environment values exported from this context (`WIKI_DB`, `WIKICTL`,
/// `WIKI_SCRATCH`, `PATH`, `TMPDIR`, `TMPPREFIX`) are CONVENIENCES for adapters
/// that preserve them — never capabilities. Correctness flows from the
/// absolute paths injected into every operation prompt
/// (`promptContextSection()`); the Seatbelt profile remains the security
/// boundary. No executable stored in agent-writable scratch is ever generated
/// or trusted.
///
/// `Sendable` + `Equatable`: built once per run/preparation on the main actor,
/// then captured by backend profiles and prompt builders.
public struct AgentRunContext: Sendable, Equatable {
    /// The canonical timestamped scratch directory (the ACP session cwd).
    public let scratchDirectory: URL
    /// `<scratch>/.tmp` — the relocated `TMPDIR` for the run's child processes.
    public let tempDirectory: URL
    /// `<scratch>/.tmp/zsh` — the defensive zsh `TMPPREFIX`. zsh keeps its own
    /// temp-prefix default (`/tmp/zsh…`) for heredocs and process substitution,
    /// independent of `TMPDIR`; relocation is set for compatibility with
    /// adapters/runtimes that happen to launch zsh (the observed rbenv-init
    /// heredoc failure) — it does NOT select zsh or require zsh syntax.
    public let zshTempPrefix: URL
    /// The active wiki's typed id (routes `--wiki` and `WIKI_DB`).
    public let wikiID: WikiID
    /// The trusted ABSOLUTE path of the bundled `wikictl` helper.
    public let wikictlPath: String
    /// The user-environment PATH this run resolved (already falls back to the
    /// inherited process PATH when the login-shell hop fails).
    public let userPATH: String
    /// The RAW login-shell PATH resolution for this run — nil when the
    /// login-shell hop failed (issue #1368). Unlike ``userPATH`` (which bakes
    /// in the inherited-process fallback so ``effectivePATH`` always has a
    /// value), this keeps the failed hop distinguishable: the ACP spawn seam
    /// (`ACPBackend.resolveSpawnConfig`) injects `PATH` into the child
    /// environment from THIS value only, so an absent resolution leaves the
    /// child's `PATH` unset rather than silently inheriting the daemon's
    /// minimal one.
    public let resolvedLoginShellPATH: String?
    /// Absolute scratch path of the staged `WIKI_STATE.md` snapshot, when the
    /// operation stages one.
    public let stateFilePath: String?
    /// Absolute scratch paths of the staged raw source(s), when any.
    public let stagedSourcePaths: [String]
    /// The EXPLICIT absolute wiki database file this run targets, when the run
    /// does not use the standard App Group container layout. nil on every
    /// production launch today: `--wiki`/`WIKI_DB` then carry ``wikiID`` and
    /// `wikictl` resolves `<container>/<wikiID>.sqlite` through the registry.
    ///
    /// When set, every trusted selector rendered from this context (env, prompt
    /// invocations, RUN ENVIRONMENT block) carries the TYPED explicit form —
    /// the `--database-path <file>` flag — never an overloaded `--wiki`
    /// string, so an explicit database can never silently masquerade as a wiki
    /// id. `wikictl` accepts the same flag (`WikiResolver.resolve(selection:)`)
    /// and refuses explicit paths inside the real App Group container. The live
    /// semantic evaluation harness (disposable fixture database under project
    /// `tmp/`) is the first caller; see
    /// `plans/wiki-strategy-evaluation-harness.md`.
    public let databasePath: URL?

    /// The scratch-relative leaf the temp roots live under.
    public static let tempRelocationLeaf = ".tmp"
    /// The temp-relative leaf of the zsh compatibility prefix.
    public static let zshTempPrefixLeaf = "zsh"

    public init(
        scratchDirectory: URL,
        wikiID: WikiID,
        wikictlDirectory: String,
        userPATH: String,
        resolvedLoginShellPATH: String? = nil,
        stateFilePath: String? = nil,
        stagedSourcePaths: [String] = [],
        databasePath: URL? = nil
    ) {
        self.scratchDirectory = scratchDirectory
        self.tempDirectory = scratchDirectory
            .appendingPathComponent(Self.tempRelocationLeaf, isDirectory: true)
        self.zshTempPrefix = scratchDirectory
            .appendingPathComponent(Self.tempRelocationLeaf, isDirectory: true)
            .appendingPathComponent(Self.zshTempPrefixLeaf, isDirectory: true)
        self.wikiID = wikiID
        self.wikictlPath = URL(fileURLWithPath: wikictlDirectory, isDirectory: true)
            .appendingPathComponent("wikictl", isDirectory: false).path
        self.userPATH = userPATH
        self.resolvedLoginShellPATH = resolvedLoginShellPATH
        self.stateFilePath = stateFilePath
        self.stagedSourcePaths = stagedSourcePaths
        self.databasePath = databasePath
    }

    /// The directory holding the trusted helper (the PATH head).
    public var wikictlDirectory: String {
        (wikictlPath as NSString).deletingLastPathComponent
    }

    /// The `--wiki`-family selector arguments trusted invocations carry: the
    /// TYPED explicit form (`--database-path <file>`) when ``databasePath`` is
    /// set, else `--wiki <wiki-id>`. One argument list feeds the exported
    /// environment, the trusted prompt invocations, and the agent-facing RUN
    /// ENVIRONMENT block — the two forms never mix.
    public var wikiSelectorArguments: [String] {
        if let databasePath {
            return [Self.databasePathFlag, databasePath.path]
        }
        return ["--wiki", wikiID.rawValue]
    }

    /// The flag spelling `wikictl` accepts for the typed explicit-database
    /// selector. Declared here so the prompt renderer and the CLI agree on
    /// exactly one spelling.
    public static let databasePathFlag = "--database-path"

    // MARK: - PATH assembly

    /// Build the effective run PATH: the helper directory FIRST, then the
    /// user's resolved environment path, deduplicated without changing
    /// first-hit order. Pure and injectable for tests.
    public static func assemblePATH(helperDirectory: String, userPath: String) -> String {
        let entries = [helperDirectory] + userPath.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in entries where !entry.isEmpty {
            if seen.insert(entry).inserted {
                ordered.append(entry)
            }
        }
        return ordered.joined(separator: ":")
    }

    public var effectivePATH: String {
        Self.assemblePATH(helperDirectory: wikictlDirectory, userPath: userPATH)
    }

    // MARK: - Environment

    /// The protected run keys this context overwrites AFTER provider
    /// environment is merged, so provider hints cannot redirect wiki routing,
    /// the scratch, or temp relocation. Order in the returned array is the
    /// overwrite order (irrelevant — the keys are disjoint).
    public var protectedEnvironment: [String: String] {
        var keys: [String: String] = [
            EnvironmentKey.wikictl: wikictlPath,
            EnvironmentKey.wikiScratch: scratchDirectory.path,
            EnvironmentKey.path: effectivePATH,
            EnvironmentKey.tmpDir: tempDirectory.path,
            EnvironmentKey.tmpPrefix: zshTempPrefix.path,
        ]
        // The two selector forms are mutually exclusive by construction: an
        // explicit database run exports WIKI_DB_PATH only, a registry run
        // exports WIKI_DB only. `wikictl` rejects a request that carries both.
        if let databasePath {
            keys[EnvironmentKey.wikiDatabasePath] = databasePath.path
        } else {
            keys[EnvironmentKey.wikiDB] = wikiID.rawValue
        }
        return keys
    }

    /// Named constants for the env keys this type owns. Same pattern as
    /// `HintKey` — the raw literals live in exactly one place.
    public enum EnvironmentKey {
        public static let wikiDB = "WIKI_DB"
        public static let wikiDatabasePath = "WIKI_DB_PATH"
        public static let wikictl = "WIKICTL"
        public static let wikiScratch = "WIKI_SCRATCH"
        public static let path = "PATH"
        public static let tmpDir = "TMPDIR"
        public static let tmpPrefix = "TMPPREFIX"
    }

    /// The full child environment for one spawn: the base (inherited process)
    /// environment, merged with the provider's hints LAST (provider wins
    /// inside its own namespace), then the protected run keys overwrite
    /// everything — so `env.WIKI_DB`, `env.WIKI_SCRATCH`, … in provider
    /// config cannot redirect the run. Pure; injectable `baseEnvironment`
    /// for tests.
    ///
    /// `PATH` is the one protected key with a carve-out (issue #1368): an
    /// EXPLICIT `PATH` in the provider's spawn environment — a
    /// user-configured `env.PATH` in agent-providers.json, or the
    /// login-shell `PATH` the spawn seam injected from
    /// ``resolvedLoginShellPATH`` — keeps every entry it named; it becomes
    /// the tail under the trusted helper head (`assemblePATH`) instead of
    /// being discarded. Explicit configuration beats host injection, and the
    /// injected login-shell `PATH` replaces the daemon's inherited one.
    public func environment(
        providerEnvironment: [String: String],
        baseEnvironment: [String: String]
    ) -> [String: String] {
        var env = baseEnvironment
        for (key, value) in providerEnvironment {
            env[key] = value
        }
        for (key, value) in protectedEnvironment {
            env[key] = value
        }
        // #1368: an explicit `PATH` from the provider's spawn environment
        // (user `env.PATH`, or the seam-injected login-shell `PATH`) keeps
        // every entry it named — it becomes the tail under the trusted
        // helper head instead of being discarded by the protected-key
        // overwrite above.
        if let explicitPATH = providerEnvironment[EnvironmentKey.path] {
            env[EnvironmentKey.path] = Self.assemblePATH(
                helperDirectory: wikictlDirectory,
                userPath: explicitPATH)
        }
        return env
    }

    // MARK: - Trusted wiki command

    /// The structured trusted wiki command head: absolute helper + the typed
    /// selector arguments. Callers append their subcommand arguments; render a
    /// shell-safe string only at the prompt boundary (`renderedWikiCommand`).
    public func wikiCommand(_ arguments: [String]) -> [String] {
        [wikictlPath] + wikiSelectorArguments + arguments
    }

    /// The trusted wiki invocation rendered as ONE shell-safe command line for
    /// prompt injection (paths with spaces survive — `ShellQuoting`).
    public func renderedWikiCommand(_ arguments: [String]) -> String {
        ShellQuoting.commandLine(
            executable: wikictlPath,
            arguments: wikiSelectorArguments + arguments)
    }

    /// The bare trusted invocation prefix (helper + selector arguments),
    /// rendered shell-safe — the form prompts splice subcommands onto.
    public var renderedWikiInvocation: String {
        ShellQuoting.commandLine(executable: wikictlPath, arguments: wikiSelectorArguments)
    }

    /// The selector, rendered as the agent types it at the start of a
    /// `wikictl` command line (e.g. `` `--wiki <id>` `` or
    /// `` `--database-path '/abs/file.sqlite'` ``).
    public var renderedWikiSelector: String {
        wikiSelectorArguments.map { ShellQuoting.quote($0) }.joined(separator: " ")
    }

    // MARK: - Prompt injection

    /// The run-capability block injected into EVERY operation prompt (one-shot,
    /// ingest phase, interactive chat turn). Absolute, self-sufficient: the
    /// agent's correctness must not depend on nested-tool cwd, `PATH`,
    /// `WIKI_DB`, or `WIKICTL` propagation — adapters have been observed
    /// moving the tool cwd and dropping env vars.
    public func promptContextSection() -> String {
        var lines: [String] = [
            "RUN ENVIRONMENT (authoritative for this run):",
            "- Scratch workspace (the ONLY directory you should write files in): \(scratchDirectory.path)",
            "- Temp files: use paths under \(tempDirectory.path) (TMPDIR already points here; a zsh-compatible TMPPREFIX also lives under the scratch temp directory).",
        ]
        if let stateFilePath {
            lines.append("- Wiki state snapshot (read this first): \(stateFilePath)")
        }
        if !stagedSourcePaths.isEmpty {
            lines.append("- Staged source file(s): \(stagedSourcePaths.joined(separator: ", "))")
        }
        lines.append("""
        - Wiki tool (PREFERRED FORM — bare `wikictl` is FIRST on your PATH): \
        `wikictl \(renderedWikiSelector) <subcommand> …`. The selector goes \
        BEFORE the subcommand; use it exactly as rendered (it is either \
        `--wiki <id>` or `--database-path <file>` for this run). The alternate \
        `--wiki=<id>` spelling is also accepted when the selector is an id.
        """)
        lines.append("""
        - Wiki tool (GUARANTEED FALLBACK — TRUSTED ABSOLUTE INVOCATION; use it \
        verbatim, splicing your subcommand and flags after it, when bare \
        `wikictl` is not found): \(renderedWikiInvocation) … The absolute path \
        contains a SPACE — keep the single quotes exactly as rendered.
        """)
        lines.append("""
          Bare `wikictl`, `$WIKICTL`, `$WIKI_DB`/`$WIKI_DB_PATH`, and your PATH are \
          conveniences that an adapter may drop — the absolute form above always works. Never generate \
          or execute a script stored inside the scratch workspace as if the app vouched for it.
        """)
        return lines.joined(separator: "\n")
    }

    /// Non-secret diagnostics: requested session cwd + capability paths. Never
    /// the whole environment, never credentials.
    public var diagnosticDescription: String {
        var text = "runContext cwd=\(scratchDirectory.path) tmp=\(tempDirectory.path) wiki=\(wikiID.rawValue) wikictl=\(wikictlPath)"
        if let databasePath {
            text += " db=\(databasePath.path)"
        }
        return text
    }

    /// A copy of this context re-rooted at a derived scratch directory (the
    /// fallback-provider sub-scratch). Everything else — wiki id, trusted
    /// helper, resolved user PATH (raw and fallback-applied) — is inherited
    /// so the derived run keeps the same capability contract. Fallback run
    /// directories get INDEPENDENT temp roots under their own scratch.
    public func withScratch(_ newScratch: URL) -> AgentRunContext {
        AgentRunContext(
            scratchDirectory: newScratch,
            wikiID: wikiID,
            wikictlDirectory: wikictlDirectory,
            userPATH: userPATH,
            resolvedLoginShellPATH: resolvedLoginShellPATH,
            stateFilePath: stateFilePath,
            stagedSourcePaths: stagedSourcePaths,
            databasePath: databasePath)
    }

    /// Create the scratch temp directories the relocated `TMPDIR` (and the
    /// defensive zsh `TMPPREFIX`) point at. MUST run before the child spawns —
    /// under the sandbox a missing temp root is a denied write at first use.
    /// Best-effort: failures surface later as the child's own write errors.
    public func createTempDirectories() {
        let fm = FileManager.default
        DebugLog.trying("createRunTempDirectories", operation: {
            try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        })
        DebugLog.trying("createRunZshTempPrefix", operation: {
            try fm.createDirectory(at: zshTempPrefix, withIntermediateDirectories: true)
        })
    }
}
