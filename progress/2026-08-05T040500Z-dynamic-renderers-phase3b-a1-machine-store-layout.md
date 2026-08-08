---
timestamp: 2026-08-05T040500Z
title: Dynamic renderers Phase 3b A1 machine-store layout
branch: feature/dynamic-renderers-03b-machine-store
status: complete
---

# Dynamic renderers Phase 3b A1 machine-store layout

## Progress

Added the typed, versioned machine package-store layout under the resolved App Group container. The layout reserves deterministic paths for package versions, staging areas, the derived JSON index, lock file, and future machine journal without creating or mutating any of them.

Added one canonical containment predicate that rejects sibling-prefix, traversal, absolute non-file, and resolved symlink escapes. Added a POSIX filesystem seam that provides `lstat` identities and `O_NOFOLLOW` opens without `FileManager` link-following inspection.

No package coordinator, index or journal mutation, registry activation, WebKit, File Provider, or wiki-store changes were added.

## Verification

- `swift test --filter RendererPackageStoreLayoutTests` passes: 5 tests.
