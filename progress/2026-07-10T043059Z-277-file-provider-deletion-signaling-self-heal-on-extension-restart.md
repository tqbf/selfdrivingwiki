---
timestamp: 2026-07-10T043059Z
title: "2026-07-09 — #277: File Provider deletion signaling — self-heal on extension restart"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #277: File Provider deletion signaling — self-heal on extension restart

## Progress


**Problem:** #111/#276 fixed deleted sources/pages lingering in the File
Provider by diffing the last-reported item set (`knownItems`) against the
current one in `WikiFSEnumerator.enumerateChanges` and calling
`didDeleteItems`. But `knownItems` is process-static (in-memory only), while
the sync anchor is persisted by the File Provider framework across extension
process restarts. On a routine extension relaunch the framework can call
`enumerateChanges(from: validAnchor)` with no prior `enumerateItems` in the new
process → `knownItems` is nil → the deletion diff is skipped → deletions that
landed while the process was dead are silently dropped (the original #111
symptom reintroduced). The docstring also wrongly claimed the anchor "expires"
on restart (it doesn't — only unparseable/legacy anchors expire).

**Fix:** in `enumerateChanges`, when the baseline is absent, return
`syncAnchorExpired` instead of diffing against an empty set. The framework then
discards its cache and does a clean full `enumerateItems`, which re-seeds the
baseline. Cost is one full re-enumeration per container after a restart; the
restart path now emits only the expiry (no wasteful `didUpdate`). Corrected the
misleading `KnownItemSet` docstring. Findings #2 (kinds) / #3 (nested) / #4
(concurrency) from the issue review were closed by tests, not code: the diff is
generic over `projection.children(of:)`, the `NSLock` guards only the dict
get/set (DB read + diff run unlocked), and the `wikiID/container` cache key
can't collide.

**Tests:** 4 new cases in `EnumeratorDeletionTests` — bookmark-ref deletion,
chat deletion, nested folder deletion, and the restart baseline-loss case
(asserts anchor expiry, not a silent drop). Full suite 7/7 pass
(`swift test --filter EnumeratorDeletionTests`).

## Verification

Historical verification remains in the progress record above.
