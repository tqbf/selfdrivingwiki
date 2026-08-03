---
timestamp: 2026-06-16T162227Z
title: "2026-06-16 — Ingest division of labor: Opus curates/writes, Sonnet only digests — DONE ✅ (user-verified, merged to main)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-06-16 — Ingest division of labor: Opus curates/writes, Sonnet only digests — DONE ✅ (user-verified, merged to main)

## Progress


CORRECTION to the model-tiering build below.
The prior build (commit `caebfd7`) tiered by model but with the WRONG division of
labor (tiny → Sonnet single pass; large → Opus *planner* that delegated **page
writing** to Sonnet `ingest-worker`s). The user's guiding principle: **Opus is
ALWAYS the curator — it decides what goes in the wiki and WRITES everything. Sonnet
exists ONLY to chew through large volumes of source content; Sonnet NEVER writes.**

**Corrected architecture.**
- **Tiny source** (`< 4 KB`, `IngestPlan.singleOpus`) → a single `--model opus` pass,
  no `--agents`. Opus reads the small staged source and writes the pages + index +
  log itself. (Opus must decide what belongs even for small sources.)
- **Large source** (`IngestPlan.opusCurator`) → `--model opus` curator + `--agents`
  `'{"source-reader":{"model":"sonnet","tools":["Bash","Read"],…}}'`. Opus INSPECTS
  the source's size/structure (`wc`/`head`/page count) WITHOUT reading the whole bulk,
  splits it into chunks, and forks **2–19** Sonnet `source-reader` DIGESTERS to READ
  the chunks in parallel and return STRUCTURED DIGESTS. Opus then synthesizes the
  digests, decides the page set, and WRITES every page + `index.md` + the log entry
  itself. Opus MAY fork more workers for follow-up QUESTIONS and MAY pull pages via
  `wikictl page get` to double-check — the `<20` cap is on TOTAL Sonnet invocations.
