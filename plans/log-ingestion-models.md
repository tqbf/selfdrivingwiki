# Plan: log resolved provider/models/thinking at ingestion start

## Goal

When an ingestion run starts, write a structured JSON record of the resolved
**provider**, **model(s)**, and **thinking effort** into the run's directory on
disk, so a run's model configuration can be inspected post-hoc (debugging "what
model did this run use", audits, and later verifying per-phase model selection).

## Verified insertion points (file:line)

- The per-run dir is
  `<Caches>/Self Driving Wiki-agent/<chatULID>/runs/<timestamp>/` (the `scratch`
  dir). See `Sources/WikiFSEngine/AgentLauncher.swift:294-299` (run-dir
  resolution) and `:3087-3092` (where `run.jsonl` + `run.stderr.log` are created
  under `scratch`).
- `Sources/WikiFSEngine/DebugRunLogger.swift` is the dedicated run-artifact
  writer (its own comment says the lightweight `run.jsonl`/`run.stderr.log` are
  *not* touched by it — those are siblings). This is the natural home for the
  new file (a new lightweight sibling artifact, not part of the verbose
  `debug/` trace).
- Data available at ingest start:
  - provider id (`runProviderLabel = provider.id`, `AgentLauncher.swift:1175`)
  - `provider.label` (`AgentProvider.label`, `Sources/WikiFSCore/Core/AgentProvider.swift:25`)
  - the selectedModelId (`providersConfig().selectedModelId(forProvider:)`,
    `AgentLauncher.swift:481-482`)
  - thinking effort (`ThinkingEffortOption`, declared in
    `Sources/WikiFSEngine/ThinkingEffortOption.swift`; the current
    `self.thinkingOption` value on the launcher).
- The `DebugRunLogger` instance is built INSIDE `ACPBackend.startProcess`
  (`ACPBackend.swift:339`) — AFTER `openLogFiles` runs. So the new write is a
  **static** helper on `DebugRunLogger` (no instance needed), invoked from
  `AgentLauncher.run()` immediately after `openLogFiles(in: scratch)`.

## Fix

1. **Add to `DebugRunLogger`** (in `Sources/WikiFSEngine/DebugRunLogger.swift`):
   - A `Codable, Sendable` record type `ModelsConfigRecord` describing the JSON
     shape, with comment explaining the forward-compatible `phases` array.
   - A pure `static func makeRecord(...)` helper that builds a
     `ModelsConfigRecord` from the data available at spawn time (provider id +
     label, selectedModelId, `ThinkingEffortOption?`, chatULID, startedAt,
     operationKind, sourceFiles, sourceIDs).
   - A `static func writeModelsConfig(_:to:)` that writes the record as
     pretty-printed JSON to `<scratch>/models.json`, best-effort (failures
     logged via `DebugLog`, never thrown — house rule: **no bare `try?`**).
2. **Call the write ONCE at ingestion start**, right after `openLogFiles(in:
   scratch)` in `AgentLauncher.run()` (line ~1176). The `queueItemID` parameter
   serves as the chatULID (it's what `makeScratchDirectory(id:)` uses to build
   the `<Caches>/.../<id>/runs/<timestamp>/` path). For `.ingest` operations,
   `sourceFiles`/`sourceIDs` come from the staged `WikiOperation.ingest`'s
   `sourcePaths` (`WikiOperation.sourceID(fromPath:)` derives the id). For
   non-ingest kinds, `sourceFiles`/`sourceIDs` are `[]`.
3. Do **not** modify `run.jsonl` or `run.stderr.log` behavior — `models.json`
   is a sibling file in `scratch/`, not in `debug/`.

## JSON shape (forward-compatible)

```json
{
  "schemaVersion": 1,
  "chatULID": "<queueItemID>",
  "startedAt": "2026-07-19T12:34:56.789Z",
  "operationKind": "ingest",
  "provider": { "id": "claude", "label": "Claude" },
  "selectedModelId": "claude-sonnet-4-5",
  "thinkingEffort": {
    "configId": "thought_level",
    "currentValue": "high",
    "choices": [
      { "value": "high", "label": "High" },
      { "value": "medium", "label": "Medium" }
    ]
  },
  "sourceFiles": ["sources/by-id/01HXY...md"],
  "sourceIDs": ["01HXY..."],
  "phases": []
}
```

`phases` is `[]` today. Forward-compat intent: when per-phase model selection
lands (planner/executor/finalizer), each phase gets an entry
`{name, provider?, selectedModelId?, thinkingEffort?}` appended to `phases`
without rewriting the schema. Readers MUST treat an absent/empty `phases` as
"the top-level triple applies to every phase" and a non-empty entry as an
override for that phase only.

## Acceptance

- `swift build` clean; `swift test` (full suite) green — no regressions.
- Starting an ingestion writes `<run-dir>/models.json` with
  provider/model/thinking. (Headless: verified by code + a focused unit test.
  The operator confirms a real run writes the file.)
- Focused unit test added in Swift Testing, asserting the JSON shape (including
  the forward-compatible structure).

## Workflow

1. First commit: this plan in `plans/log-ingestion-models.md`.
2. Implement.
3. `swift build` + `swift test`.
4. Push branch, open a PR. Do NOT merge to `main`.
