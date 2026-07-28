---
timestamp: 2026-07-27T232841Z
title: "2026-07-27 — SourceVersionID separation (#955)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-27 — SourceVersionID separation (#955)

## Progress


**Scope.** This branch adds a public `SourceVersionID` namespace for
`source_versions.id` and `source_versions.parent_id`. `SourceID` stays the
source-entity identifier. `PageID` stays the markdown-version identifier for
`SourceMarkdownVersion.id` and `parentID`. Raw SQLite text, schema SQL,
`PRAGMA user_version`, and external raw-string contracts must stay unchanged.

**Documentation checkpoint.**
- Added [`plans/source-version-id-separation.md`](plans/source-version-id-separation.md)
  as the design and implementation record.
- Added the plan to `PLAN.md`.
- Extended `DocumentationContractTests` so the namespace boundary,
  no-migration rule, raw-boundary rule, `refs.version_id` polymorphism, and
  deferred markdown-version namespace cannot silently disappear.

**Documented decisions.**
- `SourceVersionID` is only for `source_versions.id` and `parent_id`.
- `SourceOrigin.versionID` and `SourceMarkdownVersion.sourceVersionID` will
  move to `SourceVersionID`.
- `SourceMarkdownVersion.id` and `parentID` stay `PageID` in this work.
- `refs.version_id` stays polymorphic by `RefKind`:
  `source-content` uses `SourceVersionID`, `source-derived` uses `PageID`, and
  page-content refs stay in the page-version namespace.
- `rollbackSourceContent(sourceID:to:)` will move to `SourceVersionID` and add
  a typed `sourceVersionNotFound` error.
- Live source-version creation paths to type are ordinary source ingest,
  byteless ingest, content append, and snapshot/image child creation.

**What landed.**
- Added `Sources/WikiFSTypes/SourceVersionID.swift` using the same nominal-ID
  pattern as `SourceID` and `ChatID`: raw storage stays a primitive string and
  `Codable` stays byte-for-byte compatible.
- Moved only the intended source-content-version surfaces to the new namespace:
  `SourceVersion.id` / `parentID`, `SourceOrigin.versionID`,
  `SourceMarkdownVersion.sourceVersionID`, the typed rollback API, and the
  markdown-extraction provenance seam.
- Kept the deferred boundaries intact: `SourceID` still names rows in
  `sources`, `SourceMarkdownVersion.id` / `parentID` stay `PageID`, and
  source-derived refs, pins, and set-active APIs stay on the markdown-version
  namespace.
- Updated GRDB decode/bind paths so every `source_versions` writer creates a
  `SourceVersionID` in memory but binds only `rawValue` to SQLite. This now
  covers ordinary ingest, byteless ingest, append, rollback/ref rewrites, and
  snapshot-image child creation.
- Added `WikiStoreError.sourceVersionNotFound(SourceVersionID)` and switched
  rollback failures to report the typed missing source-version namespace rather
  than a page/source identifier.

**External projection inventory.**
- Audited the real non-SQL surfaces that project source content-version ids.
  The only live app-layer raw-string projection is
  `SourceOrigin.provenanceEntry.versionID` for the provenance panel.
- No File Provider path, wiki-link syntax, CLI selector, or source-link pin API
  currently projects `source_versions.id` as its own external namespace, so no
  additional raw-output assertions were added for those boundaries.
- Added `SourceVersionProjectionTests` to pin the one real app projection that
  still intentionally escapes as raw text.

**Verification.**
- `make keychain` — regenerated the gitignored
  `Sources/WikiFSCore/GeneratedKeychain.swift` prerequisite for local SwiftPM
  builds.
- `make version` — regenerated the gitignored
  `Sources/WikiFSCore/GeneratedVersion.swift` prerequisite for local SwiftPM
  builds.
- `swift test --filter DocumentationContractTests` — 3 tests in 1 suite
  passed.
- Focused source-version boundary verification:
  `swift test --filter 'SourceVersionIDPersistenceTests|SourceVersionStoreTests|SourceVersionProjectionTests|SourceAPISignatureManifestTests|SourceVersionAPISignatureManifestTests|IdentifierBoundaryTypecheckTests|ProcessedMarkdownTests|StoreEmissionTests|BlobVacuumTests|SourceMaterializerTests|SourceRefreshTests|WebsiteSnapshotStoreTests'`
  — 98 tests in 10 suites passed on the final tree.
- `make prompts` — passed.
- `swift build --build-tests` — passed on the final tree.
- `swift test` — 2,552 tests in 201 suites passed on the final tree.
- `make lint` — 0 violations in 380 files; no new bare `try?`.
- `git diff --check` — clean.

## Verification

Historical verification remains in the progress record above.
