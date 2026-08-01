---
timestamp: 2026-08-01T004700Z
title: Issue #1005 Phase 5 inspector metadata
branch: issue-1005-phase-5-inspector-metadata
status: complete
---

# Issue #1005 Phase 5 inspector metadata

## Progress

The inspector has an ordered metadata-first tab contract. Page, source, and
persisted-chat detail owners register ordered tab lists, normalize a persisted
selection asynchronously, and hydrate immutable metadata models through the
read pool when one is available.

The shared `MetadataPanelView` renders metadata state only. Its rows use typed
subjects, fields, links, and actions. `MetadataActionRouter` keeps navigation,
clipboard, comparison, and URL-opening side effects outside the Sendable
presentation model. The inspector remains constrained to 180 through 500
points and switches to stacked rows below the named 300-point metric.

The shared panel has hosted `NSWindow` layout coverage at 180, 299, 300, and
500 points, establishing `MetadataMetrics.stackedRowThreshold == 300`.
Page/source/chat projection, renderer, typed router, hydration, event-refresh,
live `ChatTurnID` overlay, accessibility, and outline/history regression tests
are present in the Phase 5 AC matrix. Issue #219 deletion UI and navigation
remain explicitly out of scope.

## Verification

- `make build` — passed (exit 0).
- `swift build` — passed (exit 0).
- `make test` — passed (exit 0): 2,949 tests in 240 suites.
- `swift test` — passed (exit 0): 2,949 tests in 240 suites.
- `WIKIFS_APP_TESTS=1 swift test` with the Phase 5 suites plus Phase 1–4
  metadata regressions — passed (exit 0): 268 tests in 25 suites.
- `git diff --check` — passed (exit 0) before the final documentation edit;
  rerun in the exact-head audit.
