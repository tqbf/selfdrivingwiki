# Agent scripting and CAS-protected processed-source rewrite

**Status:** Implemented. Gives sandboxed wiki agents a shell-neutral run
contract (scratch scripting with Bun/Python/`sh`), and exposes
`source edit-markdown` to agents as a CAS-protected processed-Markdown
rewrite. Architecture and threat model: `plans/sandbox-agent.md` §"Run
context". Origin: chat `01M2EXC4NEDK5WYEMZGFADYXCH` (Codex ACP moved the
nested tool cwd and dropped `WIKI_DB`; the rbenv-init heredoc hit the
`/tmp/zsh` denial).

## Problem

Two failures, one root shape: the run's correctness depended on things the
sandbox does not control.

1. **Adapter drift.** The adapter, not the app, decides the nested tool cwd and
   which environment variables survive. Prompts said "run bare `wikictl`, it
   targets this wiki via `$WIKI_DB`" — both claims broke in the field.
2. **The heredoc claim was wrong.** Prompts banned heredocs because "the
   sandbox blocks the temp file". Measured truth: zsh heredocs failed because
   zsh keeps its own `TMPPREFIX` (`/tmp/zsh…`), which the sandbox did not
   relocate; `TMPDIR` relocation alone does not cover zsh. And macOS `sh` /
   `bash` stage heredoc temp files in `/tmp` REGARDLESS of `TMPDIR`, so an
   in-shell heredoc can never run inside the fence.

Separately, "rewrite a source" had no agent-facing meaning: the CLI operation
existed but was undocumented to agents and did a blind write.

## Design

### Typed run context (`AgentRunContext`)

One `Sendable` value per run replaces loosely typed env threading:

- canonical timestamped scratch (the ACP session cwd),
- `<scratch>/.tmp` (`TMPDIR`) and `<scratch>/.tmp/zsh` (`TMPPREFIX`),
- typed `WikiID` + trusted absolute `wikictl` path,
- effective `PATH` = helper directory + user environment `PATH` (deduplicated,
  first-hit order; the user PATH resolves through the account's configured
  login shell — `$SHELL` / passwd record, never hard-coded zsh — with the
  process PATH as fallback),
- staged state/source paths.

The launcher builds it once per run (`makeRunContext`), creates the temp roots
BEFORE the sandbox applies, derives an independent context for fallback-provider
scratch dirs (`withScratch`), and threads it into every `BackendProfile`:
one-shot, ingest planner/executors/finalizer, quota fallback, resume,
new session, and interactive chat.

### Protected environment

`ACPBackend.startProcess` merges provider env first, then overwrites
`WIKI_DB`, `WIKICTL`, `WIKI_SCRATCH`, `PATH`, `TMPDIR`, `TMPPREFIX` from the
run context. These exports are conveniences for adapters that preserve them —
never capabilities.

### Prompt injection

Every operation prompt ends with a RUN ENVIRONMENT block: absolute scratch,
temp, state, and staged-source paths, plus the trusted invocation rendered
shell-safe by one tested helper (`ShellQuoting`):
`'/abs/Helpers/wikictl' --wiki <ulid>`. Prompt text is data, not a capability;
the Seatbelt active-DB allowlist stays the security boundary.

### Processed-Markdown rewrite (CAS)

- `WikiStore.appendUserProcessedMarkdown(sourceID:content:expectedHead:)` —
  ONE `mutate` transaction: compare the active head, then blob + one `.user`
  version (parent = expected head) + ref upsert + FTS. Mismatch throws
  `SourceMarkdownConflictError` BEFORE any write. Post-commit: one event
  (through `mutate`'s seam) + one embedding schedule (`reembedInterceptor` is
  the test spy).
- CLI: `source edit-markdown --expect-head <id>` is REQUIRED (usage error
  otherwise); conflict exits 3 with a re-read / reapply-once / retry-once
  message. `source info` prints `head_version_id` — the read that feeds CAS.
