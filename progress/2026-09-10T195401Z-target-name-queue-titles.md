---
timestamp: 2026-09-10T195401Z
title: Target-name queue job titles
branch: feature/integrated-queue-workspace
status: complete
---

# Target-name queue job titles

Date: 2026-09-10. Branch: `feature/integrated-queue-workspace`.

## Problem

Queue job titles used only a target count. A single-source job displayed
`1 source`, which did not identify the source. The selected-job metadata also
omitted the wiki name.

## Progress

The navigator and selected-job header now use one title rule. A single-target
job uses the page or source name. A batch uses the first payload target name,
followed by `and 1 other` or `and N others`. A whole-wiki job uses the wiki name.

Payload order determines the first target. If that target name is unavailable,
the title uses a count instead of a later target or a raw ID. The existing
closed-wiki name index supplies recorded and read-only names.

A separate operation chip identifies ingestion, extraction, or lint. The
selected-job metadata now shows the wiki name before the typed queue item ID,
lifecycle state, and elapsed time.

The conceptual-audit cleanup removed the unused planned-status presentation
factory. Planned and not-reported target rows continue to use a nil status. Run
Details now keeps the queue item ID typed until it builds the visible row.

The plan and user guide now describe durable output snapshots, Open Source
actions, name-only evidence-free rows, operation chips, and target-name titles.

## Test verdict

One test expected the legacy fallback title `Lint 2 pages`. The operation chip
now supplies `Lint`, so the shared title correctly uses `2 pages`. The test was
wrong and now asserts the final title contract.

## Verification

- Changed-file language-server diagnostics passed.
- The opt-in queue application suites compiled and ran with the new title and
  typed-ID fixtures.
- `QueueWorkspaceIntegrationTests`, `QueueClosedWikiNameResolutionTests`, and
  `QueueWorkspacePresentationTests` passed in the combined opt-in run.
- `make build` built and signed the application.
- `swift test --no-parallel` passed 4,288 tests in 465 suites.
- `git diff --check` passed.

The hosted Overview suite process exited zero after it started its second test,
but it did not print a suite completion line. This record does not count that
command as a complete hosted-suite pass.

Two standard `make test` runs each found one unrelated extractor startup
timeout under full-suite load. The failures occurred in different tests after
10.8 and 10.9 seconds against a 10-second limit. Each test passed alone in 1.29
seconds. The complete serial run passed.
