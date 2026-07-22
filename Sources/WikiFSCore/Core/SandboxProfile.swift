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
    public struct SandboxInvocation: Equatable, Sendable {
        /// The seatbelt profile text. One argument element (passed via
        /// `sandbox-exec -p <profile>`).
        public let profile: String
        /// `sandbox-exec -D` profile-parameter pairs, in emit order. The profile
        /// references these by `(param "<key>")`. These are profile variables — they
        /// are NOT injected into the child process environment (so `-D WIKI_DB=<path>`
        /// does not collide with the `WIKI_DB=<ulid>` env var `wikictl` uses).
        public let defines: [(String, String)]

        public init(profile: String, defines: [(String, String)]) {
            self.profile = profile
            self.defines = defines
        }

        // MARK: - Equatable (tuples aren't Equatable by default)
        public static func == (lhs: SandboxInvocation, rhs: SandboxInvocation) -> Bool {
            guard lhs.profile == rhs.profile, lhs.defines.count == rhs.defines.count else {
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
    /// NOTE: `generateReadOnly` and `readOnlyInvocation` are retained in-tree
    /// deliberately but are CURRENTLY UNWIRED. The read-only Ask chat mode was
    /// removed — chats are always write-capable and use the write sandbox
    /// (`generate`/`invocation`). Kept for reference; not marked deprecated.
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
    private static func canonical(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(path, &buf) else { return path }
        return String(cString: resolved)
    }
}
