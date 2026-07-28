---
timestamp: 2026-07-09T111439Z
title: "2026-07-08 — #111: File Provider reports deletions via didDeleteItems"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — #111: File Provider reports deletions via didDeleteItems

## Progress


Issue #111: deleted sources (and pages) lingered in the File Provider
projection forever. Root cause — `WikiFSEnumerator.enumerateChanges` only ever
called `observer.didUpdate(_:)` with the surviving items; it never called
`didDeleteItems(_:)`, so the daemon had no signal to evict removed rows from
its materialized cache. The code even carried a comment flagging this as a
"known v0 gap."

**Fix (`Sources/WikiFSFileProvider/WikiFSEnumerator.swift`):**
- Added a process-wide, lock-guarded `KnownItemSet` cache keyed by
  `(wikiID, container)` that records the item identifiers the enumerator last
  handed the daemon.
- `enumerateItems` seeds the baseline (the full child set — correct on every
  page, not just the last, since pagination only slices for serving).
- `enumerateChanges` diffs the last-reported set against the current one and
  calls `observer.didDeleteItems(withIdentifiers:)` for identifiers that
  dropped out, then refreshes the cache.
- Survives enumerator recreation within one extension process; a process
  restart falls back to a full re-enumeration (anchor expires), which re-seeds
  the set.

**Tests (`Tests/WikiFSTests/EnumeratorDeletionTests.swift`, 3 new):**
- Deleting a source → the dropped id is reported via `didDeleteItems`; survivors
  come through `didUpdate`.
- No deletion → `didDeleteItems` is never called.
- Deleting a page → same behavior under `pages/by-id`.

**Build/tests:** `swift build` clean; `EnumeratorDeletionTests` (3) and
`ProjectionTreeTests` (29) all pass.

## Verification

Historical verification remains in the progress record above.
