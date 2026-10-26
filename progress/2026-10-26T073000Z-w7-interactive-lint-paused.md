---
timestamp: 2026-10-26T073000Z
title: "W7 interactive lint — paused at checkpoint; continuation notes for a fresh branch"
branch: feature/generalized-page-validity-lint
status: paused-wip
---

# W7 interactive lint — paused at checkpoint

## Progress

The operator redesigned lint as an interactive, single-flight, modal flow
and paused the build after the Opus session limit interrupted it. This
branch is the REFERENCE for a continuation on a fresh branch.

- `feat(lint): interactive lint service checkpoint (W7 paused)` —
  `Sources/WikiFS/Lint/InteractiveLintService.swift` (644 lines: the
  single-flight foreground service) plus activity-window wiring and
  per-finding fix-state integration. Compiles clean; full test suite
  NOT verified at capture (operator deferred verification).
- `docs(lint): preserve the interactive lint contract (W7 paused)` —
  the full W7 contract preserved at
  `plans/interactive-lint-w7-paused.md`.

## What remains for the continuation

1. Verify/complete `InteractiveLintService` (single-flight FSM
   `idle → running(page) → presenting(result) → idle`, foreground
   execution through the W6 per-finding precedent path, cancellation).
2. The modal results sheet: findings present → rows with Fix / Edit
   Manually (reuse the W6 per-finding machinery); none → clean bill of
   health; report-only honesty line. Rows update live as fixes
   verify/revert.
3. The Lint entry point in the page context (natural home; enabled only
   when idle).
4. Remove the user-facing queued-lint entry points (the W2b/W5b/W5c
   Run Details sections STAY — they render history).
5. Tests: service FSM + hosted dialog scenarios (own-row controls,
   `.serialized` + `.timeLimit`), per the contract's test section.
6. Whole-wiki lint is out of scope (stays as-is).

## Context pointers

- Design contract: `plans/interactive-lint-w7-paused.md`.
- The amended trust ladder + per-finding repair tier:
  `plans/generalized-page-validity-lint-implementation.md`.
- Foreground execution precedent: the W6 per-finding flow
  (`AgentOperationRunner.makePerFindingRepairPlan`,
  `LintAuthorityTier.perFindingRepair`, policy
  `.lintPerFindingRepair(pageID:)`).
- The interactive lint service is a DETECTION pass (report-only policy
  is correct for it); fixes happen per-finding afterward via the W6
  flow with the full enforcement net.
- Repo SwiftUI rules apply: no state writes during view update (defer
  via `Task { @MainActor in … }`); controls in their own List row
  (buttons-in-one-row do not bridge to AppKit — see
  `progress/2026-10-25T055556Z-w5b-proposal-review-hosted-scenarios.md`).

## Verification

- `swift build` clean on the checkpoint (12.8 s incremental).
- Full test suite intentionally NOT re-run at capture (operator
  deferred); the continuation must run all four gates before reporting:
  `make build`, `make test`,
  `WIKIFS_APP_TESTS=1 swift test --filter 'Lint|QueueReport|AgentOperationRunner'`,
  bare `swift build`.
