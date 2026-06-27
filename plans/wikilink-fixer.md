# WikiLink Fixer

**Status**: Completed (see `PROGRESS.md` for both implementation phases)

## Motivation

LLM-generated markdown frequently introduces syntax variations that break the strict
regex used to parse `[[wiki-links]]`. The most common issues observed in production:

1. **Escaped closing brackets:** `[[source:The Value of Beliefs#"quote"\]]` — the LLM
   inserts a backslash to escape the closing bracket. The regex captures `source:...\`
   as the target, and the trailing `\` causes the link to display broken (the title
   lookup misses; markdownlint also flags the stray backslash in the orange lint banner).
2. **Escaped alias pipes:** `[[Page\|My alias]]` — the LLM escapes the pipe when
   writing inside a markdown table to avoid breaking the table syntax.

The `wikictl page upsert` path (agent writes) auto-heals `\]]` on write because it
calls `MarkdownLinter.fix()` → `WikiLinkFixer.applyFixes()` before `PageUpsert.upsert`.
The problem is pages that were ingested or written before the fixer existed, or pages
the agent has not yet touched.

## Architecture

### `WikiLinkFixer` (core, pure)

`Sources/WikiFSCore/WikiLinkValidator.swift` — enum renamed from `WikiLinkValidator`
(it corrects links, not merely validates them).

- **`WikiLinkFixer.fix(target:alias:) -> FixResult`** — strips a trailing `\` from the
  target or alias captured by the bracket regex. Pure, dependency-free.
- **`WikiLinkFixer.applyFixes(to:) -> String`** — walks all `[[links]]` outside code
  blocks in a markdown string, rewrites any that `fix()` corrects, returns the original
  string unchanged when nothing needs fixing.

### On-the-fly healing (display, link graph)

`WikiLinkMarkdown` and `WikiLinkParser` both pass raw regex captures through
`WikiLinkFixer.fix()` before rendering or inserting into the `page_links` table.
The UI visually heals broken syntax immediately without any write.

### Agent write path (always heals on save)

`MarkdownLinter.fix(markdown:)` calls `WikiLinkFixer.applyFixes()` as its first step.
`PageCommand.autoFixMarkdown` (in `WikiCtlCore`) calls `MarkdownLinter.fix()` before
every `PageUpsert.upsert`. So any page the agent writes via `wikictl page upsert` is
permanently healed at write time — the fixer cannot be re-introduced by the agent.

### In-app save path (warns, doesn't auto-fix)

`WikiStoreModel.save()` runs `MarkdownLinter.lint()` (read-only) and surfaces findings
as a non-blocking `markdownSaveWarning` in the orange banner. The human is the escape
hatch: the original text is saved as-is. The "Fix" button in the banner calls
`store.fixMarkdownInDraft()` → `MarkdownLinter.fix()` → `WikiLinkFixer.applyFixes()`,
updating the draft which the user then saves.

### Explicit page lint (Lint button + sidebar context menu)

The user-visible lint flow — "Lint" button in the page detail toolbar and "Lint Page"
in the sidebar right-click menu — runs a two-phase correction:

**Phase 1 — `WikiStoreModel.preflightLint(pageID:) -> LintPreflight?`**

1. Reads the page fresh from SQLite.
2. Applies `WikiLinkFixer.applyFixes()`. If the body changed, persists via
   `PageUpsert.upsert`, reloads summaries, and syncs the loaded draft (without marking
   it dirty — the fix is already on disk).
3. Parses all `[[page links]]` (not source links) from the fixed body and checks each
   target against `store.summaries`. Broken links — targets with no matching wiki page —
   are collected.
4. Returns `LintPreflight { didFixLinks: Bool, brokenPageLinks: [String] }`.

**Phase 2 — LLM lint (`AgentOperationRunner.runLintPage`)**

Calls `preflightLint` to get the pre-flight results, then launches `claude -p` with:

- `WikiOperation.lintPage(pageTitle:brokenLinks:stateFilePath:)` — carries the
  pre-computed broken links into the prompt so the agent has concrete targets rather
  than having to discover issues itself.
- `lintPagePrompt` tells the agent:
  - What the pre-flight corrected (bracket syntax).
  - Which `[[links]]` don't resolve to existing pages (the broken-link list).
  - To read the page, fix broken links (find the right target / create the page / remove
    spurious links), check for other issues, rewrite if needed, and log with
    `wikictl log append --kind lint`.

## End-to-end pipeline

```
Page has [[source:X\]]
  → markdownlint lint() sees stray \ → orange banner warning appears
  → user clicks "Lint"
  → preflightLint: WikiLinkFixer corrects \]] → page saved → broken links scanned
  → LLM launched with "these links don't resolve: [[A]], [[B]]"
  → LLM reads page, fixes links, upserts (wikictl auto-heals on write too)
  → wikictl log append --kind lint
```

## Files changed

| File | Change |
|------|--------|
| `Sources/WikiFSCore/WikiLinkValidator.swift` | Renamed `WikiLinkValidator` → `WikiLinkFixer`, `ValidatedLink` → `FixResult`, `validate()` → `fix()` |
| `Sources/WikiFSCore/WikiLinkParser.swift` | Updated caller: `WikiLinkFixer.fix()`, `fixed.target`, `fixed.alias` |
| `Sources/WikiFSCore/WikiLinkMarkdown.swift` | Same caller update |
| `Sources/WikiFSCore/MarkdownLinter.swift` | `WikiLinkFixer.applyFixes()` |
| `Sources/WikiFSCore/WikiStoreModel.swift` | `preflightLint(pageID:) -> LintPreflight?` replaces `lintPage(_:) -> Bool` |
| `Sources/WikiFSCore/WikiOperation.swift` | `case lintPage(pageTitle:brokenLinks:stateFilePath:)` + `lintPagePrompt` |
| `Sources/WikiFS/OperationRequest.swift` | `case lintPage(pageTitle:brokenLinks:stateMarkdown:)` + staging |
| `Sources/WikiFS/AgentOperationRunner.swift` | `runLintPage(pageID:pageTitle:launcher:store:manager:fileProvider:)` |
| `Sources/WikiFS/PageDetailView.swift` | "Lint" button → `AgentOperationRunner.runLintPage` |
| `Sources/WikiFS/SidebarView.swift` | "Lint Page" context menu → `runLintPage`; `launcher: AgentLauncher` added |
| `Sources/WikiFS/ContentView.swift` | Passes `agentLauncher` to `SidebarView` |

## Testing

- `WikiLinkValidatorTests.swift` — unit tests for standard, escaped-bracket, and
  escaped-pipe links (still pass; the rename is non-breaking at test level since the
  tests were updated to use `WikiLinkFixer`).
- `RealDatabaseTest.swift` — integration test that ran over all `.md` files in a
  production iCloud directory; identified and patched 7 live files at initial rollout.
