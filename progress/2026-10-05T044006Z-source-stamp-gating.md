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

Review follow-up (PR #1369) closed a gap in layer 1's coverage and tightened
layer 2's wording. The gate keys on `WIKI_AUTHOR`, but the launcher injected
the env var only on the single-session spawn path — the large-source pipeline
(planner, executors, finalizer, and every quota-fallback spawn) composed its
phase environments without it, so those `wikictl` runs resolved
`.legacyImport` and the stamp applied: the incident path was still open. The
injection now lives in `AgentLauncher.ingestProvenanceEnvironment` — the one
seam every ingest spawn composes through (the one-shot profile, the
orchestrator's `hints(for:)`, and `runPhaseWithFallback`) — and stamps the
same `agent:ingest` identity the one-shot path resolved. One named constant
(`wikiAuthorEnvironmentKey`) replaces the per-site key literals. Step 6 of the
system prompt was reworded in the same pass: the affirmative `--source` rule
is now scoped to interactive chat ingests, so it can no longer be read
against the queued-pipeline NEVER three sentences later. `make prompts`
synced the bundled copy, and the refusal now also leaves a `DebugLog.ingest`
trace (Console.app) beside its stdout notice, which names the trust boundary:
the gate reads the host-set run author — it covers the taught workflow, not
an adversarial process that strips or overrides its own env.

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
- Review-fix pins: `ACPWiringTests` asserts every phase shape — planner,
  executor, finalizer, plus the single-session and parallel-executor
  composites — resolves `WIKI_AUTHOR=agent:ingest` through the real
  `resolveSpawnConfig`; `AgentLauncherStageKeyDispatchTests` pins the seam's
  exact env dict and that non-ingest requests leave the author to the
  one-shot site; `WikiCtlLogIndexTests` adds three scripted end-to-end pins
  (`chat:<id>`, uppercase `AGENT:ingest`, plain username — each keeps the
  ad-hoc stamp through the real parse → `applyEnv` → run path);
  `AgentPromptContractTests` pins the scoped interactive-chat wording and
  rejects the unscoped "always pass it" coming back.
