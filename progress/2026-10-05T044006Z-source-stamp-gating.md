---
timestamp: 2026-10-05T044006Z
title: Author-gated source stamp refusal
branch: bugfix/issue-1367-source-stamp-gating
status: in-review
---

# Author-gated source stamp refusal

## Progress

Issue #1367: a queued ingest job failed at 17:42:13 after the planner had
already run 62 `wikictl log append --kind ingest --source <id>` calls. The
stamps survived the failure. The sources showed as Ingested with no completed
ingestion behind them.

The host stamps sources itself at validated-successful job completion
(#1344). The mid-run agent stamps were supposed to be retired — #1347 removed
`--source` from the four pipeline task prompts — but the mounted system
prompt still taught the flag for the ad-hoc chat path, and task-prompt
silence lost to that explicit instruction.

The fix has two layers.

Layer 1 — enforcement in `wikictl`. The `log append` command now resolves the
run author. `ArgumentParser.applyEnv` routes `WIKI_AUTHOR` onto the parsed
`logAppend` command (`log append` takes no `--author` flag, so the env is the
only source; the case keeps the flag > env precedence shape).
`LogIndexCommand.Action.logAppend` carries the author as a typed `PageAuthor`
— parsed once at the CLI boundary in `Sources/wikictl/main.swift`, never a
bare string prefix check. When the resolved author is an `.agent` run and the
command passes `--source` with `--kind ingest`:

- the log row still lands (the record is harmless and useful),
- `markSourceIngested` is skipped,
- one notice line prints on stdout
  (`LogIndexCommand.agentStampRefusalNotice(source:)`), and
- the command still succeeds.

The refusal path also skips the unknown-`--source` existence check. That
check protects the stamp: it stops a typo'd id from looking like it worked.
An agent-authored run never stamps, and the notice says so, so the row must
land. `chat:` authors, `.user`, and unset authors keep today's behavior
exactly — stamp applies, no notice.

Layer 2 — prompt hardening. Explicit beats silence. The system prompt's
Ingest workflow step 6 keeps the ad-hoc chat allowance and adds the
queued-pipeline rule: NEVER pass `--source` on `wikictl log append`; the app
marks sources Ingested itself at successful job completion. The four pipeline
prompts that mention recording (`ingest-single-task.md`,
`ingest-curator-task.md`, `ingest-finalizer.md`, `ingest-write-rule.md`) each
carry the one-line prohibition at that point. The planner never records, so
it keeps #1344's absolute silence on `--source`. `make prompts` synced the
bundled copies.

The `pipelineIngestPromptsDropTheSourceRitual` guard now distinguishes
teaching from prohibiting: `--source` may appear in a task prompt only inside
the prohibition sentence. A new guard pins the system prompt's rule.

## Verification

- `make build` passed (app built and signed).
- `make test` passed (full suite, 0 failed).
- Targeted suites passed: `WikiCtlLogIndexTests` (7 new tests: agent author
  refuses the stamp and commits the row; unknown source still commits; no
  `--source` stays quiet; `chat:`/unset/agent-lookalike authors still stamp;
  scripted end-to-end exit 0 with notice and no stamp), `WikiCtlCommandTests`
  (2 new `WIKI_AUTHOR` env-routing tests), `AgentPromptContractTests`
  (reworked ritual guard + new system-prompt prohibition guard),
  `GeneratedPromptsParityTests`, `CumulativeIngestContractTests`,
  `DocumentationContractTests`.
