# Chat presentation Phase 5: keyed renderer

Date: 2026-07-30

## Result

The app chat transcript now uses a keyed render plan and an acknowledged WebKit command executor.

`ChatTranscriptRenderPlanner` compares typed display rows by durable row ID.
It returns reload, append, insert, replace, remove, or no command.
It reloads for transcript, style, reset, duplicate-ID, reorder, and equal-count identity changes.

`ChatTranscriptRenderExecutor` runs on the main actor.
It allows one DOM mutation at a time.
It advances its acknowledged snapshot only after a matching successful acknowledgement.
It coalesces repeated updates for one row through the latest desired snapshot.
A failed patch schedules one reload from that snapshot.

The WebKit shell now keeps transcript rows in one named root.
DOM commands target `data-row-id` values only.
Commands return kind, revision, row ID, and outcome.
The shell keeps focus, selection offsets, and a scroll anchor during replacements and controlled reloads.

## Validation

- `make build` passed.
- `make test` passed with 2,712 Swift Testing tests.
- Focused planner and executor tests passed with app tests enabled.
- Focused hosted WebKit tests passed with app tests enabled.
- The hosted tests passed while a SwiftUI runtime-issues log stream was active.
- `log show` found no matching update-cycle warning for the focused hosted run.
- `WIKIFS_APP_TESTS=1 swift test` stalled in the aggregate hosted suite after about three minutes.
- The stalled helpers ran from this worktree and were terminated.

## Scope

This change is Phase 5 only.
It does not change other planned phases or the documentation index.
