# SourceVersionID Separation

## Goal

Add `SourceVersionID` for `source_versions.id` and `source_versions.parent_id`.
Keep `SourceID` for `sources.id`. Keep `PageID` for
`SourceMarkdownVersion.id`, `SourceMarkdownVersion.parentID`, and every
source-derived ref, pin, and set-active API that targets
`source_markdown_versions.id`.

This change must tighten the Swift type boundary only. It must not change
SQLite schema text, migration SQL, `PRAGMA user_version`, stored ULID text,
CLI-visible raw IDs, or any other external raw-string contract.

## Scope and constraints

`SourceVersionID` is a `WikiFSTypes` leaf value type. Follow the same nominal
pattern as `SourceID` and `ChatID`: `Hashable`, `Codable`, `RawRepresentable`,
`Sendable`, and `Identifiable`, backed by the legacy raw `String`.

This work changes only the source content-version namespace:

- `SourceVersion.id`
- `SourceVersion.parentID`
- `SourceOrigin.versionID`
- `SourceMarkdownVersion.sourceVersionID`
- `rollbackSourceContent`
- `recordMarkdownExtraction` provenance threading
- active/history/append helpers for `source_versions`
- GRDB helpers that read or bind `source_versions.id`

This work must not change these namespaces:

- `SourceID` for `sources.id`, `source_links`, source search rows, queue
  source payloads, and all source-entity APIs
- `PageID` for `SourceMarkdownVersion.id`, `SourceMarkdownVersion.parentID`,
  `setActiveMarkdown`, extraction pinning, and source-derived refs
- `PageID` for page versions already in the page domain
- `ChatID` for persisted chats

This is a source-level type refactor. Keep the database schema, migration
ladder, and stored raw text unchanged.

## Documentation contract markers

Identifier boundary:
`SourceVersionID` identifies rows in `source_versions`. `SourceID` identifies
rows in `sources`. `PageID` still identifies `source_markdown_versions.id`
because markdown-version namespace separation is deferred.

No-migration decision:
Do not change schema SQL, migration bodies, table layouts, indexes, foreign
keys, or `PRAGMA user_version`. Bind only `rawValue` into the existing `TEXT`
columns.

Raw-string boundaries:
Keep SQLite row text, CLI text, daemon/app payload text, provenance strings,
and any existing external projection raw-string-compatible. Add raw-output
tests only where a real external boundary exists.

Ref polymorphism:
`refs.version_id` stays polymorphic by `RefKind`. Treat
`RefKind.sourceContent` as `SourceVersionID`, `RefKind.sourceDerived` as
`PageID`, and `RefKind.pageContent` as the page-version namespace. Do not add
an FK or a one-type wrapper for the whole column.

Deferred markdown-version namespace:
Do not introduce a new `SourceMarkdownVersionID` in this work.
`SourceMarkdownVersion.id` and `parentID` stay `PageID`, and APIs that target
markdown alternatives or pins stay on `PageID`.

## Namespace boundaries

### `SourceVersionID`

Use `SourceVersionID` for values that semantically identify a content-version
row in `source_versions`:

- `SourceVersion.id`
- `SourceVersion.parentID`
- `SourceOrigin.versionID`
- `SourceMarkdownVersion.sourceVersionID`
- `WikiStoreError.sourceVersionNotFound(SourceVersionID)`
- `activeContentVersion(sourceID:)` return payloads
- `contentVersionHistory(sourceID:)` return payloads
- `appendContentVersion(...)` return payloads
- `rollbackSourceContent(sourceID:to:)`
- `recordMarkdownExtraction(..., sourceVersionID:)`
- source-version GRDB readers and local helpers

### `SourceID`

Keep `SourceID` for source entities and source-owned collections:

- `sources.id`
- `SourceSummary.id`
- `SourceVersion.sourceID`
- `SourceMarkdownVersion.sourceID`
- source list, queue, render-map, bookmark, CLI source selector, and File
  Provider source APIs

### `PageID`

Keep `PageID` for markdown-version and pin/reference APIs:

- `SourceMarkdownVersion.id`
- `SourceMarkdownVersion.parentID`
- `setActiveMarkdown(sourceID:to:)`
- `revertProcessedMarkdown(sourceID:to:)`
- pinned extraction IDs
- `source-derived` ref targets

## Actual compatibility boundaries to preserve

The work must preserve these observed raw boundaries:

- SQLite rows in `source_versions`, `source_markdown_versions`, and `refs`
- `WikiStoreError` text that interpolates the same raw ID
- CLI text that prints source version IDs when a real command exposes them
- provenance/read-side value types that surface version IDs to app and CLI code
- tests that seed literal pre-change rows and read them through the real store

The inventory must stay precise. If a surface does not expose source content
version IDs today, do not invent a new raw-output assertion for it.

## Live creation paths that must become typed

Every live `source_versions` creation path must construct `SourceVersionID`
internally and bind only `rawValue`:

1. Ordinary source ingest in `addSource`
2. Byteless source ingest in `addBytelessSource`
3. Content append in `appendContentVersion`
4. Website snapshot/image child creation (`addSnapshotImage` and related child
   source paths)

Every read path that returns or threads a `source_versions.id` must decode it
as `SourceVersionID`.

## `refs.version_id` rule

`refs.version_id` is intentionally polymorphic. The type rule is:

