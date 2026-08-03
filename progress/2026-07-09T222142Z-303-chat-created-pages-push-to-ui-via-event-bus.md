---
timestamp: 2026-07-09T222142Z
title: "2026-07-09 — #303: Chat-created pages push to UI via event bus"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — #303: Chat-created pages push to UI via event bus

## Progress


`WikiChangeBridge.flush` was an either/or: for the active wiki it emitted a
coarse bus event (model reloaded, but the File Provider was only refreshed
transitively via the bus subscriber with an extra ~250 ms debounce); for a
non-active wiki it signaled the File Provider directly and never poked the bus.
The either/or meant that if `activeWikiID` changed during the coalesce window
(user switched wikis mid-burst), the model reload was skipped entirely.

**Fix:** `flush` now **always** signals the File Provider directly for the
changed wiki, **and** emits the coarse bus event when the wiki is the active
one. Both paths fire unconditionally for their respective targets — no more
either/or. The redundant FP signal for the active wiki (direct + bus subscriber)
is harmless: `NSFileProviderManager.signalEnumerator` is idempotent and the FP's
own coalescer collapses the duplicate.

- `Sources/WikiFS/WikiChangeBridge.swift` — `flush` restructured + doc comment
  updated.
- `plans/event-bus.md` — emitter description updated to reflect the new
  always-signal + conditional-bus-emit behavior.
- `Tests/WikiFSTests/WikiChangeBridgeBusTests.swift` — two new tests:
  `crossProcessWriteSurfacedByCoarseEvent` (wikictl write through a separate
  store with no bus → model picks it up purely from the coarse event) and
  `burstOfWritesOneCoarseEventSurfacesAll` (a burst of writes collapsed into one
  coarse event surfaces all pages).

## Verification

Historical verification remains in the progress record above.
