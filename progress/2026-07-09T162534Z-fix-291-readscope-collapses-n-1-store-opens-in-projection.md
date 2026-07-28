---
timestamp: 2026-07-09T162534Z
title: "2026-07-09 — Fix #291: ReadScope collapses N+1 store opens in Projection"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-09 — Fix #291: ReadScope collapses N+1 store opens in Projection

## Progress


`children(of: .workingSet)` opened ~35 independent SQLite connections per
enumeration pass (one per leaf, index, singleton doc, and `changeToken()` call).
Each `SQLiteWikiStore(readOnlyURL:)` runs pragma setup + `registerVec` + a WAL
checkpoint on close, making the working-set tests take 165 s+ each.

**Fix:** added a `ReadScope` reference type (`Projection.ReadScope`) that lazily
opens ONE store and caches ONE change token. The three public entry points
(`children(of:)` / `node(for:)` / `contents(for:)`) now create a scoped copy of
`self` carrying a `ReadScope`, so every internal `openReadStore()` /
`changeToken()` call within that operation reuses the same connection. The
private `*Resolved` methods hold the original bodies.

**Result:** `ProjectionTreeTests` (37 tests) went from 165 s+ per working-set
test to ~32 s for the entire suite (~10x). All 1908 fast-tier tests + the
EnumeratorDeletionTests still pass.

**Bonus:** caching `changeToken()` within one pass also makes node versioning
more consistent (previously each call queried independently, risking slight
drift mid-pass). This also speeds up the real File Provider extension.

## Verification

Historical verification remains in the progress record above.
