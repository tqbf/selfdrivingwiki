---
timestamp: 2026-10-22T072421Z
title: Page lint pre-flight lists raw external URLs and malformed tables
branch: bugfix/lint-worklist
status: complete
---

# Page lint pre-flight lists raw external URLs and malformed tables

## Progress

- Fixed #1461: a single-page lint could end "completed" without fixing anything
  because the task was link-centric and pre-flight only detected broken wiki
  links (job `01M5H1JK6HW362QBQ506R77FH6`, page "The Lady": 15s, 548 output
  tokens, "needs no changes" while the page held raw URLs and a broken table).
- Added `LintPagePreflight` + `LintPreflightScanner`
  (`Sources/WikiFSCore/Core/LintPagePreflight.swift`): two pure, factual
  detectors — bare `http(s)` URLs in prose (proper markdown links, angle
  autolinks, code spans, and fenced blocks are exempt) and malformed markdown
  tables (a run of `|`-prefixed lines with no valid separator row or
  inconsistent column counts). Both report `line <n>: …` entries and change
  nothing.
- `WikiStoreModel.LintPreflight` gains `rawExternalURLs` + `malformedTables`;
  `preflightLint(pageID:)` populates them on the post-`WikiLinkFixer` body.
- `WikiOperation.lintPage` / `OperationRequest.lintPage` now carry the full
  worklist. The associated value stays labeled `brokenLinks`, but its type is
  `LintPagePreflight`, which conforms to `ExpressibleByArrayLiteral` — existing
  call sites passing `brokenLinks: []` (including the daemon provider, which is
  intentionally untouched) keep compiling unchanged.
- `lintPagePrompt` renders two new sections next to the broken-links section
  (`Raw external URLs …` / `Malformed markdown tables …`, each "list or none
  detected", filled through the existing `{{token}}` template seam).
- `prompts/lint-page-task.md` names the audit steps: raw external URLs become
  `[[Page Title]]` / `[[source:…]]` citations where a target exists (a bare URL
  is a legitimate citation when it does not), tables are repaired structurally
  without dropping rows, and "a clean pre-flight report is the START of the
  audit, not its conclusion". Synced to
  `Sources/WikiFSCore/Resources/Prompts/lint-page-task.md` via `make prompts`.
- Updated the stale "Lint stays single-agent Opus" comments in
  `WikiOperation.swift`: the model comes from the run configuration.

## Verification

- New suite `Tests/WikiFSTests/LintPagePreflightTests.swift` (20 tests, default
  test graph): URL in prose listed with line number; URL inside a proper
  markdown link, angle autolink, code span, and fenced block not listed; no
  URLs → empty; trailing punctuation trimmed. Well-formed table clean; missing
  separator row and inconsistent column counts reported with the start line;
  fenced-block tables and single `|` lines ignored. Array-literal transport
  checks. Prompt renders all three sections (list and "none detected"), carries
  the named audit steps, and leaves no unfilled `{{…}}` placeholders.
  `preflightLint` integration: a page with a bare URL and a separator-less
  table lists both; a clean page lists neither.
- `make build` green (includes the untouched `wikid` target);
  `make test` green — full suite, no failures; `make lint` green —
  0 violations in 741 files.
