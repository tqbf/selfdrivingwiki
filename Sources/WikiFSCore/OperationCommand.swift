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
    /// The headline diagnostic for claude's "Not logged in · Please run /login":
    /// `CLAUDE_CONFIG_DIR` is relocated into an empty per-run scratch dir whenever
    /// the run is sandboxed (the read-only query default), so the child can't see
    /// the user's `~/.claude` credentials. `authSet` lists which API-key env vars
    /// are present (NAMES ONLY, never values) — an empty list plus a relocated
    /// `CLAUDE_CONFIG_DIR` is the fingerprint of that failure.
    public var debugSummary: String {
        let redactedArgs = arguments.map { Self.redactArgument($0) }.joined(separator: " ")
        let reportedEnvKeys = ["CLAUDE_CONFIG_DIR", "HOME", "TMPDIR", "PATH", "WIKI_ROOT", "WIKI_DB"]
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
    ///     byte-for-byte. The relocation env (`CLAUDE_CONFIG_DIR`, `TMPDIR`) is set
    ///     only when non-nil; it never clobbers `WIKI_ROOT`/`WIKI_DB`/`PATH`.
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
        // Prepend the helper dir so `wikictl` resolves; preserve any user PATH.
        let userPath = environment["PATH"]
        let existingPath = userPath ?? baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = wikictlDirectory + ":" + existingPath

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
            "--dangerously-skip-permissions",
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

    /// Build a stdin-backed `claude -p` query conversation. Unlike one-shot
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
        let userPath = environment["PATH"]
        let existingPath = userPath ?? baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = wikictlDirectory + ":" + existingPath

        let model = command.modelOverride.isEmpty
            ? operation.topLevelModelAlias : command.modelOverride

        var arguments = command.tokenizedPrefixArgs()
        arguments.append(contentsOf: [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", model,
            "--append-system-prompt", systemPrompt + "\n\n" + operation.prompt(wikiRoot: wikiRoot),
            "--dangerously-skip-permissions",
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

    // MARK: - Seatbelt wrapping

    /// The macOS seatbelt executable. Always present at this absolute path on macOS
    /// 15+ (deprecated but functional; no entitlement needed by an un-sandboxed app).
    static let sandboxExecutable = "/usr/bin/sandbox-exec"

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

        // Relocate the provider's self-writes into the writable scratch zone so the
        // profile allowlist stays tiny. These keys are distinct from WIKI_ROOT /
        // WIKI_DB / PATH, so they don't clobber the app-owned block.
        environment["CLAUDE_CONFIG_DIR"] = scratchDirectory + "/.claude-config"
        environment["TMPDIR"] = scratchDirectory + "/.tmp"

        var head: [String] = ["-p", sandbox.profile]
        for (key, value) in sandbox.defines {
            head.append(contentsOf: ["-D", "\(key)=\(value)"])
        }
        head.append(contentsOf: ["--", resolvedExecutable])
        return (sandboxExecutable, head + arguments)
    }
}
