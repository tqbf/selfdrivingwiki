---
timestamp: 2026-10-02T172500Z
title: Wiki strategy verification
branch: feature/wiki-strategies-cumulative-ingestion
status: active
---

# Wiki strategy verification

## Progress

The feature is not release-ready. Work remains on `feature/wiki-strategies-cumulative-ingestion`.

Strategy timestamps now use the same epoch conversion as stored timestamps, so returned and re-read values compare equal. Prompt test paths use `#filePath`, not `#file`. Create-only writes reject an explicit page ID before reporting title collisions. Identical same-author writes skip the amendment path and emit no content event. The evaluator checks each superseded claim within its sentence rather than allowing an earlier qualifier to authorize a later repeated claim.

## Verification

Strategy persistence and prompt contract recheck: 51 tests in 5 suites passed. The suites include `WikiStrategyStoreTests`, `CumulativeIngestContractTests`, `AgentPromptContractTests`, `GeneratedPromptsParityTests`, and `PromptResourceSyncTests`.

Atomic write recheck: 51 tests in 3 suites passed. `PageUpsertAtomicityTests`, `PageVersionSourceWriterTests`, and `AgentCASTests` passed. This includes real SQLite trigger rollback, two-connection CAS, and event assertions.

`WikiStrategyEvaluationHarnessTests` passed in the atomic/evaluator recheck. The combined run still failed on two atomic cases. A later atomic recheck resolved those cases. `WikiStrategyRendererTests` passed in the initial targeted run. Prompt resources were synchronized with `make prompts`.

All six `CumulativeIngestPipelineTests` passed after fixtures used real imported source IDs and the scripted CLI preserved production conflict exit codes. `WikiStrategyProjectionTests` passed, including mounted content, token changes, and write rejection.

The initial app-target run failed with 228 issues. Later capture and projection checks passed all 16 tests across two suites.
The hosted editor test now stops at its first failed control lookup, without cascading issues.
Its real name field and instructions view render, but the accessibility tree does not expose the Save button.
Activation, controller hosting, and post-load layout did not fix discovery. Hosted editor workflows remain unverified.

`make test` and bare `swift test` passed after the checkpoint received its required documentation headings.
Bare `swift build` passed after `make version prompts`. These gates preceded the latest evaluator changes and must run again.
The live budget callback tests passed all 12 evaluator-harness tests.

### Live evaluation evidence

The configured Codex backend ran all three scenarios. Artifacts are in `tmp/wiki-strategy-eval/2026-10-02T232813Z`.
The original reports contain four character failures, nine repository failures, and one documentation failure.
These verdicts mix evaluator defects with model output and are not reliable final classifications.
Source filename checks did not match imported source identities. The recorder also selected the oldest version instead of the current version.
The repository fixture expected a title it did not require. The character fixture incorrectly classified current framing as superseded.

The final Mara page preserves the earlier accusation as history and cites the later correction.
Database inspection confirms that its latest version records Chapter 7 only, despite retaining Chapter 3 claims and citations.
That missing supporting provenance is a real failure. The evaluator must preserve this check after its identity corrections.
The shared write prompt now explicitly requires supporting version inputs for retained claims. Source and resource copies are synchronized.

On operator approval, `general-purpose:glm-eval-integration` uses `zai/glm-5.3` to finish evaluator wiring and regression tests.
`general-purpose:glm-editor-harness` investigates real-control hosted UI validation without replacing production controls.
The corrected live character scenario passed at `tmp/wiki-strategy-eval/2026-10-02T235350Z`.
The corrected documentation scenario passed at `tmp/wiki-strategy-eval/2026-10-03T002006Z`.
The repository scenario passed identity, links, provenance, and history checks but failed the old historical-section heuristic.
GLM corrected that heuristic with positive footnote/history tests and a negative current-section boundary test. All 37 targeted tests passed.
No corrected post-hoc live report or human rubric verdict exists yet.

The latest hosted editor run executed all six tests and failed with 13 issues. Save and light/dark scenarios passed.
Confirmation and template workflows remain incomplete. A template-menu experiment terminated the host before suite completion.
That exit-zero truncated run is not a pass. The current harness fails that interaction explicitly.

Final `make test` passed on retry. Bare `swift build` passed. Two later bare test runs failed for different reasons.
A crash report confirms an uncatchable guarded-descriptor close violation. A separate run failed the process-group backstop count assertion.
GLM found one definite double-close error path and a shared-registry test race. Neither establishes the cause of the guarded-descriptor crash.
`general-purpose:glm-gate-isolation` owns the narrow double-close fix and shared test isolation. Full gates must run after these changes.

Human rubric decisions, independent review, phase commits, and the PR remain outstanding.
Scripted results do not establish model obedience. No merge, automatic merge, or queue action is authorized.
