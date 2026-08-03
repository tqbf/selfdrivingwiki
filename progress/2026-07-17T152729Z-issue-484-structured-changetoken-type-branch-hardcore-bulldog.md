---
timestamp: 2026-07-17T152729Z
title: "2026-07-17 — Issue #484: Structured ChangeToken type (branch `hardcore-bulldog`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Issue #484: Structured ChangeToken type (branch `hardcore-bulldog`)

## Progress


**Shipped.** Replaced the positional colon-joined `changeToken()` string
literals with a structured `ChangeToken` type — named fields per fold
(`pages`, `sourceTable`, `systemPrompt`, `log`, `wikiIndex`,
`sourceMarkdownVersions`, `sourceGraph`, `bookmarks`, `chat`) so adding a new
`ResourceKind` fold no longer breaks ~20 tests that each need a `:0` appended.

**New types** (`Sources/WikiFSCore/Resource.swift`):
- `ChangeToken` — `Sendable, Equatable` struct with named properties; nested
  structs (`Pages`, `SourceTable`, `SourceGraph`, `Chat`) for the multi-field
  folds. A `rawString` property reproduces the colon-joined form for the File
  Provider sync anchor.
- `ChangeTokenFold` — enum cases carrying named values; one case per contributor
  fold.
- `ChangeTokenContributor` protocol: `fragment(in:) -> String` →
  `fold(in:) -> ChangeTokenFold`.

**Changed** (`Sources/WikiFSCore/SQLiteWikiStore.swift`):
- `changeToken()` return type `String` → `ChangeToken`; assembles via
  `var token = ChangeToken(); for c in contributors { token.apply(try c.fold(in: self)) }`.
- 9 contributor structs updated from `fragment` → `fold`.

**Non-test callers** updated to use `.rawString`:
- `Sources/wikid/WikiDaemon.swift` — 2 sites: `(try? store.changeToken())?.rawString ?? ""`.
- `Sources/WikiFSFileProvider/Projection.swift` — 1 site: `token.rawString`.
  `Projection.changeToken()` still returns `String` (the FP opaque anchor).

**Tests migrated** (~22 literal assertions → named-field assertions):
- `SQLiteWikiStoreTests.swift` — 10 literal assertions + 2 preDelete string
  comparisons across 3 tests (`changeTokenAdvancesOnEveryMutation`,
  `changeTokenAdvancesOnIngestAndDelete`, `changeTokenAdvancesOnAppendProcessedMarkdown`).
- `LogIndexTests.swift` — 5 literal assertions across 2 tests.
- `SystemPromptTests.swift` — 2 literal assertions.
- `Phase5StoreCanonicalizationTests.swift` — `token: String` → `token: ChangeToken`
  in helper return type.
- `ChangeTokenContributorTests.swift` — added `rawStringMatchesHistoricalLayout`
  test (single assertion guarding `rawString` reproduces the historical token).

**No changes needed** (Equatable struct worked for `before != after`-style
comparisons): `BytelessEmbedIntegrationTests`, `ProcessedMarkdownTests`,
`EnumeratorDeletionTests` (uses `Projection.changeToken()` which still returns
`String`), `StoreEmissionExhaustivenessTests` (comment-only reference).

**Evidence.**
- `swift build` ✓ (159s, clean).
- `swift test --filter 'SQLiteWikiStoreTests'` ✓ (48 tests passed).
- Targeted change-token tests ✓ (all passed:
  `ChangeTokenContributorTests`, `LogIndexTests`, `SystemPromptTests`,
  `changeTokenAdvances*`, `renameSource*`, `changeTokenChangesOnVersionAppend`).
- `StoreEmissionTests` ✓ (12 tests passed — `changeToken()` signature change
  didn't break the exhaustiveness parse).
- Fast-tier `swift test --skip` ✓ (2438 tests passed).
- `rg 'changeToken\(\)\s*==\s*"' Tests/` — no remaining string-literal comparisons.
- `rg 'fragment\(in' Sources/ Tests/` — no remaining `fragment(in:)` calls.

See [`plans/issue-484-change-token-struct.md`](plans/issue-484-change-token-struct.md).

## Verification

Historical verification remains in the progress record above.
