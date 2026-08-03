# Issue #484 — Replace change-token string literals with a structured ChangeToken type

[GitHub Issue #484](https://github.com/tqbf/selfdrivingwiki/issues/484)

## Problem

`SQLiteWikiStore.changeToken()` returns a colon-joined `String` like
`"0:0:0:0:1:0:1:0:0:0:0:0:0:0"` — 14 positional fields. Tests assert against
hardcoded string literals, so adding a new `ResourceKind` fold (e.g. the
`.connection` fold in v38) breaks ~20 tests across `SQLiteWikiStoreTests`,
`LogIndexTests`, and `SystemPromptTests` that each need a `:0` appended.

## Approach

Give the change token its own structured type (`ChangeToken`) with **named
fields per fold** instead of a positional string. The contributor registry
(`tokenContributors`) still drives construction; each contributor now returns a
`ChangeTokenFold` enum case carrying its named values, and `changeToken()`
assembles them into the `ChangeToken` struct.

### New types (in `Resource.swift`)

```swift
/// One fold's structured contribution to the whole-wiki change token.
public enum ChangeTokenFold: Sendable {
    case pages(count: Int64, versionSum: Int64)
    case sourceTable(count: Int64, versionSum: Int64)
    case systemPrompt(version: Int64)
    case log(rowCount: Int64)
    case wikiIndex(version: Int64)
    case sourceMarkdownVersions(count: Int64)
    case sourceGraph(versionCount: Int64, refsGenerationSum: Int64, activitiesCount: Int64)
    case bookmarks(count: Int64)
    case chat(count: Int64, messageCount: Int64)
}

/// Structured view over the whole-wiki change token.
public struct ChangeToken: Sendable, Equatable {
    public struct Pages: Sendable, Equatable { ... }
    public struct Sources: Sendable, Equatable { ... }
    public struct SourceGraph: Sendable, Equatable { ... }
    public struct Chat: Sendable, Equatable { ... }

    public var pages = Pages()
    public var sources = Sources()
    public var systemPrompt: Int64 = 0
    public var log: Int64 = 0
    public var wikiIndex: Int64 = 0
    public var sourceMarkdownVersions: Int64 = 0
    public var sourceGraph = SourceGraph()
    public var bookmarks: Int64 = 0
    public var chat = Chat()

    /// Colon-joined form (backward compat for the File Provider sync anchor).
    public var rawString: String { ... }

    mutating func apply(_ fold: ChangeTokenFold) { ... }
}
```

### Protocol change

```swift
// Before:
func fragment(in store: SQLiteWikiStore) throws -> String

// After:
func fold(in store: SQLiteWikiStore) throws -> ChangeTokenFold
```

### Backward compatibility

The File Provider uses the token as an opaque sync anchor. The struct provides
a `rawString` property that reproduces the colon-joined form for those
consumers (`WikiDaemon.changeToken(wikiID:)`, `Projection.changeToken()`).
Tests migrate to named-field assertions; `rawString` stays available but is
not asserted against positionally.

## Token field layout (current — 14 fields from 9 contributors)

| # | Field(s) | Contributor | Source |
|---|----------|-------------|--------|
| 1-2 | `pages.count`, `pages.versionSum` | `PagesTokenContributor` | `pageCountSum()` |
| 3-4 | `sources.count`, `sources.versionSum` | `SourceTableTokenContributor` | `sourceCountSum()` |
| 5 | `systemPrompt` | `SystemPromptTokenContributor` | `systemPromptVersion()` |
| 6 | `log` | `LogTokenContributor` | `logRowCount()` |
| 7 | `wikiIndex` | `WikiIndexTokenContributor` | `wikiIndexVersion()` |
| 8 | `sourceMarkdownVersions` | `SourceDerivedTokenContributor` | `sourceMarkdownVersionCount()` |
| 9-11 | `sourceGraph.versionCount`, `.refsGenerationSum`, `.activitiesCount` | `SourceGraphTokenContributor` | `sourceVersionCount()` / `refsGenerationSum()` / `activitiesCount()` |
| 12 | `bookmarks` | `BookmarkTokenContributor` | `bookmarkNodesCount()` |
| 13-14 | `chat.count`, `chat.messageCount` | `ChatTokenContributor` | `chatCount()` / `chatMessageCount()` |

## Files affected

### Source
- `Sources/WikiFSCore/Resource.swift` — `ChangeToken` struct, `ChangeTokenFold`
  enum, `ChangeTokenContributor` protocol (`fragment`→`fold`)
- `Sources/WikiFSCore/SQLiteWikiStore.swift` — `changeToken()` return type,
  9 contributor structs (`fragment`→`fold`)
- `Sources/wikid/WikiDaemon.swift` — 2 call sites: `.changeToken()` →
  `.changeToken()?.rawString ?? ""`
- `Sources/WikiFSFileProvider/Projection.swift` — 1 call site: `.changeToken()` →
  `.changeToken().rawString`

### Tests
- `Tests/WikiFSTests/SQLiteWikiStoreTests.swift` — ~15 literal assertions +
  2 preDelete string comparisons
- `Tests/WikiFSTests/LogIndexTests.swift` — 5 literal assertions
- `Tests/WikiFSTests/SystemPromptTests.swift` — 2 literal assertions
- `Tests/WikiFSTests/ChangeTokenContributorTests.swift` — add `rawString`
  round-trip test
- `Tests/WikiFSTests/Phase5StoreCanonicalizationTests.swift` — `token: String`
  → `token: ChangeToken` in helper return type

### No changes needed
- `BytelessEmbedIntegrationTests.swift` — `before != after` (Equatable struct)
- `ProcessedMarkdownTests.swift` — `tokenBefore != tokenAfter` (Equatable)
- `EnumeratorDeletionTests.swift` — uses `Projection.changeToken()` (still
  returns String)
- `StoreEmissionExhaustivenessTests.swift` — only comment reference
