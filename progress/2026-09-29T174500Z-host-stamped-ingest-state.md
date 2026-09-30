---
timestamp: 2026-09-29T174500Z
title: Host-stamped ingest state for pipeline ingests
branch: feature/host-stamped-ingest-state
status: complete
---

# Host-stamped ingest state for pipeline ingests

## Progress

A completed pipeline ingestion job now marks its staged sources Ingested.
The host writes `sources.ingested_at` after the agent run passes its validate
gate. The agent no longer runs the `wikictl log append --source` ritual for
pipeline ingests (issue #1344).

- Both hosts stamp at the same seam. `AppQueueIngestionProvider.runIngestion`
  and `DaemonQueueIngestionProvider.runIngestion` stamp immediately after
  their throwing validate gates. A failed or cancelled job marks nothing,
  because the stamp site sits after the gate.
- `QueueIngestionReporting.stampableSourceIDs(requested:)` picks the stamp
  list. Only sources whose staging outcome was `.staged` are stamped.
  Sources with outcome `.bytesUnavailable` stay unmarked, so a retry stays
  honest.
- `markSourceIngested` keeps the first stamp. The UPDATE runs only where
  `ingested_at IS NULL`. A host re-drain, or a late agent ritual stamp,
  cannot rewrite the timestamp.
- The four task prompts (`ingest-single-task`, `ingest-curator-task`,
  `ingest-finalizer`, `ingest-planner`) no longer mention `--source`. The
  ids stay listed, because page writes cite them. The chat system prompt
  keeps the ad-hoc `--source` path and the #1343 guards.
- The daemon posts one Darwin change notification after the stamps, so
  attached apps reload the new state.

Design decisions:

- The stamp lives in the provider tails, not in `QueueEngine`. The engine
  holds no per-wiki `WikiStore` and stays lane-agnostic. Both providers
  already hold the store and the staging facts at the validate gate.
- The queue report truth rules stay unchanged. Report targets stay
  `.submitted`. The stamp is a job-level state transition, separate from the
  report.

## Verification

- `make build` clean and signed.
- New tests pass: `stampableSourceIDsCoverExactlyStagedSources`,
  `markSourceIngestedKeepsFirstTimestamp`,
  `stampIngestedSourcesStampsOnlyStagedSources`,
  `modelStampMarksSourceIngested`, `pipelineIngestPromptsDropTheSourceRitual`,
  `chatPromptKeepsAdHocSourcePath`.
- Full `make test`: green apart from one unrelated timing flake
  (`ProcessExtractorProviderTests.runtimeResolutionOccursOncePerPreparedOperation`,
  a 10 s extractor limit exceeded under parallel load). That suite passes
  standalone.
- Known gap: no direct unit test proves a failed job stamps nothing. The
  provider tails need a full launcher stack, and `wikid` is an executable
  target. The stamp sites sit strictly after the throwing validate gates,
  beside the existing validate-throw tests.
- Pre-existing failures in the opt-in `WIKIFS_APP_TESTS=1` target:
  `SourcesTests.extAndMimeDerivedFromFilename` and
  `SourcesTests.mimeExplicitParamOverridesSniff` fail on `main` too. Verified
  with the branch changes stashed. This target is outside the default test
  graph and outside CI.
