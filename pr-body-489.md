## Summary

Consolidates the hand-stringified link-kind prefixes (`"page:"` / `"source:"` / `"chat:"` / `"bookmark:"`) and inline URL host comparisons into typed accessors, eliminating 7+ duplicate literal sites (#489).

## Changes

### New typed accessors (single source of truth)

- **`ResourceKind.linkPrefix`** (`Sources/WikiFSCore/Resource.swift`) — computed property returning `"page:"` / `"source:"` / `"chat:"` / `"bookmark:"` for linkable kinds, `nil` for non-linkable kinds (`systemPrompt`, `wikiIndex`, `log`).
- **`ParsedLink.LinkType.resourceKind`** + **`ParsedLink.LinkType.linkPrefix`** (`Sources/WikiFSCore/WikiLinkParser.swift`) — bridges the overlap between the 3-case `LinkType` enum and the 7-case `ResourceKind` enum, delegating prefix strings to `ResourceKind.linkPrefix` so both vocabularies draw from one definition.
- **`WikiLinkMarkdown.sourceHost`** / **`WikiLinkMarkdown.anchorHost`** (`Sources/WikiFSCore/WikiLinkMarkdown.swift`) — new static constants alongside the existing `resolvedHost` / `chatHost` / `unresolvedHost`.

### Inline literal sites replaced

| File | Before | After |
|------|--------|-------|
| `WikiLinkParser.swift` | `peel(prefix: "page:"/…)` + literal array | `ParsedLink.LinkType.page.linkPrefix` + `allCases` loop |
| `WikiLinkRewriter.swift` | `case .source: prefix = "source:"` switch | `kind.linkPrefix` |
| `MarkdownHTMLRenderer.swift` | `case "source": prefix = "source:"` | `WikiLinkMarkdown.sourceHost` + `.source.linkPrefix` |
| `WikiStateSnapshot.swift` | `"page:\(…)"` interpolation | `ResourceKind.page.linkPrefix` |
| `OmniboxResult.swift` | `"page:\(p.id.rawValue)"` etc. | `ResourceKind.page.linkPrefix!` |
| `AgentLauncher.swift` | `"chat:\(chatID)"` (×2) | `ResourceKind.chat.linkPrefix!` |
| `BlobSchemeHandler.swift` | `url.host == "source"` | `WikiLinkMarkdown.sourceHost` |
| `WikiLinkMarkdown.swift` | `host == "source"` / `== "anchor"` (×6) | `sourceHost` / `anchorHost` |

### Test

- `Tests/WikiFSTests/LinkPrefixAccessorTests.swift` — 9 tests asserting prefix values, nil-returns for non-linkable kinds, the `LinkType` → `ResourceKind` bridge, host constants, and end-to-end flow through `classify` / `isEmptyPrefix`.

## Verification

```
# Issue's grep — zero hits outside accessor doc comments:
rg '"page:"|"source:"|"chat:"' Sources/ -t swift
# → only 3 lines, all in doc comments of accessor definitions

# Full fast test tier passes (2447 tests):
swift test --skip 'EnumeratorDeletionTests|SQLiteWikiStoreTests|StoreEmissionTests|FreshSchemaParityTests|SQLiteStatementLifecycleIntegrationTests|BlobVacuumTests|AgentCASTests|GenerationGateLaneTests|WorkspaceStagingTests|WorkspaceMergeCompletenessTests|IngestIsolationTests|ChatSummaryTests|ProjectionTreeTests'
```

Closes #489.