- `source-content` ref target → `SourceVersionID`
- `source-derived` ref target → `PageID`
- `page-content` ref target → page-version namespace

Do not erase that distinction with `String` in internal APIs once `kind` is
known. Convert at the branch where `kind` disambiguates the namespace.

## Error surface

Add `WikiStoreError.sourceVersionNotFound(SourceVersionID)`.

Use it where a missing `source_versions` row is the real failure, especially
`rollbackSourceContent(sourceID:to:)`. Do not rebuild a `PageID` or use a
generic not-found case for a source content version.

Keep existing page and chat not-found cases unchanged.

## Implementation plan

### Phase 1: Add the nominal type and document the boundary

1. Add `Sources/WikiFSTypes/SourceVersionID.swift`.
2. Match the `SourceID` and `ChatID` nominal pattern exactly.
3. Add raw-value, identity, hash, and `Codable` tests.
4. Extend `DocumentationContractTests` for this plan.
5. Record the first-commit evidence in `PROGRESS.md`.

### Phase 2: Convert source content-version models

1. Change `SourceVersion.id` and `parentID` to `SourceVersionID`.
2. Change `SourceOrigin.versionID` to `SourceVersionID`.
3. Change `SourceMarkdownVersion.sourceVersionID` to `SourceVersionID?`.
4. Keep `SourceMarkdownVersion.id` and `parentID` on `PageID`.
5. Update initializers, equality, and hash usage.

### Phase 3: Convert store and GRDB helpers

1. Change public source-content-version APIs to use `SourceVersionID`.
2. Change private GRDB helpers that read or validate `source_versions.id`.
3. Bind only `rawValue` into SQL arguments.
4. Keep schema SQL and `schemaVersion` unchanged.
5. Add literal pre-change SQLite fixtures that prove schema and raw-row
   compatibility.

### Phase 4: Thread provenance and rollback correctly

1. Change `recordMarkdownExtraction(..., sourceVersionID:)` to use
   `SourceVersionID?`.
2. Resolve the fallback active content version as `SourceVersionID`.
3. Change `rollbackSourceContent(sourceID:to:)` to accept `SourceVersionID`.
4. Keep `revertProcessedMarkdown` and `setActiveMarkdown` on `PageID`.
5. Add tests for rollback ownership, missing-version error, lineage, and
   mutation emission.

### Phase 5: Audit mixed carriers and external projections

1. Audit every `versionID` in source-related code by semantic owner.
2. Treat `refs.version_id` by `RefKind`, not by column name alone.
3. Keep real raw-output tests only for real external boundaries.
4. Add compiler fixtures that reject `SourceID`, `PageID`, and
   `SourceMarkdownVersion.id` at rollback and reject inverse misuse of
   `SourceVersionID`.

## Acceptance criteria

- `SourceVersionID` exists in `WikiFSTypes` and preserves the raw string and
  `Codable` shape.
- `SourceVersion.id` and `parentID` use `SourceVersionID`.
- `SourceOrigin.versionID` and `SourceMarkdownVersion.sourceVersionID` use
  `SourceVersionID`.
- `rollbackSourceContent(sourceID:to:)` accepts `SourceVersionID`.
- `recordMarkdownExtraction(..., sourceVersionID:)` accepts `SourceVersionID?`.
- Live source-version creation paths type the new IDs before SQL bind.
- Literal pre-change SQLite fixtures still decode with unchanged raw schema and
  row text.
- `refs.version_id` stays polymorphic by `RefKind`.
- Markdown-version APIs still use `PageID`.
- The API signature manifest and compiler fixtures enforce the split.

## Required tests

Add or extend tests for:

- `SourceVersionID` raw value, identity, hash, and `Codable`
- literal pre-change DB compatibility, including raw schema, row text, ref
  rows, and provenance compatibility
- all live source-version creation paths: ordinary, byteless, append, and
  snapshot/image child
- append lineage, active ref resolution, `MAX(id)` fallback, and history
- rollback ownership, missing-version error, and mutation emission
- source origin and markdown-extraction provenance threading
- separate historical-retention tests for `vacuumBlobs` and
  `vacuumActivities`
- `SourceVersionAPISignatures.txt` and real-module compiler fixtures

Compiler fixtures must reject:

- `SourceID` where `SourceVersionID` is required
- `PageID` where `SourceVersionID` is required
- `SourceMarkdownVersion.id` at source-content rollback
- inverse misuse of `SourceVersionID` at source-entity or markdown-version APIs

## Verification order

1. `make prompts`
2. Focused `SourceVersionID` and documentation suites
3. Focused persistence, GRDB, provenance, rollback, and vacuum suites
4. `swift build --build-tests`
5. `swift test`
6. `make lint`
7. `git diff --check`

## Risks and decisions

- Source-related code contains both source-entity IDs and source-version IDs.
  Convert by semantic owner, not by file name.
- `SourceMarkdownVersion.sourceVersionID` points into `source_versions`, but
  `SourceMarkdownVersion.id` does not. The split must keep that asymmetry.
- `refs.version_id` is intentionally polymorphic. A one-type wrapper for the
  whole column would be wrong.
- External raw-output tests must follow real boundaries only. Do not add fake
  compatibility tests for surfaces that do not serialize source content-version
  IDs today.
- Markdown-version namespace separation is deferred on purpose. This plan must
  document that deferral clearly so later work does not treat it as an
  accident.
