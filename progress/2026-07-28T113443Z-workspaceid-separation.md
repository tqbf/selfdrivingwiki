---
timestamp: 2026-07-28T113443Z
title: "2026-07-28 — WorkspaceID separation"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-28 — WorkspaceID separation

## Progress


**Scope.** Added a distinct `WorkspaceID` namespace for workspace entities. The change preserves all stored and external raw identifier text.

**What changed.**
- Added `WorkspaceID` to `WikiFSTypes` with the same primitive-string Codable shape as other identifier types.
- Changed workspace summaries, refs, conflicts, store methods, model facades, ingestion, and agent execution to use `WorkspaceID`.
- Kept SQLite columns as `TEXT`. GRDB converts identifiers only at row and parameter boundaries.
- Kept CLI command input and output as text. CLI handlers convert to `WorkspaceID` before store calls.
- Kept `WIKI_WORKSPACE` as text. The launcher writes `WorkspaceID.rawValue` to the environment hint.
- Added `WorkspaceIDTests` and `plans/workspace-id-separation.md`.

**Verification.**
- `swift build` passed before this final test pass.
- `swift test --filter 'Workspace(ID|Transition|.*Workspace.*)'` — 48 tests in 6 suites passed.
- `swift test` — ran 2,585 tests in 205 suites, then failed with 21 issues. The failures were in existing `IdentifierBoundaryTypecheckTests` / fixture compilation checks, which reported `no such module 'WikiFSCore'` or `no such module 'WikiFSEngine'`; all workspace suites passed.
- Final migration scan: no `workspaceID: String` declarations remain in Swift sources.
- `git diff --check` — clean.

## Verification

Historical verification remains in the progress record above.
