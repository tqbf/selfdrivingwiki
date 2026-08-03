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

The corrective exact-head work for PR #1015 makes the chat inspector hydrate
the existing typed `ChatUsageSummary`. Updated and message-count rows remain
in Summary; the live-replaced `ChatTurnID` is shown under **Latest turn**, and
durable aggregate counters and matching-currency cost are shown only under
**Persisted conversation totals**. The aggregate is never combined with the
live overlay. Direct projection tests pin that distinction and the two summary
rows. The cross-process test now mounts a real chat metadata task keyed by
`MetadataHydrationKey.chat(..., messageVersion)`, makes a committed chat
message write, observes the event-bus-driven `messageVersion` advance, and
observes the keyed hydration task run again. Hosted tests now mount real
`NSWindow` controls and assert picker segment order plus its exact accessibility
label contract, rendered row values and hint contract, selectable monospaced
identifiers, wrapped values, keyboard activation, and renderer source I/O
exclusion.

## Verification

- `make build` — passed (exit 0).
- `swift build` — passed (exit 0).
- `make test` — passed (exit 0): 2,949 tests in 240 suites.
- `swift test` — passed (exit 0): 2,949 tests in 240 suites.
- `WIKIFS_APP_TESTS=1 swift test` with the Phase 5 suites plus Phase 1–4
  metadata regressions — passed (exit 0): 268 tests in 25 suites.
- `git diff --check` — passed (exit 0) before the final documentation edit;
  rerun in the exact-head audit.

## Corrective exact-head verification

- `make build` — passed (exit 0).
- `swift build` — passed (exit 0).
- `make test` — passed (exit 0): 2,949 tests in 240 suites.
- `swift test` — passed (exit 0): 2,949 tests in 240 suites.
- `WIKIFS_APP_TESTS=1 swift test` across all Phase 1–5 metadata, provenance,
  extraction, hydration, hosted inspector, and regression suites — passed
  (exit 0): 338 tests in 31 suites.
- Focused corrected coverage (`ChatMetadataProjectionTests`,
  `ChatMetadataMergeTests`, `MetadataCrossProcessRefreshTests`, and
  `MetadataPanelHostedTests`) — passed (exit 0).
- Typed page/source namespace, inspector no-store-I/O, metadata event-emission,
  and public-mutator emission-exhaustiveness audits — passed (exit 0): 7 tests
  in 4 suites.
- `git diff --check`; renderer-I/O, lifecycle-writer, cancellation, typed-ID,
  event, and changed-scope shell audits — passed (exit 0). The changed scope
  contains no deletion UI or issue #219 navigation.
