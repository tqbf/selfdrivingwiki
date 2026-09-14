---
timestamp: 2026-09-14T030000Z
title: Agent run context, sandbox scripting contract, CAS source edit-markdown
branch: main (working tree)
status: complete
---

# Agent run context, sandbox scripting contract, CAS source edit-markdown

## Progress

Implemented `plans/agent-scripting-and-processed-source-rewrite.md`
(architecture section added to `plans/sandbox-agent.md` §"Run context").

- **`AgentRunContext`** (new, `Sources/WikiFSEngine/AgentRunContext.swift`):
  typed per-run capability context — canonical scratch, `<scratch>/.tmp`,
  `<scratch>/.tmp/zsh`, typed `WikiID`, trusted absolute `wikictl` path,
  effective `PATH`, staged state/source paths. Includes `ShellQuoting` (POSIX
  single-quote rendering for prompt injection) and `UserEnvironmentPath`
  (shell-neutral login-shell PATH discovery through `$SHELL`/passwd record,
  process-PATH fallback, injected runner for tests).
- **Threading:** the launcher builds one context per run (`makeRunContext`),
  creates the temp roots before any sandbox applies, derives independent
  contexts for fallback-provider scratch dirs, and threads the context through
  every profile: one-shot, ingest planner/executors/finalizer, quota fallback,
  resume, new session, interactive chat. `ACPBackend.startProcess` merges
  provider env first, then overwrites the protected keys
  (`WIKI_DB`/`WIKICTL`/`WIKI_SCRATCH`/`PATH`/`TMPDIR`/`TMPPREFIX`);
  `requestedSessionCWD` prefers the run-context scratch for
  newSession/resume/fork.
- **Prompts:** every operation prompt (one-shot, ingest phases, fallback,
  interactive chat) now ends with a RUN ENVIRONMENT block naming the absolute
  scratch/temp/state/source paths and the trusted absolute
  `wikictl --wiki <id>` invocation. `system-prompt-default.md` gained the
  scripting section (scratch-only Bun/Python/sh, direct invocation, file
  delivery) and the processed-source rewrite workflow; `chat.md`,
  `ingest-write-rule.md`, `wiki-tree-render.md`, `ingest-executor.md`,
  `ingest-finalizer.md` share one delivery rule; the categorical heredoc ban
  and the "do NOT pass --wiki" claim are gone. `make prompts` synced the
  bundled copies.
- **CAS rewrite:** `SourceMarkdownConflictError` (WikiFSCore),
  `WikiStore.appendUserProcessedMarkdown` + GRDB implementation (one `mutate`
  transaction: head compare → blob → `.user` version → ref upsert → FTS;
  post-commit one event + one embedding; `reembedInterceptor` test seam),
  `WikiStoreError.noProcessedMarkdown`, CLI `source edit-markdown --expect-head`
  now REQUIRED with exit-3 conflict mapping, `source info` prints
  `head_version_id`, CLIReference/usage docs updated,
  `SourceCommand.run` doc corrected (writes commit).
- **Tests:** new `AgentRunContextTests`, `AgentRuntimePathTests`,
  `AgentSandboxProcessTests` (live `/usr/bin/sandbox-exec`), and
  `AgentPromptContractTests` + `PromptResourceSyncTests`; extended
  `ACPWiringTests`, `WikiCtlCommandTests`, `HeadVersionEchoTests`,
  `StoreEmissionTests`, `SourceEmbeddingSearchTests`,
  `StoreEmissionExhaustivenessTests`.

Measured behavior recorded in `plans/sandbox-agent.md`: zsh heredocs honor a
scratch-local `TMPPREFIX`; macOS `sh`/`bash` stage heredoc temps in `/tmp`
regardless of `TMPDIR`, so in-shell heredocs stay outside the fence and
heredoc bodies flow through stdin or scratch files. The fence still permits no
`/tmp` write access.

## Verification

- `make build` — pass (app built + signed).
- `make test` — pass. 4393 tests, 471 suites.
- Bare `swift build` + `swift test` (after prompt sync) — pass, same totals.
- `WIKIFS_APP_TESTS=1 swift test --filter
  "AgentSandboxProcessTests|AgentRuntimePathTests|AgentRunContextTests|ACPWiringTests"`
  — 59 tests pass, including live-sandbox coverage: `/bin/sh` transform +
  outside-write denial, stdin heredoc transform, zsh heredoc with scratch
  `TMPPREFIX` (this machine has zsh), installed Python and Bun smokes, the
  absolute `wikictl --wiki <id>` CAS rewrite with `WIKI_DB`/`WIKICTL`/`PATH`
  removed, raw bytes unchanged, and the cross-wiki mutation denial.
- `swift test --filter "WikiCtlCommandTests|HeadVersionEchoTests|StoreEmissionTests|SourceEmbeddingSearchTests|StoreEmissionExhaustivenessTests"`
  — pass (CAS match appends one `.user` child + one event + one embedding
  schedule + new-head echo; stale head exits conflict with no mutation, no
  event, no embedding; two writers from one head produce exactly one append;
  scratch-style `--file` input works; `source info` head line).
- `swift test --filter
  "AgentPromptContractTests|PromptResourceSyncTests|GeneratedPromptsParityTests"`
  — pass (prompt contract + canonical/bundled sync).
- `make prompts` run after every prompt edit.
- Not run here: the disposable-wiki manual scenario
  (`ManualScenarios.sandboxedProcessedSourceRewrite`) — procedure documented in
  the feature plan for the PR gate.
