---
timestamp: 2026-09-10T061500Z
title: Durable queue output snapshots
branch: feature/integrated-queue-workspace
status: complete
---

# Durable queue output snapshots

Date: 2026-09-10. Branch: `feature/integrated-queue-workspace`.

## Problem

The Agent Queue loaded ingestion outputs from the selected wiki store. The load
failed when the wiki had no open session. Historical job details therefore
depended on mutable wiki state and window state.

## Progress

`QueueAttemptReport` now owns an optional output snapshot. Each
`QueueRecordedOutputPage` contains a typed `PageID` and the title recorded at
completion.

QueueStore migration v9 adds `queue_attempt_report_outputs`. It also adds the
`outputs_recorded` header field. This field distinguishes two states:

- `nil` means that the attempt did not record a snapshot.
- An empty array means that the snapshot completed and found no pages.

A report mutation can replace the full snapshot. Other mutations preserve it.
A new execution of the same attempt resets it. Retry isolation and item-delete
cascades match the existing report rules.

Both ingestion hosts query `pagesCitingSources` after agent validation. The app
runs the query after its workspace merge callback completes. A query failure is
logged and leaves the snapshot absent. It does not change a successful job
result.

The Overview reads outputs from the loaded attempt report. It no longer queries
the selected wiki store. An open wiki can still supply a newer title and an Open
Page action, but it does not supply output identity.

## Compatibility

Reports created before migration v9 have no output snapshot. The Overview shows
“Outputs were not recorded for this job.” It does not show a false zero.

The snapshot keeps the existing 200-row bound. A full snapshot displays `200+`
to avoid showing the bound as an exact total.

## Verification

- Focused report and app mapping suites passed 43 tests.
- `make build` built and signed the app.
- `make test` passed 4,288 tests in 465 suites.
- The independent SwiftUI review found no issues.
- Changed-file LSP diagnostics were clean. The workspace diagnostic request
  timed out, but the SwiftPM build and test compilers passed.

The known SwiftPM warning about 12 extractor fixture files remains unrelated.
