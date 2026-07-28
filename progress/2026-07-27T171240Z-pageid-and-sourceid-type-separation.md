---
timestamp: 2026-07-27T171240Z
title: "2026-07-27 — PageID and SourceID type separation"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-27 — PageID and SourceID type separation

## Progress


**Scope.** This branch separates page and source entity identifiers in Swift.
`PageID` remains the page identifier. `SourceID` becomes the source entity
identifier. This type change must not change external identifier text.

**Compatibility record.** The Phase 1 characterization test records a primitive
JSON string for a legacy top-level `PageID`. The normalized queue source field
is `{"sourceIDs":["LEGACY-SOURCE-ID"]}`. `SourceID` uses that same shape.

**Persistence and boundaries.** The SQLite schema version and stored identifier
text remain unchanged. SQL, JSON string fields, CLI text, File Provider item
identifiers, paths, staged filenames, agent manifests, and wiki links stay raw
strings at their boundaries.

**Namespace rule.** Page, source, chat, and version identifiers remain separate.
This change defers `ChatID`, `SourceVersionID`, and
`SourceMarkdownVersionID`. A bookmark uses tagged content to carry a page,
source, chat, or folder value.

**Verification.**
- `make prompts` — passed.
- `swift build --build-tests` — passed.
- Focused acceptance run — 458 tests in 25 suites passed.
- Real-API identifier compiler fixtures and the source API signature manifest —
  4 tests in 2 suites passed.
- `swift test` — 2,505 tests in 193 suites passed on the final tree.
- `make lint` — 0 violations in 378 files; no new bare `try?`.
- `git diff --check` — clean.
- Three implementation review passes completed. The final pass found no
  critical or high issues and confirmed no schema, raw-format, bookmark,
  emission, logging, version-ID, chat-ID, or source-entity type leak.

## Verification

Historical verification remains in the progress record above.
