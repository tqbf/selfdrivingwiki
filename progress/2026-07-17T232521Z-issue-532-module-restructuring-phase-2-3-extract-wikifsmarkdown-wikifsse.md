---
timestamp: 2026-07-17T232521Z
title: "2026-07-17 — Issue #532: Module restructuring Phase 2+3 — extract WikiFSMarkdown + WikiFSSearch (branch `refactor/extract-markdown-search`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-17 — Issue #532: Module restructuring Phase 2+3 — extract WikiFSMarkdown + WikiFSSearch (branch `refactor/extract-markdown-search`)

## Progress


**Shipped.** Extracted two new SPM targets following the Phase 1 pattern
(WikiFSLinks + WikiFSTypes, PR #535):

- **`WikiFSMarkdown`** (16 files) — linter, extractors, diffs, HTML↔markdown
  converters, slug utils, mermaid validator. Depends on `WikiFSTypes` +
  `WikiFSLinks` (`WikiLinkFixer`, `WikiLinkSpan`). Links `JavaScriptCore`
  (MarkdownLinter + MermaidValidator run vendored JS in a JSContext).
- **`WikiFSSearch`** (6 files) — `Embedder` protocol, `NLEmbedder`,
  `EmbeddingService`, `TextChunker`, `RankFusion`, `WikiIndex`. Depends on
  `WikiFSTypes` only. Links `NaturalLanguage` (NLEmbedder).

Both re-exported by `WikiFSCore` via `@_exported import` in `ModuleExports.swift`
so consumers don't need per-file imports.

**Key decisions:**
- **Moved `DebugLog` to `WikiFSTypes`** — the pure leaf logging type (Foundation
  + `os` only) was used by both `MarkdownLinter` and `EmbeddingService`. Moving
  it to the leaf module + re-export solved both dependencies cleanly.
- **Inlined 3 `GeneratedPrompts` references** to break circular dependencies
  (`WikiFSMarkdown`/`WikiFSSearch` → `WikiFSCore` → back): `wikiIndexDefault`
  (4-line fallback string in `WikiIndex`), `extractionSystem` +
  `extractionInstruction` (extraction prompts in `ExtractionPrompts`). Each has
  a comment pointing to its `prompts/*.md` source file.
- **Kept `PageMarkdownFormat.swift` in WikiFSCore** — it references `WikiPage`
  and `SourceMarkdownVersion` (domain model types with deep WikiFSCore coupling)
  and has ~23 call sites. Too coupled to extract without a protocol-injection
  refactor; left in `Sources/WikiFSCore/Markdown/` per the task's "keep if too
  coupled" guidance.
- **Widened 5 access levels to `public`** (was `internal`, accessed cross-module
  after extraction): `SlugUtils.slugBase`, `RankFusion.rrf`, plus
  `HTMLToMarkdown.Token`/`scopedTokens`/`markdown(fromScopedTokens:)`/`titleOnly`
  and `WikiFootnoteMarkdown.Footnote.init` (Swift 6 implicit memberwise init is
  internal — added explicit public init).
- **Removed `linkerSettings` from WikiFSCore** — `JavaScriptCore` and
  `NaturalLanguage` are now linked by their respective extracted targets and
  transitively available through the dependency chain.

**Dependency graph** (DAG, no cycles):
```
WikiFSTypes (leaf)
├─ DebugLog, PageID, ULID, ResourceKind, EmbedTarget, ParsedLink, MimeType
├─ WikiFSLinks → WikiFSTypes
├─ WikiFSMarkdown → WikiFSTypes + WikiFSLinks
├─ WikiFSSearch → WikiFSTypes
└─ WikiFSCore → all four (+ CSqliteVec)
```

**Gates:** `make version prompts` ✓; `swift build` clean ✓;
fast tier **2456 tests / 211 suites passed** ✓.

## Verification

Historical verification remains in the progress record above.
