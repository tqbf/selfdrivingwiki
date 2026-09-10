---
timestamp: 2026-09-08T031900Z
title: Integrated queue workspace design documentation
branch: feature/integrated-queue-workspace
status: implementation-underway
---

# Integrated queue workspace design documentation

## Progress

Wrote the repository design record for the approved Integrated Queue
Workspace plan (issues #1219, #1220, #1221). Documentation only. No code
changed.

- Added `plans/integrated-queue-workspace.md`. It records the layout contract
  for both queue windows, the state vocabulary (job lifecycle, target states,
  per-operation language), the report truth rules, Pause versus Stop All
  semantics, whole-job retry, and the history and search scope. It states that
  implementation is underway and that tests have not run. The screenshots
  section is explicitly empty until the named manual review runs.
- Added the feature index entry for that plan to `PLAN.md`, beside the typed
  queue transcripts entry.

A prior documentation delegate was cancelled before writing any files. No
partial work existed to preserve. This entry is its replacement.

Decision: lifecycle vocabulary in the design doc uses the real
`QueueItemState` and `QueueRunState` cases from
`Sources/WikiFSCore/Core/QueueTypes.swift`, so the document and the code use
one set of names.

Out of scope for this entry: user-facing queue guidance in `docs/user-guide/`
(search scope, Pause versus Stop All, retry, Overview versus Activity, Not
Reported) is a pending documentation task for the implementation delegate.

## Verification

No commands, tests, or builds ran for this task. The work is three
documentation writes through file tools. No commit or push happened. The
implementation delegate owns commits on `feature/integrated-queue-workspace`.

Feature verification status: implementation is underway. Tests have not run.
Nothing in this entry claims a passing build, a passing suite, or a completed
manual review.
