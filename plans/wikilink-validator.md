# WikiLink Validator

**Status**: Completed

## Motivation

LLM-generated markdown frequently introduces "hallucinations" or syntax variations that break the strict regexes used to parse `[[wiki-links]]`. The most common issues observed in production are:
1. **Escaped closing brackets:** `[[source:The Value of Beliefs#"quote"\]]` - the LLM inserts a backslash to escape the closing bracket, which gets captured by the fragment regex and causes the link to display brokenly.
2. **Escaped alias pipes:** `[[Page\|My alias]]` - the LLM escapes the pipe when constructing markdown tables to avoid breaking the table syntax.

## Implementation

To fix this robustly without scattering cleanup logic throughout the codebase, we implemented a pure, dependency-free `WikiLinkValidator`.

### Architecture
- **`WikiLinkValidator.swift`**: A pure data-in/data-out pipeline struct that inspects the raw `target` and `alias` parsed from `WikiLinkSpan.regex`. It trims trailing backslashes and normalizes other edge cases.
- **On-the-Fly Healing (`WikiLinkMarkdown`, `WikiLinkParser`)**: Before rendering a link or extracting it to the database, the regex captures are passed through the validator. This ensures the app visually "heals" the broken markdown immediately.
- **Data-at-Rest Healing (`MarkdownLinter`)**: The validator is integrated into the linter's `applyFixes` phase. It scans the raw markdown string and permanently overwrites the broken syntax (e.g. `\]]`) with correct syntax (`]]`) before the file is saved back to disk.

### Testing
- `WikiLinkValidatorTests.swift`: Unit tests validating standard, escaped-bracket, and escaped-pipe links.
- `RealDatabaseTest.swift`: An integration test that ran the validator over all `.md` files in a production iCloud directory to confirm real-world efficacy. It successfully identified and patched 7 live files.