- `appendProcessedMarkdown` is unchanged for trusted extraction/transcript
  callers.
- Prompts teach the flow only for explicit user requests; raw bytes stay
  immutable; the mount stays read-only.

### Prompt contract (AC.9 shape)

`prompts/system-prompt-default.md` carries the tooling section: scratch-only
scripting, direct Bun/Python invocation with `command -v` discovery, portable
`/bin/sh` as baseline, file delivery for bodies, heredoc correction (quoted
heredocs work; scratch files preferred). `chat.md` carries the rewrite flow.
`ingest-write-rule.md`, `wiki-tree-render.md`, `ingest-executor.md`,
`ingest-finalizer.md` share one delivery rule. `make prompts` syncs the bundled
copies; `AgentPromptContractTests` + `PromptResourceSyncTests` pin all of it.

## Non-goals

- No executable allowlist and no bundled runtimes. Bun/Python are used only
  when installed; real-runtime smokes are capability-gated skips.
- No raw-source writes, no File Provider writes, no broad `/tmp` allowance.
- Login shells are for PATH discovery only — never a per-command prerequisite.

## Review outcome (independent reviewer, post-implementation)

- **Interactive resume prompt refresh (fixed).** A resumed chat sent only the
  raw user message, so the model kept the PREVIOUS run's authoritative paths.
  Resume now prepends the current `promptContextSection()` with a
  supersedes note; displayed text stays the raw user message
  (`continueChatResumesAndSkipsFreshStart` pins it).
- **Shared Claude temp namespace (rebutted here, tracked in ISSUES.md).** The
  `CLAUDE_TMP` allow and the `claude-*-cwd` regex pre-date this change (the
  diff touches `SandboxProfile.swift` comments only). Narrowing them needs
  per-session path resolution for Claude Code — recorded as a known issue with
  a follow-up direction, not a regression of this feature.
- **No findings** on quoting/injection, protected-env precedence, launch-path
  coverage, CAS atomicity/events/embeddings, or raw-source immutability.

## Verification

| Claim | Evidence |
| --- | --- |
| Run-context purity + protected merge | `AgentRunContextTests`, `ACPWiringTests.protectedRunEnvironmentOverridesProviderHints` |
| PATH assembly + shell-neutral discovery | `AgentRunContextTests` (injected runner), `AgentRuntimePathTests` (fixture runtimes) |
| Live fence + heredocs + runtimes | `AgentSandboxProcessTests` (real `sandbox-exec`; zsh test gated on `/bin/zsh`; Bun/Python gated on install) |
| Absolute `wikictl` without agent env; cross-wiki denial | `AgentSandboxProcessTests.absoluteWikictlInvocationWorksWithoutAgentEnvironment`, `.productionSandboxPreventsCrossWikiMutation` |
| CAS atomicity, events, embedding, head echo | `WikiCtlCommandTests`, `HeadVersionEchoTests`, `StoreEmissionTests`, `SourceEmbeddingSearchTests`, `StoreEmissionExhaustivenessTests` |
| Prompt contract + sync | `AgentPromptContractTests`, `PromptResourceSyncTests`, `GeneratedPromptsParityTests` |
| Manual scenario | `ManualScenarios.sandboxedProcessedSourceRewrite` — see the procedure below |

### Manual scenario — sandboxed processed-source rewrite

Run on macOS with sandbox enabled, against a disposable test wiki:

1. Open a chat and ask the agent to clean the processed transcript of an
   existing source.
2. Confirm the task prompt carries the RUN ENVIRONMENT block and the script
   uses the absolute scratch paths and the absolute `wikictl --wiki <id>` form.
3. Confirm a new processed version becomes active, the raw source bytes are
   unchanged, prior versions stay selectable, and the UI refreshes.
4. Edit the source from the app while the agent works; confirm the agent's
   stale write exits 3 and the agent re-reads, retries once, then reports.
5. Ask the agent to write outside scratch and to target another wiki; confirm
   both stay denied.
