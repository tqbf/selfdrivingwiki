---
timestamp: 2026-09-11T035349Z
title: Queue list rows drop all time text
branch: feature/queue-rows-no-time-text
status: complete
---

# Queue list rows drop all time text

## Progress

The Activity window job rows showed time text in three places. Running rows
ticked "running · 42s elapsed" in the metadata line. Running usage rows
appended "· 42s elapsed" to the live token line. Finished rows showed a
relative "2 min. ago" suffix. The operator asked to remove the duration from
the queue list items, and then asked to remove the relative time as well.

Rows now show only the job ID in the metadata line. Running rows append the
state word "running". The two per-second `TimelineView` wrappers existed only
for the ticking elapsed text, so they are gone. Rows now re-render on queue
events only. Run Details and the selected-job header clock still show start,
finish, and duration. The `elapsedString` and `relativeTime(for:)` helpers and
the `RowDisplayData.relativeTime` field became dead code and were deleted.

## Verification

- `make build` passed.
- `WIKIFS_APP_TESTS=1 swift test --filter QueueWorkspacePresentation` passed
  (31 tests).
- `WIKIFS_APP_TESTS=1 swift test --filter
  "ActivityWindow|QueueWorkspaceIntegration|QueueClosedWikiName"` passed
  (86 tests in 4 suites).
