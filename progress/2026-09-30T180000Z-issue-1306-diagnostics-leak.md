---
timestamp: 2026-09-30T180000Z
title: Docling test-failure message scoped to Docling routes in diagnostics
branch: bugfix/issue-1306-docling-diagnostics-leak
status: complete
---

# Docling test-failure message scoped to Docling routes in diagnostics

## Progress

Copy Diagnostics no longer leaks the Docling Test Connection failure
message into other routes' reports (issue #1306).

- `recoveryPresentation(for:)` builds `ExtractorRouteRecoveryFacts` from
  the view-global `doclingTest` state and feeds the same facts to every
  route. `ExtractorRouteRecoveryPresenter.report(...)` then read
  `facts.connectionFailureMessage` for every route, so a failed Docling
  test outranked a package route's own setup reason on the `Failure:`
  line.
- `report(...)` now gates the connection message on the same `isDocling`
  identity check that already gates `doclingEndpointOrigin`,
  `doclingTimeoutMilliseconds`, and `connectionTest`. A non-Docling route
  falls through to its own `status.setupFailureMessage`. A retained
  activation failure (`failure?.message`) still wins on every route.
- Visible UI is unchanged. The copied-diagnostics payload is the only
  behavior change.
- Known divergence, accepted: `present()` derives `isDocling` from the
  saved selection's role; `report()` derives it from logical identity. A
  legacy `.doclingServe` backend reference can therefore show status
  `.doclingConnectionFailed` while the report nil-gates the connection
  fields. This divergence predates the fix (`connectionTest` has the
  same gate), and the `Failure:` line falls back to the accurate generic
  copy ("The Docling connection test failed.").

## Verification

- New regression test `connectionFailureMessageStaysScopedToDoclingRoutes`
  in `ExtractorRouteRecoveryPresenterTests`
  (`Tests/WikiFSAppTests/ExtractionRouteTableHostedTests.swift`). It
  covers three scenarios: a generic package route must show its own
  setup reason and no Docling canary; a Docling route must still surface
  the detailed connection message; a retained activation failure must
  outrank the connection message.
- Mutation check: with the fix stashed, the test fails on exactly the
  leak (the canary appears; the route's own reason is missing). With the
  fix, the suite passes.
- `make test` passes (default SwiftPM graph).
- `WIKIFS_APP_TESTS=1 swift test --filter ExtractorRouteRecoveryPresenterTests`
  passes. This run is required: `WikiFSAppTests` is an opt-in target that
  plain `swift test --filter` and `make test` do not include.
