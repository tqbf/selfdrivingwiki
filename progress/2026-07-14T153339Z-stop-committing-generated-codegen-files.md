---
timestamp: 2026-07-14T153339Z
title: "2026-07-14 — Stop committing generated codegen files"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-14 — Stop committing generated codegen files

## Progress


`GeneratedVersion.swift` (git SHA → Swift) and `GeneratedPrompts.swift` (prompt
markdown → Swift) are now gitignored — regenerated at build time by `make
version` / `make prompts`. Previously they were checked in, causing constant
diff noise: the version file embedded the git SHA, so it drifted on every commit
(the committed snapshot always pointed at the *previous* SHA). CI now runs
`make version prompts` before `swift build` instead of gating on drift.

## Verification

Historical verification remains in the progress record above.
