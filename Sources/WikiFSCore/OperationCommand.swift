import Foundation

/// The fully-assembled `claude -p` invocation for one `WikiOperation` run, scoped
/// to one wiki (`plans/llm-wiki.md` Phase C — "`claude -p` orchestration").
///
/// PURE and injectable: built by `OperationCommand.build(...)` from the operation,
/// the wiki's live mount path, its DB id, its `system_prompt` body, a per-run
/// scratch dir, and the directory holding `wikictl`. No process is spawned here —
/// the app's `AgentLauncher` runs `executableURL` with `arguments`, `environment`,
/// and `currentDirectory`. This split is what lets the Phase-C gate unit-test the
/// EXACT flag surface (`--append-system-prompt`, `--allowedTools`, the env, the
/// scratch cwd, and `wikictl`-on-PATH) without a real agent run.
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

    /// The `--allowedTools` value (decision: least privilege). `wikictl` is the
    /// only write path; the rest are read-only shell + read tools. The CLI accepts
    /// a single space-separated string for this flag (verified against
    /// `claude --help` 2.x: "Comma or space-separated list of tool names").
    ///
    /// `Bash(wikictl:*)` scopes Bash to wikictl invocations; `Bash(find:*)` /
    /// `(cat:*)` / `(grep:*)` / `(printf:*)` cover read-only browsing and the
    /// stdin-piped `--body-file -` writes; `Read`/`Grep`/`Glob` are the read tools.
    public static let allowedTools =
        "Bash(wikictl:*) Bash(find:*) Bash(cat:*) Bash(grep:*) Bash(printf:*) Read Grep Glob"

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
    ///     (`WikiFS.app/Contents/Helpers`). PREPENDED to the child's PATH so the
    ///     agent's `Bash(wikictl:*)` calls resolve.
    ///   - claudeExecutable: the `claude` binary name (default `"claude"`; the
    ///     PATH preflight confirms it resolves on the login shell).
    ///   - baseEnvironment: the parent environment to inherit (default the current
    ///     process's). Injected so tests can pin a known PATH.
    public static func build(
        operation: WikiOperation,
        wikiRoot: String,
        wikiID: String,
        systemPrompt: String,
        scratchDirectory: String,
        wikictlDirectory: String,
        claudeExecutable: String = "claude",
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> OperationCommand {
        var environment = baseEnvironment
        environment["WIKI_ROOT"] = wikiRoot
        environment["WIKI_DB"] = wikiID
        // Prepend the helper dir so `wikictl` resolves for the agent's Bash calls,
        // without shadowing system tools the agent also needs (find/cat/grep).
        let existingPath = baseEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = wikictlDirectory + ":" + existingPath

        let arguments = [
            "-p", operation.prompt,
            "--append-system-prompt", systemPrompt,
            "--allowedTools", allowedTools,
        ]

        return OperationCommand(
            executable: claudeExecutable,
            arguments: arguments,
            environment: environment,
            currentDirectoryPath: scratchDirectory
        )
    }
}
