---
timestamp: 2026-07-11T032353Z
title: "2026-07-10 — Multi-phase ACP ingestion (planner → executors → finalizer)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-10 — Multi-phase ACP ingestion (planner → executors → finalizer)

## Progress


**Problem:** Large-source ACP ingestion relied on Claude's in-process sub-agents
(the Sonnet `source-reader` digester spawned via `--agents`). Sub-agents don't
work over ACP — the protocol has no custom agent types and background agents
can't complete within a single turn. So a large ingest over ACP silently stalled.

**Fix:** Replaced the one-shot spawn with a multi-process architecture for ACP
large ingests (> 4 KB):

1. **Planner** (Opus, 1 session): reads staged sources, decides the page set,
   writes a `plan.json` to the scratch directory. Does NOT write wiki pages.
2. **Executors** (Sonnet, N sessions — one per source file): each reads its
   assigned pages from `plan.json` + the source section, writes pages via
   `$WIKICTL page upsert`. Sequential (parallel is a future optimization).
3. **Finalizer** (Opus, 1 session): reads `$WIKICTL page list`, writes
   `index.md` via `$WIKICTL index set`, records log entries via
   `$WIKICTL log append --kind ingest --source <id>`.

Each phase is a clean, independent single-turn ACP session — no sub-agents, no
background dispatch, no sleep. Tiny sources (< 4 KB) and all CLI runs use the
existing single-session path unchanged.

**Lifecycle design:** `runACPIngestPlannerExecutors()` is a structural
replacement for `run()`'s spawn-commit block. It is dispatched AFTER `run()` has
acquired the generation gate, fired `onLock`, opened log files, and set
`isRunning`/`ingestingSourceIDs`. It owns per-phase: `BackendProfile` (model
override), `sessionHandle`, `currentRunToken`. The per-phase `onExit` closure
does NOT call `finish()` (phase-tracking only); `finish()` is called exactly once
at the end. If the user hits Stop, `stopAgent()` cancels the live phase's session,
remaining phases are skipped, and `finish()` runs once via the cancellation path.

**Fallback:** If the planner fails or produces no valid `plan.json`, the
orchestration falls back to single-session ACP ingest (the original one-shot
prompt with the "no sub-agents" instruction).

**Model override for executors:** The alias "sonnet" doesn't match
`ACPModelSelectionResolver` (exact-id matching). Instead, after the planner
session starts, the advertised models are read via `ACPBackend.availableModels`
and the first model whose id/name contains "sonnet" is selected. Falls back to
the provider's default if no match.

**Files changed:**
- `Sources/WikiFSCore/ACPIngestPlan.swift` (**new**): `Codable` plan schema
  (`ACPIngestPageAssignment`, `ACPIngestPlan`), tolerant JSON extraction
  (`extract(from:)` — strips fences, substrings `{`→`}`), pure prompt builders
  (`ACPIngestPrompts.plannerPrompt`/`executorPrompt`/`finalizerPrompt`).
- `Sources/WikiFS/AgentLauncher.swift`: `runACPIngestPlannerExecutors()` method
  + `runPhase()` helper + `runACPIngestFallback()` + `findSonnetModelId()`.
  Dispatch point inserted after `onLock` in `run()` for `useACP && .opusCurator`.
- `prompts/ingest-planner.md`, `prompts/ingest-executor.md`,
  `prompts/ingest-finalizer.md` (**new**): codegen'd into `GeneratedPrompts.swift`.
- `Tests/WikiFSTests/FakeAgentBackend.swift` (**new**): test double conforming to
  `AgentBackend`.
- `Tests/WikiFSTests/ACPIngestPlanTests.swift` (**new**): 23 tests — plan
  encode/decode round-trip, `assignments(forSource:)`, `distinctSourceFiles`,
  tolerant JSON extraction (clean/fenced/prose-wrapped/invalid), prompt builders,
  `findSonnetModelId` (match/name/no-match/empty/case-insensitive),
  FakeAgentBackend recording (start/send/cancel sequence, failure, model hints).
- `Sources/WikiFSCore/WikiOperation.swift`: `sourceID(fromPath:)` → `public`.
- `tools/promptgen/main.swift`: registered 3 new prompt entries.

**Not verified:** The full orchestration needs a live ACP agent for end-to-end
verification (integration-level). The FakeAgentBackend infrastructure is provided
for future integration tests that drive the launcher end-to-end.

## Verification

Historical verification remains in the progress record above.
