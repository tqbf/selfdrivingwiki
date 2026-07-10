import Foundation

/// The fully-assembled `claude -p` invocation for one `WikiOperation` run, scoped
/// to one wiki (`plans/llm-wiki.md` Phase C — "`claude -p` orchestration").
///
/// PURE and injectable: built by `OperationCommand.build(...)` from the operation,
/// the wiki's live mount path, its DB id, its `system_prompt` body, a per-run
/// scratch dir, and the directory holding `wikictl`. No process is spawned here —
/// the app's `AgentLauncher` runs `executableURL` with `arguments`, `environment`,
/// and `currentDirectory`. This split is what lets the Phase-C gate unit-test the
/// EXACT flag surface (`--append-system-prompt`, `--dangerously-skip-permissions`,
/// the env, the scratch cwd, and `wikictl`-on-PATH) without a real agent run.
public struct OperationCommand: Equatable, Sendable {
    /// The `claude` executable to run. Resolved from the login-shell PATH at spawn
    /// time (the app's PATH preflight guarantees it exists); we keep it as a bare
    /// name so the child's own PATH lookup applies.
    public let executable: String
    /// The full argument vector after `executable`.
    public let arguments: [String]
    /// The child process environment (a copy of the parent's, plus our additions).
    public let environment: [String: String]
    /// The working directory: a per-run WRITABLE scratch dir (Claude Code needs a
    /// writable cwd for session/todo scratch — decision #4). NEVER the read-only
    /// mount.
    public let currentDirectoryPath: String

    // MARK: - Debug summary

