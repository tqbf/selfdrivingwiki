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

        return OperationCommand(
            executable: resolvedExecutable,
            arguments: arguments,
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

        return OperationCommand(
            executable: resolvedExecutable,
            arguments: arguments,
            environment: environment,
            currentDirectoryPath: scratchDirectory
        )
    }
}
