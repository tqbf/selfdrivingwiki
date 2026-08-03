---
timestamp: 2026-07-28T023718Z
title: "2026-07-28 — SourceMarkdownVersionID separation (#956)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-28 — SourceMarkdownVersionID separation (#956)

## Progress


**Scope.** This branch adds a public `SourceMarkdownVersionID` namespace for
`source_markdown_versions.id` and `source_markdown_versions.parent_id`. It also
types `source-derived` refs and `source_links.pinned_version_id` in Swift while
preserving SQLite schema/text, `PRAGMA user_version`, queue JSON, File Provider
identifiers, wiki-link `@vN`, CLI text, and staged or agent-facing raw-string
contracts.

**Documentation checkpoint.**
- Added [`plans/source-markdown-version-id-separation.md`](plans/source-markdown-version-id-separation.md)
  as the design and implementation record.
- Added the plan to `PLAN.md`.
- Extended `DocumentationContractTests` so the markdown-version namespace,
  no-migration rule, raw-string boundaries, `source-derived` / source-link-pin
  typing, and recorded verification evidence cannot silently disappear.

**What landed so far.**
- Added `Sources/WikiFSTypes/SourceMarkdownVersionID.swift` as the public
  markdown-version namespace with primitive-string `Codable` compatibility.
- Converted core production seams to `SourceMarkdownVersionID`, including
  `SourceMarkdownVersion.id` / `parentID`, `ExtractionAlternative.id`,
  `WikiStore` / `GRDBWikiStore` / `WikiStoreModel` processed-markdown APIs,
  `WikiRenderContext.sourceDerivedChain`, pending pinned extraction, CLI
  `source set-active`, and source-link pin reads.
- Added structural guardrails:
  `SourceMarkdownVersionAPISignatureManifestTests`,
  `SourceMarkdownVersionIDPersistenceTests`, and expanded
  `IdentifierBoundaryTypecheckTests` coverage for rejected page/source/chat/
  source-version calls into markdown-version APIs.
- Added store-level error coverage proving unknown markdown-version targets
  throw `sourceMarkdownVersionNotFound(SourceMarkdownVersionID)` while missing
  pages still throw `notFound(PageID)`.
- Expanded the reviewed boundary coverage so the load-bearing seams are now
  explicit and executable: the markdown-version signature manifest includes the
  compare/history/nomination/render adapters; queue JSON and agent manifests
  prove they intentionally carry no markdown-version field; File Provider item
  identifiers and parents stay exact raw strings; pinned wiki-link text,
  transclusion pin routing, CLI `source set-active` text, and source-scoped
  store emissions are each pinned by named tests.
- PR #962 Paseo audit follow-up at commit `f8c8ceb` is now fixed on this
  branch:
  the markdown-version API manifest explicitly enumerates every active
  processed-markdown HEAD seam (`WikiStore.processedMarkdownHead(sourceID:)`,
  GRDB public/private HEAD readers, `processedMarkdownHeadsBySource()`, and
  `WikiStoreModel.processedMarkdownHead(for:)`), with a dedicated guard that
  fails if any of those keys drop out of either the expected set or the fixture.
- Added recorder-based `StoreEmissionTests` coverage for the unknown-target
  markdown mutators. `revertProcessedMarkdown(sourceID:to:)` and
  `setActiveMarkdown(sourceID:to:)` with unknown `SourceMarkdownVersionID`
  values now prove all three required postconditions together: the call throws
  `WikiStoreError.sourceMarkdownVersionNotFound`, emits no
  `ResourceChangeEvent`, and leaves the prior active HEAD unchanged in both the
  direct head read and the batch HEAD projection.

**Verification.**
- Final manifest follow-up for the exact-head Paseo audit of PR #962 at commit
  `091caae`:
  added the remaining live processed-markdown HEAD consumers to
  `SourceMarkdownVersionAPISignatures.txt`,
  `SourceMarkdownVersionAPISignatureManifestTests.expectedEntryKeys`, and a
  dedicated active-HEAD consumer guard without weakening the manifest or the
  earlier audit-fix claims. The newly enumerated surfaces are the two
  `WikiCtlCore/SourceCommand.swift` `--markdown` HEAD reads (`cat` / `export`),
  both live `WikiFSFileProvider/Projection.swift`
  `processedMarkdownHeadsBySource()` batched reads (`cachedHeadsBySource()` and
  `makeLinkMaps()`), and
  `wikid/DaemonQueueIngestionProvider.swift`'s ingest staging HEAD read.
- `make keychain` — passed.
- `make version` — passed.
- Focused core boundary verification:
  `swift test --filter 'SourceMarkdownVersionAPISignatureManifestTests|QueueEventEnvelopeTests|QueueRestartTests|WikiCtlCommandTests|Phase6PinningPureTests|ModelsConfigRecordTests'`
  — 153 tests in 6 suites passed.
- Focused app-side boundary verification:
  `WIKIFS_APP_TESTS=1 swift test --filter 'ProjectionTests|ProcessedMarkdownTests|TransclusionEmbedTests'`
  — 96 tests in 6 suites passed.
- Focused emission verification:
  `swift test --filter 'StoreEmissionTests'`
  — 37 tests in 1 suite passed.
- Handoff verification before recovery:
  `make prompts`
  `swift build --build-tests`
  — both passed in the prior fix-agent session for this same worktree.
- Final recovery verification on the current tree:
  `swift test`
  — 2,579 tests in 204 suites passed.
  `make lint`
  — passed with 0 violations in 381 files.
  `git diff --check`
  — clean.
- Paseo audit fix verification on Tuesday, July 28, 2026:
  `swift test --filter 'SourceMarkdownVersionAPISignatureManifestTests|Phase6PinningStoreTests|StoreEmissionTests'`
  — 52 tests in 3 suites passed.
  `make prompts`
  — passed.
  `swift build --build-tests`
  — passed.
  `swift test`
  — started and ran past the requested 10-minute allowance, then was confirmed
  blocked in `swiftpm-testing-helper` (PID 92754, `STAT S`, `0.0%` CPU) with
  no further output; interrupted after notifying the blocker.
  `make lint`
  — passed with 0 violations in 381 files.
  `git diff --check`
  — clean.
- Final manifest-only follow-up verification on Tuesday, July 28, 2026:
  `swift test --filter SourceMarkdownVersionAPISignatureManifestTests`
  — 2 tests in 1 suite passed.
  `swift build --build-tests`
  — passed.
  `swift test --filter WikiCtlCommandTests`
  — 115 tests in 1 suite passed.
  `WIKIFS_APP_TESTS=1 swift test --filter ProjectionTests`
  — 13 tests in 2 suites passed.
  `git diff --check`
  — clean.

## Verification

Historical verification remains in the progress record above.
