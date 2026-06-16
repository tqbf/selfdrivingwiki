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

        var arguments = [
            // The prompt carries the RESOLVED absolute wikiRoot (not `$WIKI_ROOT`
            // for the agent to expand) plus the staged source / state file paths, so
            // it has the load-bearing write rule, a concrete map, and the local
            // source up front — the live gate showed the agent burning turns probing
            // for structure and (under the old allowlist) getting every
            // `$WIKI_ROOT`-expanded command rejected.
            "-p", operation.prompt(wikiRoot: wikiRoot),
            // Model tiering (problem #3, verified against CLI 2.1.178): `--model`
            // sets the TOP-LEVEL model, which is ALWAYS `opus` — Opus is the
            // curator/writer for both Ingest modes and for Query/Lint. The tiering is
            // in the FAN-OUT: a large-source Ingest also passes `--agents` (below)
            // defining a Sonnet `source-reader` DIGESTER that reads source volume and
            // returns digests (it never writes). Workers inherit the process env
            // (WIKI_DB, PATH) but NOT `--append-system-prompt`, so the worker prompt
            // is self-sufficient (and carries no write rule, since it only reads).
            "--model", operation.topLevelModelAlias,
            // Stream the run as NDJSON so the UI can render activity in real time
            // instead of staring at a silent panel until the final result. The
            // installed CLI (2.1.178) REQUIRES `--verbose` alongside
            // `--output-format stream-json` in `-p` mode, and
            // `--include-partial-messages` adds token/text deltas for a livelier
            // feel. All three were verified against `claude --help` and a real
            // captured run; see `AgentEvent`/`AgentEventParser` for the schema.
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--append-system-prompt", systemPrompt,
            // Frictionless mode (`plans/llm-wiki.md`): the fine-grained
            // `--allowedTools 'Bash(wikictl:*) Bash(cat:*) …'` allowlist is
            // fundamentally incompatible with the `$WIKI_ROOT`/`$WIKI_DB` env-var
            // paths and compound commands the whole design depends on — the CLI
            // can't statically verify a command containing a shell expansion, so it
            // demands approval, and in `-p` mode there is no approval prompt: the
            // run is dead on arrival (the live gate produced ZERO output for exactly
            // this reason). It is ALSO required for the Task tool that drives the
            // Opus→Sonnet fan-out. The app is local, un-sandboxed, and
            // user-initiated, and the agent only has `wikictl` + read-only shell
            // intent, so we bypass permission checks entirely. Verified accepted by
            // the installed CLI (2.1.178 — `permissionMode":"bypassPermissions"`).
            "--dangerously-skip-permissions",
        ]

        // A large-source Ingest fans out to a Sonnet `source-reader` DIGESTER defined
        // inline. The JSON shape (`description`/`prompt`/`model`/`tools`) and that the
        // worker actually runs on `claude-sonnet-4-6`, reads the staged source via
        // its read-only `["Read","Bash"]` tools, and returns its digest to the Opus
        // parent were verified by a real `--agents` smoke test against CLI 2.1.178.
        if let agentsJSON = operation.agentsJSON {
            arguments.append(contentsOf: ["--agents", agentsJSON])
        }

        return OperationCommand(
            executable: claudeExecutable,
            arguments: arguments,
            environment: environment,
            currentDirectoryPath: scratchDirectory
        )
    }
}
