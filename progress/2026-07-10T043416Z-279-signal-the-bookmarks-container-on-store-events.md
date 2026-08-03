---
timestamp: 2026-07-10T043416Z
title: "2026-07-09 — #279: Signal the bookmarks container on store events"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #279: Signal the bookmarks container on store events

## Progress


**Problem:** `FileProviderSpike.signalChange(forWikiID:)` had a hardcoded list
of containers to proactively refresh on every store event. The top-level
`bookmarks/` folder was missing — only pages/root/indexes/sources/chats views
plus `.workingSet` were signaled. So a Finder/Terminal user browsing
`bookmarks/` directly wouldn't see bookmark create/move/delete changes until a
working-set sweep re-enumerated. (The working set still caught deletions
authoritatively; the per-container signal is an optimization for proactive
refresh.)

**Fix:** added `NSFileProviderItemIdentifier(WikiFSContainerID.bookmarks)` to
the `containers` array in `signalChange(forWikiID:)`. Bookmarks use
`NestedResourceProjection` (arbitrary-depth folders), so only the top-level
container needs signaling — nested folder enumerators refresh via the parent's
`didUpdate` re-enumeration.

**Tests:** no new tests — the signal path is best-effort against
`NSFileProviderManager` and not unit-testable. `swift build` clean.

## Verification

Historical verification remains in the progress record above.