    /// A single-line, redacted summary of this invocation for `DebugLog`. Surfaces
    /// the executable, the full FLAG surface (long payloads like the system prompt
    /// and the query prompt are truncated to a length marker so the log stays
    /// legible and free of wiki content), and only the auth/resolution-relevant
    /// environment keys — never the whole environment, which may carry API keys.
    ///
    /// `authSet` lists which API-key env vars are present (NAMES ONLY, never values) —
    /// an empty list means Claude Code will fall back to ~/.claude credential lookup.
    public var debugSummary: String {
        let redactedArgs = arguments.map { Self.redactArgument($0) }.joined(separator: " ")
        let reportedEnvKeys = ["HOME", "TMPDIR", "PATH", "WIKI_ROOT", "WIKI_DB"]
        let env = reportedEnvKeys
            .compactMap { key in environment[key].map { "\(key)=\($0)" } }
            .joined(separator: " ")
        // Presence-only (no values): an API key or OAuth token in the child env
        // bypasses interactive /login, so knowing which are set explains the auth
        // path without ever logging a secret.
        let authKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]
        let authSet = authKeys.filter { (environment[$0]?.isEmpty == false) }
        let sandboxed = (executable == Self.sandboxExecutable)
        return "exe=\(executable) sandboxed=\(sandboxed) "
            + "args=[\(redactedArgs)] env={\(env)} "
            + "authSet=[\(authSet.joined(separator: ","))] cwd=\(currentDirectoryPath)"
    }

    /// Truncate one argument to a head + length marker when it's long. The system
    /// prompt and query prompt run to thousands of characters (and may carry wiki
    /// content), so dumping them whole would bury the flags and leak page text;
    /// short flags and values pass through unchanged.
    static func redactArgument(_ arg: String, limit: Int = 80) -> String {
        guard arg.count > limit else { return arg }
        return "\(arg.prefix(limit))…(\(arg.count) chars)"
    }

    /// Build the invocation for `operation` against one wiki.
    ///
    /// - Parameters:
    ///   - operation: which op + its inputs (carries its own self-sufficient prompt).
    ///   - wikiRoot: the wiki's LIVE File Provider mount path, resolved at click
    ///     time (never hardcoded). Exported as `WIKI_ROOT`.
    ///   - wikiID: the active wiki's ULID. Exported as `WIKI_DB` so `wikictl`
    ///     writes the right DB without a `--wiki` flag.
    ///   - systemPrompt: that wiki's `system_prompt` singleton body, passed via
    ///     `--append-system-prompt`. No `CLAUDE.md` is written onto the mount.
    ///   - scratchDirectory: a per-run writable dir (under the app caches). The cwd.
    ///   - wikictlDirectory: the directory containing the `wikictl` binary
    ///     (`Self Driving Wiki.app/Contents/Helpers`). PREPENDED to the child's PATH so the
    ///     agent's `Bash(wikictl:*)` calls resolve.
    ///   - resolvedExecutable: the PATH-resolved full path to the executable
    ///     (e.g. `/opt/homebrew/bin/claude`). Preflight happens in AgentLauncher.
    ///   - command: the agent command config (prefix args, model override, extra
    ///     env). Default reproduces today's `claude -p …` exactly.
    ///   - sandbox: when non-nil, wrap the invocation in `/usr/bin/sandbox-exec`
    ///     with the seatbelt profile that confines writes to the scratch dir + active
    ///     wiki DB (`plans/sandbox-agent.md`). Default `nil` reproduces today's run
    ///     byte-for-byte. `TMPDIR` is relocated into scratch when non-nil; it never
    ///     clobbers `WIKI_ROOT`/`WIKI_DB`/`PATH`.
    ///   - baseEnvironment: the parent environment to inherit (default the current
    ///     process's). Injected so tests can pin a known PATH.
    public static func build(
        operation: WikiOperation,
        wikiRoot: String,
        wikiID: String,
        systemPrompt: String,
        scratchDirectory: String,
        wikictlDirectory: String,
        resolvedExecutable: String = "claude",
        command: AgentCommandConfig = .default,
        sandbox: SandboxProfile.SandboxInvocation? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OperationCommand {
        // User env first, then app-owned keys (authoritative).
        var environment = baseEnvironment
        for (key, value) in command.parsedExtraEnv() {
            environment[key] = value
        }
        environment["WIKI_ROOT"] = wikiRoot
        environment["WIKI_DB"] = wikiID
        resolveWikictl(into: &environment, wikictlDirectory: wikictlDirectory, baseEnvironment: baseEnvironment)

        let model = command.modelOverride.isEmpty
            ? operation.topLevelModelAlias : command.modelOverride

        var arguments = command.tokenizedPrefixArgs()
        arguments.append(contentsOf: [
            "-p", operation.prompt(wikiRoot: wikiRoot),
            "--model", model,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--append-system-prompt", systemPrompt,
            // Scope the agent to wikictl + read-only inspection tools (issue #116 item 3).
            // This replaces the old --dangerously-skip-permissions bypass: non-sanctioned
            // Bash (uv/python/curl/...) is denied by Claude Code before exec.
            "--allowed-tools", Self.allowedToolsValue(includeFileWrites: true),
            "--disallowed-tools", Self.disallowedTools.joined(separator: ","),
        ])

        if let agentsJSON = operation.agentsJSON {
            arguments.append(contentsOf: ["--agents", agentsJSON])
        }

        let (executable, wrappedArguments) = applySandbox(
            to: resolvedExecutable,
            arguments: arguments,
            environment: &environment,
            scratchDirectory: scratchDirectory,
            sandbox: sandbox
        )

        return OperationCommand(
            executable: executable,
            arguments: wrappedArguments,
            environment: environment,
            currentDirectoryPath: scratchDirectory
        )
    }

    /// Build a stdin-backed `claude -p` query chat. Unlike one-shot
    /// operations, no prompt is passed as the positional `-p` value; user turns are
    /// sent later as stream-json over stdin while the session remains open.
    public static func buildInteractiveQuery(
        operation: WikiOperation,
        wikiRoot: String,
        wikiID: String,
        systemPrompt: String,
        scratchDirectory: String,
        wikictlDirectory: String,
        resolvedExecutable: String = "claude",
        command: AgentCommandConfig = .default,
        sandbox: SandboxProfile.SandboxInvocation? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OperationCommand {
        var environment = baseEnvironment
        for (key, value) in command.parsedExtraEnv() {
            environment[key] = value
        }
        environment["WIKI_ROOT"] = wikiRoot
        environment["WIKI_DB"] = wikiID
        resolveWikictl(into: &environment, wikictlDirectory: wikictlDirectory, baseEnvironment: baseEnvironment)

        let model = command.modelOverride.isEmpty
            ? operation.topLevelModelAlias : command.modelOverride

        // Chats are always write-capable now (the read-only Ask mode was
        // removed), so the chat command always includes Write/Edit in the
        // allow-list. `queryChatAllowsEdits` still reads `allowWikiEdits` from
        // the operation (retained for signature stability, always true from the
        // chat path) and defaults `true` for any non-chat op — fail-open for
        // tool access, since the seatbelt remains the authoritative write gate.
        let allowWikiEdits = Self.queryChatAllowsEdits(operation)

        var arguments = command.tokenizedPrefixArgs()
        arguments.append(contentsOf: [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--append-system-prompt", systemPrompt + "\n\n" + operation.prompt(wikiRoot: wikiRoot),
            // Scope the agent to wikictl + read-only inspection tools (issue #116 item 3),
            // replacing the old --dangerously-skip-permissions bypass.
            "--allowed-tools", Self.allowedToolsValue(includeFileWrites: allowWikiEdits),
            "--disallowed-tools", Self.disallowedTools.joined(separator: ","),
        ])

        let (executable, wrappedArguments) = applySandbox(
            to: resolvedExecutable,
            arguments: arguments,
            environment: &environment,
            scratchDirectory: scratchDirectory,
            sandbox: sandbox
        )

        return OperationCommand(
            executable: executable,
            arguments: wrappedArguments,
            environment: environment,
            currentDirectoryPath: scratchDirectory
        )
    }

    // MARK: - wikictl resolution

    /// Make the embedded `wikictl` reachable to the agent **without** depending on the
    /// agent's interactive shell preserving our `PATH`. Sets three things on `environment`:
    ///
    /// 1. `WIKICTL` — the absolute path to the binary. Env vars survive the agent's shell
    ///    init even when `PATH` does not: Claude Code's Bash tool runs the user's login
    ///    shell, whose startup may rebuild `PATH` from scratch (e.g. nix-darwin's
    ///    `/etc/zshenv`), discarding our prepend. The system prompt invokes `$WIKICTL`,
    ///    so resolution no longer rides on `PATH` at all.
    /// 2. `PATH` — still prepend the helper dir so a bare `wikictl` resolves where the
    ///    shell leaves our `PATH` intact (preserving any user `PATH`).
    /// 3. `__NIX_DARWIN_SET_ENVIRONMENT_DONE` — nix-darwin's shell init rebuilds `PATH`
    ///    only when this guard is unset (the case for a GUI/launchd-spawned app). Setting
    ///    it makes nix-darwin treat the environment as already initialized, so the `PATH`
    ///    prepend in (2) survives into the agent's shell. Inert on non-nix systems.
    static func resolveWikictl(
        into environment: inout [String: String],
        wikictlDirectory: String,
        baseEnvironment: [String: String]
    ) {
        environment["WIKICTL"] = wikictlDirectory + "/wikictl"
        let existingPath = environment["PATH"] ?? baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = wikictlDirectory + ":" + existingPath
        environment["__NIX_DARWIN_SET_ENVIRONMENT_DONE"] = "1"
    }

    // MARK: - Seatbelt wrapping

    /// The macOS seatbelt executable. Always present at this absolute path on macOS
    /// 15+ (deprecated but functional; no entitlement needed by an un-sandboxed app).
    static let sandboxExecutable = "/usr/bin/sandbox-exec"

    /// The path component appended to the scratch directory to form the `TMPDIR`
    /// relocation target for sandboxed spawns. Shared with `AgentLauncher` so that
    /// both the env-var writer (`applySandbox`) and the directory creator
    /// (`createSandboxTmpDir`) always agree on the same leaf name without duplication.
    public static let tmpRelocationLeaf = ".tmp"

    // MARK: - Permission scoping (replaces `--dangerously-skip-permissions`)

    /// The sanctioned exec + tool surface a spawned agent may use WITHOUT prompting.
    /// Replaces the old `--dangerously-skip-permissions` bypass (issue #116 item 3): the
    /// agent's only sanctioned job is calling `wikictl`, so any other Bash — interpreters,
    /// network tools, shells — is denied by Claude Code BEFORE exec, not just by the OS
    /// seatbelt. In headless `-p`, tools not in `--allowed-tools` are denied (the model
    /// receives a `permission-denied` tool_result and adapts); repeated denials abort the
    /// session, which self-terminates a prompt-injected attack.
    ///
    /// The read-only inspection commands (`cat`/`grep`/`sed`/`head`/`tail`/`wc`/`find`)
    /// are allowed because the prompts already instruct them and they add no exfiltration
    /// capability beyond the already-unrestricted `Read` tool — and `sed -i` writes
    /// outside scratch are still blocked by the seatbelt write fence. `pdftotext`/`strings`
    /// are deliberately NOT here: pdf2md pre-extracts markdown at ingest, and
    /// `plans/pdf-extraction.md` already directed their removal from the prompts.
    static let baseAllowedTools: [String] = [
        "Bash(wikictl:*)",
        "Bash(cat:*)", "Bash(grep:*)", "Bash(sed:*)",
        "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)", "Bash(find:*)",
        "Read", "Grep", "Glob", "Task", "TodoWrite",
    ]

    /// File-creation/modification tools. Included for all read-write spawns
    /// (Ingest / Lint / chat). Chats are always write-capable now, so the chat
    /// path always includes these; the seatbelt profile blocks writes at the
    /// kernel for any spawn whose sandbox fences them.
    static let fileWritingTools: [String] = ["Write", "Edit"]

    /// The exec/network surface explicitly DENIED even if a permissive user
    /// `~/.claude/settings.json` would allow it (Claude Code resolves deny over allow;
    /// CLI flags also outrank user settings). Targets the demonstrated attack vector
    /// (`uv run`), the other interpreter chains, network tools, and the AppleScript
    /// automation escape — none of which a wikictl-only agent ever legitimately needs.
    /// This is a backstop; the positive `--allowed-tools` list is the primary gate.
    static let disallowedTools: [String] = [
        "Bash(uv:*)", "Bash(uv)",
        "Bash(python:*)", "Bash(python3:*)",
        "Bash(ruby:*)", "Bash(node:*)",
        "Bash(curl:*)", "Bash(wget:*)",
        "Bash(sh:*)", "Bash(bash:*)", "Bash(zsh:*)", "Bash(osascript:*)",
        "WebFetch", "WebSearch",
    ]

    /// Build the comma-separated `--allowed-tools` value. `includeFileWrites`
    /// is `true` for all chat spawns (chats are always write-capable) and for
    /// Ingest/Lint.
    static func allowedToolsValue(includeFileWrites: Bool) -> String {
        var tools = baseAllowedTools
        if includeFileWrites { tools.append(contentsOf: fileWritingTools) }
        return tools.joined(separator: ",")
    }

    /// Extract `allowWikiEdits` from a `.queryChat` operation. Chats are always
    /// write-capable now (the chat path always constructs the operation with
    /// `allowWikiEdits: true`), so this is effectively always `true` for chats.
    /// Defensive default `true` (read-write) if `buildInteractiveQuery` is ever
    /// handed a non-chat operation — fail-open for tool access, since the
    /// seatbelt remains the authoritative write gate regardless.
    static func queryChatAllowsEdits(_ operation: WikiOperation) -> Bool {
        if case .queryChat(_, let allowWikiEdits) = operation { return allowWikiEdits }
        return true
    }

    /// When `sandbox` is non-nil, rewrite the invocation so the provider runs inside
    /// `/usr/bin/sandbox-exec -p <profile> -D … -- <provider>`, and relocate the
    /// provider's own config/temp into the scratch dir so they land inside the
    /// allowlist. When `nil`, returns the inputs unchanged (byte-identical to a
    /// pre-sandbox run). Pure; mutates `environment` only to add the relocation keys.
    private static func applySandbox(
        to resolvedExecutable: String,
        arguments: [String],
        environment: inout [String: String],
        scratchDirectory: String,
        sandbox: SandboxProfile.SandboxInvocation?
    ) -> (executable: String, arguments: [String]) {
        guard let sandbox else { return (resolvedExecutable, arguments) }

        // Relocate temp writes into scratch so they land inside the seatbelt allowlist.
        // CLAUDE_CONFIG_DIR is intentionally NOT redirected: Claude Code reads its
        // credentials from ~/.claude/.credentials.json, and pointing it at an empty
        // scratch dir hides those credentials. The seatbelt profile allows writes to
        // ~/.claude/ + ~/.claude.json (`SandboxProfile.generate`/`generateReadOnly`) so
        // a sandboxed session can persist its transcript; `claudeHomeDenyRules()` narrows
        // that allow by denying the execution-vector / credential paths (issue #116
        // item 4) — so CLAUDE_CONFIG_DIR redirection stays unnecessary AND the subtree
        // is no longer a persistence hole.
        environment["TMPDIR"] = scratchDirectory + "/" + Self.tmpRelocationLeaf

        var head: [String] = ["-p", sandbox.profile]
        for (key, value) in sandbox.defines {
            head.append(contentsOf: ["-D", "\(key)=\(value)"])
        }
        head.append(contentsOf: ["--", resolvedExecutable])
        return (sandboxExecutable, head + arguments)
    }
}
