---
timestamp: 2026-10-04T050500Z
title: Independent review findings, F1 fix and F4 verification
branch: feature/wiki-strategies-cumulative-ingestion
status: partial
---

# Independent review findings: F1 fix and F4 verification

## Progress

This entry records work on the findings of the independent review at
`tmp/claude-strategy-independent-review.md`. The review examined SHA
`d520923e073568b4890c534af7ea50a2a052cfdb`. The follow-on evidence commit is
`8c614a30`.

Claude Opus 4.6 wrote the review. That model family wrote neither the
approved plan (OpenAI models) nor the implementation (`zai/glm-5.3`, with
operator approval). The reviewer ran zero builds and zero tests. The review
reported no high-severity findings, no critical findings, and no merge
blockers.

The operator now requires fixes for findings F2 and F3, not only acceptance
records. Other delegates own that work. This entry does not close F2 or F3
and does not close the review.

## F1: reset-path timestamp normalization (fixed)

The save path normalized its timestamp through a Unix-epoch round-trip. The
reset path used a bare `Date()`. The review flagged this difference at
`GRDBWikiStore.swift`.

The reset outcome returns `strategy: nil`. No public read returns the
tombstone `updated_at` value. The difference therefore had no observable
effect. The fix is a representation-consistency change, not a behavior fix.

The fix applies the same epoch round-trip to the reset path in
`saveWikiStrategy`. Both write paths now construct the timestamp the same
way. A comment at the site states the reason.

No new test was added. A precision test would assert a value that no public
API returns. The existing `roundTripAndIsolation` test covers the save path,
where the returned strategy carries the timestamp.

Targeted gate: `swift test --filter WikiStrategyStoreTests`. Result: 7 tests
in 1 suite passed, exit code 0.

## F4: issue #1354 fix on main (verified, one detail corrected)

The review stated that commits `5d820594` and `70eaa89b` fix issue #1354 on
main. Read-only git and GitHub evidence gives this result:

- Both commits exist locally on branch
  `bugfix/ingest-launch-failure-completion`.
- Neither commit is an ancestor of `origin/main`. GitHub squash-merged pull
  request #1355, so those branch commits never landed on main as themselves.
- Pull request #1355 is MERGED. Its merge commit is `afb692d9`, the current
  `origin/main` tip in local refs. The commit message names issue #1354.
- Issue #1354 is CLOSED as COMPLETED at 2026-10-04T04:41:22Z.

The review conclusion is supported: the fix is on main. The cited commit SHAs
were imprecise. They are the pull-request branch commits, not main commits.

This task made no rebase, merge, cherry-pick, or issue state change. The
branch picks the fix up at its next rebase or merge, which the operator owns.

## F2 and F3: owned by other delegates

The operator accepted the template menu workflow and the semantic evaluation
(`progress/2026-10-04T045018Z-wiki-strategy-live-closeout.md`). The operator
now requires fixes for both findings. Acceptance alone does not close them.

One delegate owns the hosted template-menu UI test. Another delegate owns the
semantic evidence investigation. This entry records that ownership and claims
no result from their work.

Known limitation, unchanged: the final Mara page records Chapter 7 only as
supporting provenance for its latest version, while it retains Chapter 3
claims (`progress/wiki-strategies-verification.md`). The shared write prompt
now requires supporting version inputs for retained claims. That is a
mitigation of model behavior, not a deterministic fix claim. The original
failed and partial live reports stay preserved as recorded. No rubric score
was assigned here. The operator's acceptance stays an operator decision, not
a fixture pass.

## F5 through F8: no code action

- F5: the operator confirmed the live chat and source workflow in the
  running app (closeout record above). The beachball record already documents
  the unproven causal link. No action.
- F6 and F7: the review confirmed these paths correct. No action.
- F8: the review recorded prompt contract coverage as a strength. No action.

## Gates

Targeted gate: `swift test --filter WikiStrategyStoreTests`. Result: 7 tests
in 1 suite passed, exit code 0.

Full gates (`make build`, `caffeinate -i make test`, bare `swift build`, bare
`swift test`) are held for the parent. They run after the F2 and F3 delegate
work lands, so one run covers the final branch state.
