---
timestamp: 2026-07-28T042708Z
title: "2026-07-28 — PageVersionID separation"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-28 — PageVersionID separation

## Progress


Added `PageVersionID` for `page_versions.id` and migrated page history, CAS, revert, restore, workspace, compare UI, CLI, and provenance paths. Created workspace pages return `nil` from `workspaceWritePage` because blob-only staging has no page-version row. Workspace conflicts tag real page versions separately from staged blob hashes, and wiki-index conflicts no longer masquerade as page-version IDs. Shared provenance uses tagged page/source version IDs.

Fixed `IdentifierBoundaryTypecheckTests` build-product discovery. The fixture compiler now selects a SwiftPM module directory that contains every imported Wiki module. It prefers the primary build tree over auxiliary index and analysis trees.

**Verification.**
- `swift build --build-tests` passed.
- The 62 affected page-version and workspace tests passed.
- `swift test --filter IdentifierBoundaryTypecheckTests` passed with 21 tests.
- `swift test` passed with 2,583 tests in 205 suites.
- `git diff --check` passed.

## Verification

Historical verification remains in the progress record above.
