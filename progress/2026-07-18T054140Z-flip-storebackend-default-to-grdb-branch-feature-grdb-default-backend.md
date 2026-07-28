---
timestamp: 2026-07-18T054140Z
title: "2026-07-17 — Flip StoreBackend default to GRDB (branch `feature/grdb-default-backend`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Flip StoreBackend default to GRDB (branch `feature/grdb-default-backend`)

## Progress


**What changed:** The GRDB migration is complete — all 88 methods implemented
(#545/#550), 37-version migration ladder (#557), and 2,480 parity tests pass
(#561). `StoreBackend.current` now defaults to `.grdb` instead of `.sqlite`.
Setting `WIKIFS_STORE_BACKEND=sqlite` opts back in to the legacy
`SQLiteWikiStore` as an escape hatch.

**Deprecation:** Added prominent `⚠️ DEPRECATED` doc comment headers to
`SQLiteWikiStore`, `SQLiteStatement`, and `WikiReadPool`, noting that
`GRDBWikiStore` is the default and these types will be removed in a future
version. No `@available(*, deprecated)` markers were added — with
`-warnings-as-errors` active and live production usage of `WikiReadPool`
outside `SQLiteWikiStore`, compiler-enforced deprecation would break the build.
Compiler-enforced deprecation will come in a follow-up PR when the files are
actually deleted.

**Tests:** Fast test tier (2,487 tests) passes against GRDB by default
(`WIKIFS_STORE_BACKEND` unset). `SQLiteWikiStoreTests` (48 tests) still pass
— they construct the store directly, not through the factory, confirming the
deprecated code remains functional.

## Verification

Historical verification remains in the progress record above.
