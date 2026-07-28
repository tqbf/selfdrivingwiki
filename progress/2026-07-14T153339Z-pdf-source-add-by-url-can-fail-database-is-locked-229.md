---
timestamp: 2026-07-14T153339Z
title: "2026-07-08 — PDF source add by URL can fail \"database is locked\" (#229)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-08 — PDF source add by URL can fail "database is locked" (#229)

## Progress


PDFKit's whole-file parse for extracting a PDF display name was running inside
the store's lock, delaying the write transaction long enough for concurrent
writers to exceed the busy timeout. Fix: resolve the display name before
acquiring the lock, and for PDFs run that resolution off the main actor.

## Verification

Historical verification remains in the progress record above.
