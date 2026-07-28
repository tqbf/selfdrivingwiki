---
timestamp: 2026-07-17T210059Z
title: "2026-07-17 — Reorganize WikiFSCore + WikiFS into subdirectories (#531)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Reorganize WikiFSCore + WikiFS into subdirectories (#531)

## Progress


**Problem:** `Sources/WikiFSCore/` (131 flat `.swift` files) and
`Sources/WikiFS/` (92 flat `.swift` files) were monolithic flat directories,
making navigation and understanding ownership difficult.

**Fix:** Pure `git mv` reorganization into logical subdirectories — zero new
SPM targets, zero import changes, zero access-control changes. SwiftPM
recursively includes all `.swift` under each target's `path:`, so subdirectories
are transparent to the build.

- **WikiFSCore** (131 files → 7 dirs): `Store/` (9), `Links/` (11), `Markdown/`
  (15), `Sources/` (14), `Integrations/` (25), `Search/` (6), `Core/` (51).
- **WikiFS** (92 files → 10 dirs): `Pages/` (4), `Sources/` (14), `Chats/` (4),
  `Bookmarks/` (5), `Settings/` (9), `Queue/` (11), `Window/` (18), `Reader/` (8),
  `Editor/` (17), `System/` (2).

**Test follow-up:** 4 source-scan tests had hardcoded `Sources/WikiFSCore/<File>.swift`
path strings to read source files (not compile symbols). Updated 7 path strings
across 4 test files to follow the moved files to their new subdirectories:
`FormatMaterializerTests`, `QueueStoreTests`, `StoreEmissionExhaustivenessTests`,
`SourceMaterializerTests`. No logic changed — only path strings.

**Build/Tests:** `swift build` clean (107s); fast test tier 2456 tests passed
(21s). PR #531.


---

## Verification

Historical verification remains in the progress record above.
