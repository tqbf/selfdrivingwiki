#if os(macOS)
import Darwin
#endif
import Foundation

/// Pure generator for the macOS seatbelt (`sandbox-exec`) profile that confines the
/// spawned agent's filesystem writes to a strict allowlist.
///
/// The profile is **allow-by-default for reads, network, and process execution**, but
/// **default-deny for writes** — `(allow default)` keeps the provider running normally
/// (it can read, exec, and use the network to reach its LLM API), then `(deny
/// file-write*)` is overridden by explicit `(allow file-write* …)` rules for ONLY:
///
/// - the per-run scratch dir (a directory tree → `subpath`),
/// - the active wiki's `<ulid>.sqlite` + its SQLite `-wal` / `-shm` / `-journal`
///   sidecars (exact files → `literal`).
///
/// This is provider-agnostic: the profile never names a provider; it fences the write
/// channel only. See `plans/sandbox-agent.md` for the threat model and the
/// `sandbox-exec` syntax research that underpins this.
///
/// Temp-file contract: the launcher relocates the agent's standard temp files
/// under the scratch (`TMPDIR=<scratch>/.tmp`, plus a defensive zsh
/// `TMPPREFIX=<scratch>/.tmp/zsh` compatibility leaf). Because both live under
/// the `SCRATCH_DIR` subpath allow, heredoc/process-substitution temp files are
/// writable inside the sandbox without any `/tmp` allowance — this profile must
/// NOT permit `/tmp/zsh*` globally.
///
/// The ONE read/exec carve-out: the resolved `pdf2md` script is denied for both
/// `process-exec*` and `file-read*` (`pdf2mdDenyRules()`), so a sandboxed agent can't
/// run the bundled extractor or feed it to `uv --script`. Everything else stays
/// allow-default. Generic `uv`/`python3` exec is NOT yet denied (issue #116 item 2).
///
/// `~/.claude` write narrowing (issue #116 item 4): the `~/.claude` subtree is broadly
/// allowed (the transcript under `projects/` needs it), but `claudeHomeDenyRules()`
/// layers narrower denies over the execution-vector / credential paths (`hooks/`,
/// `commands/`, `agents/`, `skills/`, `plugins/`, `.credentials.json`, `settings.json`,
/// `settings.local.json`, `CLAUDE.md`) so a sandboxed agent can't plant files a future
/// unsandboxed session would execute.
public enum SandboxProfile {

    /// The fully-resolved invocation the launcher hands to `OperationCommand` when the
    /// sandbox is on: the profile text (one string, passed via `sandbox-exec -p`) plus
    /// the `-D key=value` profile-parameter pairs it references. Equatable so the
    /// pure argv-assembly in `OperationCommand` is unit-testable.
    ///
    /// The profile is split into a `baseProfile` and a `trailer` because the
    /// seatbelt is purely LAST-MATCH-WINS (verified empirically on macOS 15: a
    /// later rule wins over an earlier one regardless of specificity — an allow
    /// placed after a broad deny re-opens it, and vice versa).
    /// `invocation(_:addingHomeSubpaths:)` appends per-spawn write allows to the
    /// BASE, and the trailer is carried through unchanged and always emitted
    /// last — so strict-mode denies (which must stay last) cannot be defeated
    /// by later layering.
    public struct SandboxInvocation: Equatable, Sendable {
        /// The seatbelt rules emitted before any per-spawn layering. One
        /// argument element prefix (passed via `sandbox-exec -p <profile>`).
        public let baseProfile: String
        /// Rules that MUST remain the last matching rules — strict-mode denies
        /// appended after every base rule and carried through layering.
        /// Empty for every non-strict invocation.
        public let trailer: [String]
        /// `sandbox-exec -D` profile-parameter pairs, in emit order. The profile
        /// references these by `(param "<key>")`. These are profile variables — they
        /// are NOT injected into the child process environment (so `-D WIKI_DB=<path>`
        /// does not collide with the `WIKI_DB=<ulid>` env var `wikictl` uses).
        public let defines: [(String, String)]

