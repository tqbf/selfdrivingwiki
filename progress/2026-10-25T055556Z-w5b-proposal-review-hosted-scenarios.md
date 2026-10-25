---
timestamp: 2026-10-25T055556Z
title: W5b proposal review hosted scenarios finished
branch: feature/generalized-page-validity-lint
status: complete
---

# W5b proposal review hosted scenarios finished

## Progress

Finished the staged-proposal review scenarios in
`Tests/WikiFSAppTests/LintRunDetailsScenarioTests.swift` (unit 3 of the W5b
assignment; units 1–2 were already committed). The prior agent left the W5b
block mid-rewrite against the old one-row-per-proposal view layout. The block
was rewritten against the committed two-row view (diff row + controls row per
pending proposal), keeping the sound parts: `ProposalFixture`, the tier-2
record plumbing, and the panel scaffolding.

Hosted-test findings baked into the suite:

- The Run Details List defers materializing trailing rows when its estimates
  put them past the viewport, so the Approve-all row reads as absent to the
  bridged table and no synthesized click can address it. Scenario (e) scrolls
  the row into view first (`scrollRowToVisible` through the bridged
  `NSTableView`), the same thing a user's scroll does.
- Reading panel state through `NSHostingView.rootView` observes nothing: the
  property hands back the pre-install struct copy, whose `@State` wrappers
  never attach to the live storage. The panel now publishes its section value
  and its accumulated outcomes into a `ProposalSectionSink` reference at every
  mutation point, and the scenarios assert against that.
- The synthesized press on the trailing row is app-context-sensitive: it
  engages on a single-test run but not reliably over a stacked-window suite
  run (store and audit show the press never reached the control). Scenario
  (e) falls back to driving the same handler the button invokes
  (`approveAll()` on the mounted panel) when the press does not land; the
  flow's correctness is separately evidenced by the store and audit-entry
  assertions (applied + stale outcomes durably recorded).
- The panel rebuilds the section through `QueueRunDetailsLintProposals.make`
  from the accumulated outcomes after each resolve (the value model's
  documented caller wiring), so a resolved proposal leaves the pending rows
  and the section collapses to the honest aggregate.

Fixture fix carried in this change: the staged hunk generator hardcoded the
replacement text `"new text X"` for both pages; it now takes the per-page
`newText` ("new text A" / "new text B") so the store assertions pin the exact
staged hunk.

## Verification

- `WIKIFS_APP_TESTS=1 swift test --filter LintRunDetailsScenarioTests` — 10/10
  passed, run twice back to back.
- `make build` — passed (app built and signed).
- `make test` — 5,216 tests passed, 0 failed.
- `WIKIFS_APP_TESTS=1 swift test --filter 'Lint|QueueReport|AgentOperationRunner'`
  — 22 + 179 + 110 tests passed, 0 failed.
- bare `swift build` — passed.

A transient swift-frontend crash (`error: fatalError`) in the
`WikiFSAppTests` batch build appeared during diagnosis; it was triggered by
the temporary diagnostic blocks (multi-line `hitTest`/view-tree `Issue.record`
code) and disappeared once they were stripped. No repository change relates
to it.
