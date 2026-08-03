---
timestamp: 2026-07-28T205000Z
title: Preserve ceiling-kill retry context
branch: ceiling-kill-retry-context
status: complete
---

# Preserve ceiling-kill retry context

## Progress

- Added a typed `ceiling-kill-context.json` debug artifact written before the
  watchdog cancels an ACP session, including pending command summaries and
  measured wait durations.
- Retries load the latest preceding artifact for their queue item and receive a
  bounded advisory in planner and executor prompts.
- Mirrored the same advisory into the Activity transcript after the terminal
  ceiling-failure event.

## Verification

- `swift build`
- `swift test --filter DebugRunLoggerTests`
