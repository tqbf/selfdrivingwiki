# WikiLink Fixer

**Status**: Completed

## Problem

LLM-generated markdown introduces backslash escapes that break `[[wiki-link]]` parsing:

- `[[source:X#"quote"\]]` — escaped closing bracket gets captured as part of the target, breaking the link display and showing up as a stray `\` in the markdown lint warning banner.
- `[[Page\|alias]]` — escaped pipe, common when the LLM writes inside a markdown table.

`WikiLinkFixer` corrects these at three surfaces so pages heal regardless of how the fix arrives.

## Three healing surfaces

**1. On-the-fly (display only)**
`WikiLinkMarkdown` and `WikiLinkParser` strip trailing `\` from each link's raw regex captures before rendering or writing to the `page_links` table. The page looks correct immediately; the file on disk is unchanged.

**2. Agent write path (permanent, automatic)**
`MarkdownLinter.fix()` applies `WikiLinkFixer.applyFixes()` as its first step. `wikictl page upsert` calls the linter before every write, so any page the LLM rewrites is permanently corrected at write time — the bug cannot re-enter via the agent.

**3. Explicit page lint (user-triggered)**
The "Lint" button in the page detail toolbar and "Lint Page" in the sidebar right-click menu run a two-phase flow:

- **Pre-flight** (`WikiStoreModel.preflightLint`): applies `WikiLinkFixer.applyFixes()` and saves immediately if any `\]]` were found; then parses all `[[page links]]` and checks each target against known page titles, collecting any that don't resolve.
- **LLM lint** (`AgentOperationRunner.runLintPage`): launches `claude -p` with a page-scoped prompt (`WikiOperation.lintPage`) that includes the pre-computed broken-link list so the agent has concrete targets rather than discovering issues itself. The agent reads the page, fixes broken links, checks for other issues, rewrites if needed, and logs with `wikictl log append --kind lint`.

## End-to-end flow

```
Page has [[source:X\]]
  → on save: orange markdown lint banner surfaces the stray \
  → user clicks "Lint"
  → pre-flight: WikiLinkFixer corrects \]] → page saved
  → broken links scanned: [[A]], [[B]] don't resolve
  → LLM launched with findings pre-loaded
  → LLM fixes links, upserts (auto-healed again on write)
  → wikictl log append --kind lint
```

## Testing

`WikiLinkFixerTests` (`Tests/WikiFSTests/WikiLinkValidatorTests.swift`):

- `testNormalLink` — clean link passes through unchanged.
- `testEscapedBracketInTarget` — `source:Doc\` → `source:Doc`.
- `testEscapedBracketInAlias` — `My alias\` → `My alias`.
- `testApplyFixesProductionPatterns` — batch fixer over inline markdown reproducing the `\]]` patterns found across 7 live production pages at initial rollout.
- `testApplyFixesUnchangedWhenClean` — clean markdown is returned as-is.