- The Sonnet worker has **read-only tools** (`["Read","Bash"]`, no wikictl), and its
  prompt (`IngestPlan.digesterPrompt`) carries NO write rule — it only reads + returns
  a digest. The write rule (`IngestWriteRule.writes`) now leads ONLY the Opus prompts
  (single + curator), since Opus is the writer (`OperationCommandTests` asserts both
  ways). Top-level `--model` is `opus` in BOTH Ingest modes; the tiering is purely in
  the fan-out. Query/Lint unchanged (single-Opus + write rule + WIKI_STATE +
  don't-rediscover).

**Verified (CLI 2.1.178, real `--agents` smoke test):** top level ran on
`claude-opus-4-8`; the `source-reader` subagent resolved to `claude-sonnet-4-6`
(`"resolvedModel":"claude-sonnet-4-6"`), READ the staged source via its `Read` tool,
and returned its digest to the Opus parent, which replied `DIGEST_RECEIVED: …`. No
wikictl anywhere in the worker. Delegation still surfaces as an `Agent` `tool_use` +
`system`/`task_started`/`task_notification` events; the `AgentEvent` parser maps those
to `.subagent` and the activity panel renders the fan-out as purple "reading" / green
"digested" rows (relabeled from "delegated"/"finished" + `doc.text.magnifyingglass`
icon, since the workers now READ, not write).

**Tests / build.** Reworked the two-mode argv + plan tests: tiny → `--model opus` no
`--agents`; large → `--model opus` + a read-only `source-reader` digester whose prompt
DIGESTS (not writes); the curator prompt carries the 2–19 guardrail + "fork more for
questions / pull pages to double-check" + "Opus writes every page"; the worker prompt
has no wiki-write instructions. `make test` → **320/320** green; `make` clean signed
bundle. Live gate (orchestrator `make install` + watch a large Ingest) pending: proof
is no mount-probing, Opus does the writing, a visible fan-out of 2–19 Sonnet *reader*
workers, and Opus optionally asking follow-ups / pulling pages.

### Superseded — 2026-06-16 — Ingest redesign: write-rule in the prompt, local staging, model tiering

Branch `feature/ingest-fewer-turns`. Fixes three problems a live Ingest run exposed.
(The model-tiering division of labor in item #3 below was corrected by the entry
above; items #1 and #2 — the write rule in the `-p` prompt, and local staging — still
stand.)

**1. Agent probed the read-only mount instead of writing.** Phase D moved the
`wikictl` write rule entirely into `--append-system-prompt`, which the agent
under-weights — in a real run it printed *"The mount is read-only. There must be a
dedicated tool for wiki mutations. Let me search."*, ran ToolSearch, then
`echo > pages/by-title/__wikitest__.md` to test the mount. Fix: the load-bearing
write rule + the exact `wikictl` write commands now lead EVERY `-p` prompt
(`IngestWriteRule.writes`), while the layout map / conventions stay in the schema
(DRY — asserted both ways in `OperationCommandTests`).

**2. Wasted orientation turns + laggy mount reads.** The app now STAGES into the
per-run scratch dir, reading from SQLite (not the ~5s-laggy mount): `WIKI_STATE.md`
(titles + index.md + log tail, via `WikiStateSnapshot.renderStateFile`) and, for
Ingest, the raw `source.<ext>` bytes (via `ingestedFileContent`). The prompt names
those absolute paths and forbids `wikictl page list` / re-reading index.md/log.md
(`IngestWriteRule.dontRediscover`). Staging is owned by `AgentLauncher` (it owns the
scratch dir); the per-op intent is the new app-side `OperationRequest`, whose pure
pieces (`AgentStaging` leaf-name math, the `WIKI_STATE.md` rendering, the plan
decision) are core-tested.

**3. Model tiering.** App picks the mode by source size (`IngestPlan.decide`,
threshold `tinySourceByteThreshold = 4096`). **Tiny** (`< 4 KB`) → single
`--model sonnet` pass, no `--agents`. **Non-tiny** → `--model opus` planner +
`--agents '{"ingest-worker":{"model":"sonnet",…,"tools":["Bash","Read"]}}'`: Opus
plans the page set, fans out to **2–19** Sonnet workers (prompt-level guardrail:
"use more than 1 and fewer than 20; size the fan-out to the material"), then Opus
synthesizes `index.md` + the log entry. Query/Lint stay single-agent Opus but ALSO
get the write rule + the staged state + the don't-rediscover directive. The worker
prompt is SELF-SUFFICIENT (a custom agent's `prompt` doesn't inherit
`--append-system-prompt`, so it embeds the full write rule).

**Verified mechanism (CLI 2.1.178, real `--agents` smoke test):** top level ran on
`claude-opus-4-8`, the `worker` subagent resolved to `claude-sonnet-4-6`
(`"resolvedModel":"claude-sonnet-4-6"`; `modelUsage` shows both). Aliases: `opus` →
`claude-opus-4-8`, `sonnet` → `claude-sonnet-4-6`. The `--agents` JSON shape is
`{"<name>":{"description","model","prompt","tools"}}`. Delegation surfaces in the
stream as an `Agent` `tool_use` plus `system`/`task_started` + `task_notification`
events — the `AgentEvent` parser now maps those to a `.subagent` event and the
activity panel renders the Opus→Sonnet fan-out as indented purple "delegated" /
green "finished" rows.

**Tests / build.** +20 tests (the two-mode argv builder, the 2..19 guardrail text,
the write-rule + staged paths + don't-rediscover assertions, the schema-not-
duplicated check, `IngestPlan` threshold, `AgentStaging` path math + WIKI_STATE.md
rendering, the `.subagent`/`Agent` parser cases). `make test` → **320/320** green;
`make` clean signed bundle. Live gate (orchestrator `make install` + watch an
Ingest) pending: proof is no mount-probing, few/no orientation turns, a visible
Opus→Sonnet fan-out.

## Verification

Historical verification remains in the progress record above.
