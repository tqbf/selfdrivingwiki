---
timestamp: 2026-10-05T212818Z
title: Plan-rejection reason reaches the queue, and the planner keeps strict job locality
branch: bugfix/issue-1370-plan-rejection-observability
status: in-review
---

# Plan-rejection reason reaches the queue, and the planner keeps strict job locality

## Progress

Issue #1370, job 01M4572543AX7SBK4KJ5Z71MA3. The planner wrote a 12-page plan.
Validation rejected it because one page named a supporting source from an
EARLIER batch:

```
plan page "101: …" names supporting source
"100-…--01M4509GR2B6FXDK5P0VNZ8EAJ.md", which is not one of the staged source files
```

The job then failed with only the generic message "Agent spawn failed: The
agent run aborted before completing (exit status -1)." The reason was invisible
to the user. Two defects, plus a prompt clarification.

**Defect 1 — the reason never reached the failure the queue reads.** The
rejection site in `AgentLauncher.runACPIngestPlannerExecutors` logged the
detail with `DebugLog.agent`, appended a `.result(isError: true, …)` event, and
called `finish(status: -1)`. The queue validator
(`QueueIngestionOutcomeValidator.validate`) reads `preflightError` FIRST and
`turnFailure` only to select the message, so a run with no `preflightError` and
no turn failure falls to the generic exit-status text. The rejection site never
set `preflightError`, so the detail died in the log.

The fix copies a COMPACT one-line reason into `preflightError` before
`finish(status: -1)`, mirroring the #1354 abort-point copy in
`runACPIngestFallback`. The new
`ACPIngestPlanValidation.failureSummary(_:)` names the FIRST problem verbatim
and appends " (+N more)" when other problems exist. The full multi-line detail
stays in the log and the transcript event. The routing is verified, not
assumed: `AppQueueIngestionProvider.runAgent` reads
`launcher.preflightError` and passes it to the validator after the run
returns.

**Defect 2 — the `.result` event never persisted to the queue transcript.**
`flushTranscript` logged `tail=1 kinds=["result": 1]`, yet
`queue_item_transcript_items` had no such row. The drop is in the translator,
not in the persistence filter: `AgentEvent.isPersistable` is `true` for
`.result`, but `AgentEventTranscriptTranslator.translate` returned `nil` for
`.result` in its catch-all arm, so the event never became a
`ChatTranscriptItem`. `QueueTranscriptStateStore.accept` reduces the
translator's deltas, finds nothing changed, and enqueues no batch — nothing to
persist and nothing to broadcast.

The translator now maps `.result` to its own assistant message. The mapping
honours the dedup rule that `plans/chat-and-persistence.md` already documents
for the continuation preamble: a result whose text repeats the turn's
assistant text adds no content and is skipped, while a STANDALONE result is
kept. The comparison is against the turn's last assistant text, not the open
content block — `.assistantText` closes the block it just wrote. The helper
leaves the block closed, because a result is terminal
(`AgentEvent.endsGeneration`); the next turn's assistant text must start its
own block instead of replacing the result text. An empty result text produces
no row.

**Locality — the operator kept strict job locality.** An already-ingested
source from an earlier batch stays INADMISSIBLE as a supporting source, and the
primary `sourceFile` stays job-local. The validator's strictness is unchanged.
`prompts/ingest-planner.md` now states the rule AT the `supportingSources`
schema field, names the cross-batch failure mode explicitly, and states the
consequence: validation rejects the WHOLE plan, so no executor runs and one
cross-batch citation wastes the entire job. Earlier material is reached with a
`[[wiki link]]` to the existing page instead.

## Verification

- `make build` passed (app built and signed).
- `make test` passed (full default SwiftPM suite, exit 0).
- New tests:
  - `AgentEventTranscriptTranslatorTests` — `resultMatchingOpenAssistantBlockProducesNoDelta`,
    `standaloneResultBecomesPersistableAssistantMessage`,
    `resultClosesBlockSoNextTurnStartsFresh`, `emptyResultProducesNoDelta`.
    `ignoredEventsProduceNoDelta` no longer includes `.result` in its
    dropped-event list, because `.result` is no longer dropped.
  - `QueueWorkerOutputChannelTests` — `standalone result persists to the queue
    transcript` pins that a `.result` reaches `persistTranscript` as one
    message item, the persistence the incident showed missing.
  - `CumulativeIngestContractTests` — `rejectionSummaryNamesFirstProblemOnly`,
    `rejectionSummaryOmitsCounterForSingleProblem`,
    `rejectionSummaryIsNilWithoutProblems`.
  - `ACPIngestPlanTests` — `planValidationFailureRejectsPlanBeforeExecutorLaunch`
    extended to assert the `preflightError` copy;
    `planValidationFailureSummarizesMultipleProblems` pins the "(+1 more)"
    form end-to-end through a real launcher run.
  - `AgentPromptContractTests` — `plannerSupportingSourcesAreJobLocal` pins the
    strengthened rule in BOTH the canonical prompt and the bundled copy.
- The strengthened prompt was synced with `make prompts`; both copies are
  committed together.
- The operator should rebuild and reinstall the app so the running daemon picks
  up the fix.