        /// The complete seatbelt profile text handed to `sandbox-exec -p`:
        /// `baseProfile` followed by the trailer (always last).
        public var profile: String {
            baseProfile + trailer.map { $0 + "\n" }.joined()
        }

        /// The back-compat memberwise shape: no trailer. Every non-strict
        /// invocation is built through this.
        public init(profile: String, defines: [(String, String)]) {
            self.init(baseProfile: profile, trailer: [], defines: defines)
        }

        /// The layered shape: allows folded into the base, strict denies kept
        /// in the trailer so they remain the last matching rules.
        public init(baseProfile: String, trailer: [String], defines: [(String, String)]) {
            self.baseProfile = baseProfile
            self.trailer = trailer
            self.defines = defines
        }

        // MARK: - Equatable (tuples aren't Equatable by default)
        public static func == (lhs: SandboxInvocation, rhs: SandboxInvocation) -> Bool {
            guard lhs.baseProfile == rhs.baseProfile,
                  lhs.trailer == rhs.trailer,
                  lhs.defines.count == rhs.defines.count else {
                return false
            }
            return zip(lhs.defines, rhs.defines).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    /// The SQLite journal-mode sidecar suffixes that may be created alongside the
    /// active wiki DB. `(WAL → -wal/-shm; DELETE/TRUNCATE/PERSIST → -journal.)`
    static let sqliteSidecarSuffixes = ["-wal", "-shm", "-journal"]

    /// Generate the seatbelt profile text. Pure `String → String` — no shell, no IO.
    ///
    /// - Parameters:
    ///   - scratchDir: the per-run scratch directory absolute path (the writable cwd).
    ///   - wikiDBPath: the active wiki's `<ulid>.sqlite` absolute file path.
    ///   - pdf2mdScriptPath: when non-nil, the resolved absolute path to the bundled
    ///     `pdf2md` PEP 723 script. Emits `process-exec*` + `file-read*` denies (by
    ///     `literal` on the script file) so a sandboxed agent can't run it or feed it
    ///     to `uv --script`. See `pdf2mdDenyRules()` for why this is `literal`, not
    ///     `subpath`. Nil (default) emits nothing — byte-identical to the pre-denial
    ///     profile, so call sites that don't care are unaffected.
    public static func generate(
        scratchDir: String,
        wikiDBPath: String,
        pdf2mdScriptPath: String? = nil
    ) -> String {
        var lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            // The scratch dir is a directory tree.
            "(allow file-write* (subpath (param \"SCRATCH_DIR\")))",
            // Claude Code writes its session transcript under ~/.claude/projects/ and its
            // top-level state to ~/.claude.json. The subtree allow is deliberately broad
            // so benign runtime paths (projects/, shell-snapshots/, sessions/, …) keep
            // working; the execution-vector / credential subpaths are carved out by
            // claudeHomeDenyRules() below (issue #116 item 4).
            "(allow file-write* (subpath (string-append (param \"HOME\") \"/.claude\")))",
            "(allow file-write* (literal (string-append (param \"HOME\") \"/.claude.json\")))",
            // Claude Code derives a per-session temp dir from the cwd and places it under
            // /private/tmp/claude-<uid>/<munged-cwd>/ — NOT under $TMPDIR. Its Bash tool
            // mkdir's this dir before running any command, so without this allow rule the
            // sandboxed agent's shell dies with EPERM on the first invocation.
            "(allow file-write* (subpath (param \"CLAUDE_TMP\")))",
            // The active wiki DB and its SQLite sidecars are exact files.
            "(allow file-write* (literal (param \"WIKI_DB\")))",
        ]
        // Layer the ~/.claude execution-vector / credential denies over the subtree allow.
        lines.append(contentsOf: claudeHomeDenyRules())
        lines.append(contentsOf: agentRuntimeWriteRules())
        for suffix in sqliteSidecarSuffixes {
            lines.append(
                "(allow file-write* (literal (string-append (param \"WIKI_DB\") \"\(suffix)\")))"
            )
        }
        // The deny rules reference only the `PDF2MD_SCRIPT` param NAME; the resolved
        // value flows in via `-D` at sandbox-exec time. Guard just to avoid emitting
        // rules with nothing to deny (and to keep the default-nil profile identical to
        // the pre-denial one).
        if let pdf2mdScriptPath, !pdf2mdScriptPath.isEmpty {
            lines.append(contentsOf: pdf2mdDenyRules())
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Generate a READ-ONLY seatbelt profile that allows writes to scratch (the agent
    /// needs a writable cwd for temp files) but DENIES writes to the wiki database.
    /// Used when the query agent runs without "Allow wiki edits" — it physically
    /// prevents `wikictl page add` / `wikictl index set` / `wikictl log append`
    /// from writing, regardless of prompt instructions.
    ///
    /// - Parameter pdf2mdScriptPath: when non-nil, emits the same `pdf2md` exec/read
    ///   denies as `generate(...)` so the deny holds for the read-only query path too.
    ///   See `generate(...)` / `pdf2mdDenyRules()` for details. Nil (default) emits
    ///   nothing.
    ///
    /// Wired since issue #1276: `LLMSandboxScratch` builds this invocation for
    /// every read-only LLM spawn that has no wiki database — ACP extraction,
    /// model summarization/title generation, and provider-model probes.
    /// (`AgentLauncher` no longer wires a read-only chat mode; chats are always
    /// write-capable and use `generate`/`invocation`.)
    public static func generateReadOnly(
        scratchDir: String,
        pdf2mdScriptPath: String? = nil
    ) -> String {
        var lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            // The scratch dir is writable — the agent needs a cwd.
            "(allow file-write* (subpath (param \"SCRATCH_DIR\")))",
            // Claude Code writes its session transcript under ~/.claude/projects/ and its
            // top-level state to ~/.claude.json. The subtree allow is deliberately broad
            // so benign runtime paths (projects/, shell-snapshots/, sessions/, …) keep
            // working; the execution-vector / credential subpaths are carved out by
            // claudeHomeDenyRules() below (issue #116 item 4).
            "(allow file-write* (subpath (string-append (param \"HOME\") \"/.claude\")))",
            "(allow file-write* (literal (string-append (param \"HOME\") \"/.claude.json\")))",
            // See `generate` — Claude Code's per-session temp dir lives under
            // /private/tmp/claude-<uid>/ (cwd-derived, not $TMPDIR). Required for the
            // Bash tool to function under the sandbox.
            "(allow file-write* (subpath (param \"CLAUDE_TMP\")))",
        ]
        // Layer the ~/.claude execution-vector / credential denies over the subtree allow.
        lines.append(contentsOf: claudeHomeDenyRules())
        lines.append(contentsOf: agentRuntimeWriteRules())
        // Mirror `generate`: deny exec/read of the resolved pdf2md script when a path
        // is supplied. The rules reference only the `PDF2MD_SCRIPT` param name.
        if let pdf2mdScriptPath, !pdf2mdScriptPath.isEmpty {
            lines.append(contentsOf: pdf2mdDenyRules())
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Build a read-only `SandboxInvocation` that confines the agent to scratch
    /// writes only. No wiki DB path is allowed — wikictl writes will fail.
    ///
    /// Both `homePath` and `scratchDir` are canonicalized via `realpath` so a
    /// symlinked HOME (e.g. on systems where the home directory path goes through
    /// a symlink) does not make the `~/.claude` allow rule silently fail. For
    /// non-existent paths `realpath` falls back to the input, which matches the
    /// behavior in `invocation(...)`.
    public static func readOnlyInvocation(
        homePath: String,
        scratchDir: String,
        claudeTempBase: String = defaultClaudeTempBase(),
        pdf2mdScriptPath: String? = nil
    ) -> SandboxInvocation {
        let resolvedHome = Self.canonical(homePath)
        let resolvedScratch = Self.canonical(scratchDir)
        let resolvedClaudeTemp = Self.canonical(claudeTempBase)
        let resolvedPdf2md = pdf2mdScriptPath.map { Self.canonical($0) }
        let profile = generateReadOnly(
            scratchDir: resolvedScratch,
            pdf2mdScriptPath: resolvedPdf2md
        )
        var defines: [(String, String)] = [
            ("HOME", resolvedHome),
            ("SCRATCH_DIR", resolvedScratch),
            ("CLAUDE_TMP", resolvedClaudeTemp),
        ]
        if let resolvedPdf2md, !resolvedPdf2md.isEmpty {
            defines.append(("PDF2MD_SCRIPT", resolvedPdf2md))
        }
        return SandboxInvocation(profile: profile, defines: defines)
    }

    /// Build the STRICT read-only `SandboxInvocation` for the summarizer child
    /// (issue #1276 follow-up): the read-only profile above, plus a trailer of
    /// last-matching denies that closes the execution and credential-read
    /// channels for a one-shot LLM call with no file-tool needs:
    ///
    /// - **W^X on writable land** — nothing the child (or any descendant)
    ///   writes into the scratch or temp can be executed or mapped
    ///   executable. Deliberately NOT extended to `~/.bun`/`~/.npm`/`~/.claude`:
    ///   those are write-allowed AND exec-bearing by design (`bun x` runs
    ///   packages from its cache), so denying exec there bricks the shipped
    ///   adapters.
    /// - **macOS pivot/escape exec denies** — `open` and `launchctl` are
    ///   launchd-spawned OUTSIDE the seatbelt (a complete fence escape);
    ///   AppleScript/Shortcuts can drive other apps; `security` dumps the
    ///   keychain; `crontab`/`at` persist. No summarizer needs any of them.
    /// - **Named credential/data read denies** — network is open, so a read
    ///   IS exfiltration. Deliberately does NOT deny the adapter auth files
    ///   (`~/.claude/.credentials.json`, `~/.codex/auth.json`) — the child
    ///   must authenticate. Never denies `$HOME` broadly: every common
    ///   adapter binary and runtime lives under HOME.
    ///
    /// Interpreter denies (`uv`, `bun`, `python3`, `node`) are deliberately
    /// ABSENT — an arbitrary ACP adapter may BE one of them, and denying
    /// `python3` while the adapter's own runtime runs free buys nothing.
    /// The trailer is emitted LAST (after `invocation(_:addingHomeSubpaths:)`
    /// layering) because the seatbelt is last-match-wins.
    public static func strictReadOnlyInvocation(
        homePath: String,
        scratchDir: String,
        claudeTempBase: String = defaultClaudeTempBase(),
        pdf2mdScriptPath: String? = nil
    ) -> SandboxInvocation {
        let base = readOnlyInvocation(
            homePath: homePath,
            scratchDir: scratchDir,
            claudeTempBase: claudeTempBase,
            pdf2mdScriptPath: pdf2mdScriptPath)
        return SandboxInvocation(
            baseProfile: base.baseProfile,
            trailer: strictDenyTrailer(),
            defines: base.defines)
    }

    /// The strict trailer: last-matching deny rules, in three independently
    /// testable groups.
    private static func strictDenyTrailer() -> [String] {
        writableLandExecDenies()
            + macOSPivotExecDenies()
            + sensitiveReadDenies()
    }

    /// W^X: nothing the child can write may be executed or mapped executable.
    /// Covers the scratch (cwd + relocated `TMPDIR`), Claude's per-session
    /// temp base, and the canonical temp roots. Paths are canonical
    /// (`/private/tmp`, never `/tmp`) — the kernel matcher resolves against
    /// the realpath.
    private static func writableLandExecDenies() -> [String] {
        [
            "(deny process-exec* (subpath (param \"SCRATCH_DIR\")))",
            "(deny file-map-executable (subpath (param \"SCRATCH_DIR\")))",
            "(deny process-exec* (subpath (param \"CLAUDE_TMP\")))",
            "(deny file-map-executable (subpath (param \"CLAUDE_TMP\")))",
            "(deny process-exec* (subpath \"/private/tmp\"))",
            "(deny file-map-executable (subpath \"/private/tmp\"))",
            "(deny process-exec* (subpath \"/private/var/tmp\"))",
            "(deny file-map-executable (subpath \"/private/var/tmp\"))",
        ]
    }

    /// macOS privilege pivots and sandbox escapes: `open`/`launchctl` are
    /// launchd-spawned outside the fence entirely; AppleScript/Shortcuts can
    /// drive other apps and launder TCC consent; `security` dumps the
    /// keychain; `crontab`/`at` persist; `sudo` fails more cleanly denied.
    /// All literal paths verified present on macOS 15.
    private static func macOSPivotExecDenies() -> [String] {
        [
            "(deny process-exec* (literal \"/usr/bin/open\"))",
            "(deny process-exec* (literal \"/bin/launchctl\"))",
            "(deny process-exec* (literal \"/usr/bin/osascript\"))",
            "(deny process-exec* (literal \"/usr/bin/osacompile\"))",
            "(deny process-exec* (literal \"/usr/bin/automator\"))",
            "(deny process-exec* (literal \"/usr/bin/shortcuts\"))",
            "(deny process-exec* (literal \"/usr/bin/security\"))",
            "(deny process-exec* (literal \"/usr/bin/crontab\"))",
            "(deny process-exec* (literal \"/usr/bin/at\"))",
            "(deny process-exec* (literal \"/usr/bin/sudo\"))",
        ]
    }

    /// Named credential/data stores, read-denied — with open network, a read
    /// is exfiltration. Paths are built in-profile from `(param "HOME")` (no
    /// trailing-slash roots: `string-append` does not normalize), so no new
    /// `-D` defines are needed and non-existent leaves simply never match.
    /// Deliberately excludes `~/.npmrc`/`~/.bunfig.toml` (registry auth reads
    /// on every install — a paranoid-tier candidate) and the adapter auth
    /// files the child must read to authenticate.
    private static func sensitiveReadDenies() -> [String] {
        var rules: [String] = [
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/.ssh\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/.aws\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/.gnupg\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/.config/gcloud\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/.config/gh\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/.kube\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/.docker\")))",
            "(deny file-read* (literal (string-append (param \"HOME\") \"/.netrc\")))",
            "(deny file-read* (literal (string-append (param \"HOME\") \"/.git-credentials\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Keychains\")))",
            "(deny file-read* (subpath \"/Library/Keychains\"))",
        ]
        // High-value personal data — cheap defense-in-depth behind TCC.
        rules.append(contentsOf: [
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Messages\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Mail\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Cookies\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Safari\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Application Support/Firefox\")))",
            "(deny file-read* (subpath (string-append (param \"HOME\") \"/Library/Application Support/Google/Chrome\")))",
        ])
        return rules
    }

    /// Build a `SandboxInvocation` from the three spawn-time paths. The scratch dir and
    /// DB path are **symlink-resolved** here, because the seatbelt `subpath`/`literal`
    /// matchers match the CANONICAL path — a symlinked component (e.g. `/tmp` →
    /// `/private/tmp`) makes an allow rule silently fail and writes get denied. Keeping
    /// this resolution in the (tested) core layer guards against a launcher regression
    /// dropping it.
    public static func invocation(
        homePath: String,
        scratchDir: String,
        wikiDBPath: String,
        claudeTempBase: String = defaultClaudeTempBase(),
        pdf2mdScriptPath: String? = nil
    ) -> SandboxInvocation {
        func realPath(_ s: String) -> String {
            Self.canonical(s)
        }
        // Canonicalize ALL paths — including HOME — so a symlinked component (e.g.
        // a HOME that goes through a symlink, or the classic `/tmp` → `/private/tmp`
        // on macOS) does not make a seatbelt allow rule silently fail. Non-existent
        // paths fall back to the input (realpath returns nil for non-existent paths).
        let resolvedHome = realPath(homePath)
        let resolvedScratch = realPath(scratchDir)
        let resolvedDB = realPath(wikiDBPath)
        let resolvedClaudeTemp = realPath(claudeTempBase)
        // The script file exists when the launcher hands it to us (it probed
        // `isExecutableFile`), so `realpath` fully resolves it — important because
        // the seatbelt `literal` matcher resolves the exec'd/read path the same way.
        // A dev script under `/tmp/…` surfaces as `/private/tmp/…`, matching how the
        // kernel resolves the agent's exec attempt.
        let resolvedPdf2md = pdf2mdScriptPath.map { realPath($0) }
        let profile = generate(
            scratchDir: resolvedScratch,
            wikiDBPath: resolvedDB,
            pdf2mdScriptPath: resolvedPdf2md
        )
        // NOTE: these are profile parameters, NOT child env vars. `-D WIKI_DB=<path>`
        // is consumed by `(param "WIKI_DB")`; it does not touch the `WIKI_DB=<ulid>`
        // env var the agent/wikictl use. `PDF2MD_SCRIPT` is appended ONLY when a path
        // was supplied, so the default-nil invocation stays byte-identical to the
        // pre-denial build (call sites and argv-index tests unaffected).
        var defines: [(String, String)] = [
            ("HOME", resolvedHome),
            ("SCRATCH_DIR", resolvedScratch),
            ("WIKI_DB", resolvedDB),
            ("CLAUDE_TMP", resolvedClaudeTemp),
        ]
        if let resolvedPdf2md, !resolvedPdf2md.isEmpty {
            defines.append(("PDF2MD_SCRIPT", resolvedPdf2md))
        }
        return SandboxInvocation(profile: profile, defines: defines)
    }

    /// Filesystem-write allowances every spawned agent's SHELL and tools need at
    /// runtime, independent of the wiki write policy — so they belong in BOTH the
    /// read-write (`generate`) and read-only (`generateReadOnly`) profiles. Shared here
    /// so the two can't drift. Kept to least privilege — only paths a normal shell run
    /// actually touches, scoped as narrowly as the use allows:
    ///
    /// - **`/dev/null`** — zsh redirects to it during startup; without a write allow the
    ///   shell prints `operation not permitted: /dev/null` on every command. Only data
    ///   writes are needed (not chmod/unlink), so `file-write-data`, not `file-write*`.
    /// - **`/dev/fd`** — the targets of `/dev/stdout`/`/dev/stderr` after symlink
    ///   canonicalization; aliases the process's own fds, so it can't widen access.
    ///   Data writes only.
    /// - **Claude Code's per-shell cwd markers.** Its Bash tool creates a marker dir
    ///   directly under `/private/tmp` named `claude-<hex>-cwd` — a sibling of, NOT
    ///   under, the per-session `CLAUDE_TMP` base (`/private/tmp/claude-<uid>`, already
    ///   allowed separately). Scoped to exactly that marker shape rather than a broad
    ///   `/private/tmp/claude-*` prefix, so the agent can't write across other uids' or
    ///   sessions' temp dirs in shared `/private/tmp`. This needs full `file-write*`
    ///   (mkdir/unlink). `/dev/tty` and `/dev/dtracehelper` are deliberately NOT allowed
    ///   — they weren't observed as needed (the agent's output is piped, not a tty).
    private static func agentRuntimeWriteRules() -> [String] {
        [
            "(allow file-write-data (literal \"/dev/null\"))",
            "(allow file-write-data (subpath \"/dev/fd\"))",
            "(allow file-write* (regex #\"^/private/tmp/claude-[A-Za-z0-9]+-cwd(/|$)\"))",
        ]
    }

    /// `~/.claude` write-deny rules layered OVER the broad `~/.claude` subtree allow, so
    /// a sandboxed agent can't tamper files that a FUTURE, unsandboxed Claude Code session
    /// would load and execute (issue #116 item 4). The subtree allow is kept broad for
    /// robustness — Claude Code writes the session transcript under `~/.claude/projects/`
    /// and touches other benign runtime paths (`shell-snapshots/`, `sessions/`, `cache/`,
    /// …) that vary by version; carving them all out individually would be brittle. Instead
    /// the dangerous subpaths are denied here, and a narrower filtered deny wins over the
    /// broader allow (same specificity semantics the `(deny file-write*)` fence and
    /// `pdf2mdDenyRules()` rely on — verified live with `sandbox-exec`).
    ///
    /// Two categories, both under `~/.claude/`:
    /// - **Execution vectors** (subtree `deny`): `hooks/`, `commands/`, `agents/`,
    ///   `skills/`, `plugins/` — each can run code or define behavior a future session
    ///   loads. (`commands/` is denied defensively even when absent — it's a known vector.)
    /// - **Credentials + config + memory** (literal `deny`): `.credentials.json`,
    ///   `settings.json`, `settings.local.json`, `CLAUDE.md` — credential swap, settings
    ///   tamper (e.g. enabling `bypassPermissions`), or user-level instruction injection.
    ///
    /// Emitted in BOTH profiles; references only `(param "HOME")` (already a define), so
    /// no new `-D` parameter is threaded through the invocation builders.
    private static func claudeHomeDenyRules() -> [String] {
        let dirSubtrees = ["hooks", "commands", "agents", "skills", "plugins"]
        let literalFiles = [".credentials.json", "settings.json", "settings.local.json", "CLAUDE.md"]
        var rules: [String] = []
        for d in dirSubtrees {
            rules.append("(deny file-write* (subpath (string-append (param \"HOME\") \"/.claude/\(d)\")))")
        }
        for f in literalFiles {
            rules.append("(deny file-write* (literal (string-append (param \"HOME\") \"/.claude/\(f)\")))")
        }
        return rules
    }

    /// The `pdf2md` exec/read deny rules, emitted by BOTH `generate` and
    /// `generateReadOnly` when a resolved script path is supplied. Shared here so the
    /// two profiles can't drift — the deny must hold for every spawn path (Ingest /
    /// Edit / read-only Query) regardless of "Allow wiki edits".
    ///
    /// **Why `literal` on the script FILE, not `subpath` on its directory.** `wikictl`
    /// (the agent's ONLY sanctioned exec) and `pdf2md` ship in the SAME directory in
    /// every production/dev candidate — `Contents/Helpers/` in the bundle, `build/`,
    /// and the `swift run` exe-sibling (`HelpersLocation.wikictlDirectory` vs
    /// `PdfExtractionService.candidateLocations()`). A `subpath` deny on that dir would
    /// deny exec of `wikictl` too, breaking the agent. `literal` on the exact script
    /// path denies only `pdf2md` and never collides with `wikictl`.
    ///
    /// **Why `file-read*` as well as `process-exec*`.** `uv run --script pdf2md` must
    /// `open()` the script to parse its PEP 723 inline deps; denying the read closes
    /// that angle for the bundled-script case (issue #116 item 1's "ideally deny-read").
    /// The agent never legitimately reads `pdf2md` — only the unsandboxed APP process
    /// (`PdfExtractionService`) does — so this is safe. This does NOT stop generic
    /// `uv`/`python3` use (item 2, a follow-up).
    ///
    /// Precedence: these are filtered rules, so they win over the generic
    /// `(allow default)` at the top of the profile — same last-specific-match-wins
    /// semantics the `(deny file-write*)` + `(allow file-write* …)` pair relies on.
    private static func pdf2mdDenyRules() -> [String] {
        [
            "(deny process-exec* (literal (param \"PDF2MD_SCRIPT\")))",
            "(deny file-read* (literal (param \"PDF2MD_SCRIPT\")))",
        ]
    }

    // MARK: - Applying an invocation to a spawn

    /// The seatbelt front-end the deleted `OperationCommand.applySandbox` (and
    /// now `ACPBackend.startProcess`) wraps a spawn with.
    public static let sandboxExecutablePath = "/usr/bin/sandbox-exec"

    /// Assemble the `sandbox-exec` argv that wraps a real spawn:
    /// `-p <profile> -D k=v ... -- <executable> <args...>`. Byte-for-byte the
    /// pattern the deleted `OperationCommand.applySandbox` used for the agent
    /// and `ExtractorSandboxProfile.wrappedArguments` uses for extractors —
    /// that method now delegates here so the two wrap shapes cannot drift.
    public static func wrappedArguments(
        executablePath: String,
        arguments: [String],
        invocation: SandboxInvocation
    ) -> [String] {
        ["-p", invocation.profile]
            + invocation.defines.flatMap { ["-D", "\($0.0)=\($0.1)"] }
            + ["--", executablePath]
            + arguments
    }

    /// A copy of `base` with one extra writable `~`-relative subpath per
    /// entry: `(allow file-write* (subpath (string-append (param "HOME")
    /// "/<subpath>")))`. Used for provider config homes the base profiles
    /// don't already allow (Codex writes `~/.codex`, Gemini `~/.gemini`;
    /// `~/.claude` is already allowed by the base profile). The appended
    /// allows fold into the BASE (before the trailer); they cannot shadow the
    /// `PDF2MD_SCRIPT` exec/read denies (different operation classes), the
    /// claude-home credential denies (disjoint subtrees), or a strict trailer
    /// (carried through unchanged and always emitted after them — the
    /// seatbelt is last-match-wins, so strict denies must stay last).
    /// `HOME` is already a define on every invocation this module builds, so
    /// no new defines are added. An empty list returns `base` unchanged.
    public static func invocation(
        _ base: SandboxInvocation,
        addingHomeSubpaths subpaths: [String]
    ) -> SandboxInvocation {
        guard !subpaths.isEmpty else { return base }
        var baseProfile = base.baseProfile
        for subpath in subpaths {
            baseProfile += "(allow file-write* (subpath (string-append (param \"HOME\") \"/\(subpath)\")))\n"
        }
        return SandboxInvocation(
            baseProfile: baseProfile,
            trailer: base.trailer,
            defines: base.defines)
    }

    // MARK: - Helpers

    /// The base directory Claude Code uses for its per-session temp dirs:
    /// `/private/tmp/claude-<uid>`. Claude Code places a `<munged-cwd>/<session>` tree
    /// under here (cwd-derived, independent of `$TMPDIR`) and its Bash tool mkdir's it
    /// before running anything — so the whole subtree must be writable or the sandboxed
    /// shell fails with EPERM. The seatbelt matches the canonical path; `/private/tmp`
    /// is already canonical, but callers run this through `canonical(...)` regardless.
    public static func defaultClaudeTempBase() -> String {
        "/private/tmp/claude-\(getuid())"
    }

    /// `realpath(3)` — the kernel's own canonical-path resolution, which is exactly
    /// what the seatbelt `subpath`/`literal` matchers resolve against. Foundation's
    /// `URL.resolvingSymlinksInPath()` is unreliable for this (it does NOT resolve
    /// `/tmp` → `/private/tmp`); `realpath` does. Falls back to the input when the
    /// path doesn't exist yet (`realpath` returns nil for non-existent paths), since
    /// a non-existent path can't be symlink-resolved and the seatbelt will create it.
    ///
    /// Internal (not private) so the managed-extractor profile
    /// (`ExtractorSandboxProfile`) shares the exact same canonicalization —
    /// both profiles must resolve roots the way the seatbelt kernel matcher
    /// does, and they must not drift.
    static func canonical(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(path, &buf) else { return path }
        return String(cString: resolved)
    }
}
