---
timestamp: 2026-07-19T231719Z
title: "wikictl CLI — `page` subcommand namespace (feature/wikictl-page-cmd)"
branch: null
status: historical
timestamp_source: git-commit
---

# wikictl CLI — `page` subcommand namespace (feature/wikictl-page-cmd)

## Progress


**Date:** 2026-07-19

The `wikictl` CLI historically had a mix of flat page commands (`.list`,
`.get`, `.upsert`, `.delete`, `.search`, `.pageHistory`, `.pageRevert`,
`.sourceEditMarkdown`, `.sourceRename`, `.sourceSetActive`,
`.sourceRefresh`) on `ArgumentParser.Command` alongside already-namespaced
cases (`.source(SourceCommand.Action)`, `.chat(...)`, `.bookmark(...)`,
`.workspace(...)`, `.admin(...)`). This refactor moves every page/source
flat case under its existing namespacing enum, mirroring the
`SourceCommand.Action` pattern.

**Changes:**

- **`PageCommand.Action`** (the executable form):
  - Renamed `upsert` → `add`. The body is now `BodySource` (`.inline(String)`
    or `.file(path)`), so the action carries the same I/O-deferral info the
    parser used to. `PageCommand.run(.add(...))` resolves the body source
    just before the write.
  - `history`, `revert` already used the renamed cases (no change there).
- **`SourceCommand.Action.editMarkdown`** — `content: String` →
  `content: BodySource`, mirroring `PageCommand.Action.add`. Resolution
  happens inside `SourceCommand.run`.
- **`ArgumentParser.Command`** — removed the 11 flat page/source cases.
  Added `case page(PageCommand.Action)` (the single wrapping form). The
  parser routes `wikictl page …` and `wikictl source …` two-level via
  `parsePageCommand` / `parseSourceCommand`, both of which now produce the
  wrapping `.page(...)` / `.source(...)` form directly. Removed
  `parseSearchCommand` and `parseSourceEditMarkdown` helpers (their
  logic is inlined into the parent parser). Updated `applyEnv` so
  `WIKI_WORKSPACE` / `WIKI_AUTHOR` inject via pattern-matching
  `.page(.get(...))` / `.page(.add(...))`.
- **CLI grammar change** — `wikictl search` (top-level) is now
  `wikictl page search` (it was an implicit page command, now explicitly
  namespaced). `wikictl page upsert` → `wikictl page add` (the rename).
  All other page subcommands unchanged at the CLI grammar level
  (`page list/get/delete/history/revert`).
- **`main.swift`** — `execute()` is now 11 cases (down from 22). The flat
  `.list/.get/.delete/.upsert/.search/.pageHistory/.pageRevert` and
  `.sourceEditMarkdown/.sourceRename/.sourceSetActive/.sourceRefresh`
  dispatches collapse into `case .page(let action)` and `case .source(...)`.
  Async refresh still routed via the `RefreshResultBox` semaphore bridge,
  now triggered by `if case .refresh(let selector) = action` inside the
  `.source` branch.
- **`BodySource`** (`Sources/WikiCtlCore/BodySource.swift`) — new
  `public enum BodySource: Equatable, Sendable` with `.inline(String)`
  and `.file(String)` (path or `-` stdin). `resolveBodySource(...)` and
  `readBodyFile(...)` are public so `wikictl/main.swift` reuses the same
  stdin/file resolution for `indexSet` (the one flat case that stays —
  `logAppend`/`indexSet` are already two-level via `log append` /
  `index set` subcommands and were left as-is).
- **Docs/prompts** — `page upsert` → `page add` and `wikictl search` →
  `wikictl page search` across `prompts/*.md` (regenerated
  `GeneratedPrompts.swift` via `make prompts`), in-source doc comments,
  and test assertions that pin prompt text. Historical bash traces in
  `progress/` left intact (they describe what was run at the time).

**Test updates:** `WikiCtlCommandTests`, `AgentCASTests`,
`IngestIsolationTests`, `MermaidValidatorTests` updated for the
`.page(.add(...))` / `BodySource.inline(...)` shapes; parser tests for
search now invoke `page search` instead of top-level `search`. All other
test assertions are prompt-text replacements only.

**Result:** 258 suites / 3031 tests pass. `swift build` clean.

**Build:** `make version prompts && swift build && swift test`.

## Verification

Historical verification remains in the progress record above.
