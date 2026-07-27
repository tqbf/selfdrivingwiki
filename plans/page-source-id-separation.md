# PageID and SourceID Type Separation

## Goal

Add `SourceID` for source entities. Keep `PageID` for page entities. The compiler must reject an attempt to use one identifier where the other is required.

This change does not change SQLite values, queue payload JSON, wiki-link syntax, File Provider identifiers, or other external string formats.

## Scope and constraints

`SourceID` is a `WikiFSTypes` leaf-module value type. It has the same `String` raw value as the legacy source-valued `PageID` instances.

Phase 1 must characterize the legacy JSON encoding before code defines `SourceID`. The observed encoding can be a primitive string or a keyed object. `SourceID` must preserve that exact normalized JSON shape.

Convert source entity models, store APIs, GRDB row decoding, queue and engine workflows, source UI state, render maps, File Provider projection code, and CLI source commands to `SourceID`.

Keep identifiers in their real namespaces. Do not convert chat IDs, source content-version IDs, or source Markdown-version IDs to `SourceID`. This change does not introduce `ChatID`, `SourceVersionID`, or `SourceMarkdownVersionID`.

When one field can carry page, source, or chat identity, use a namespaced enum. Replace the ambiguous bookmark target carrier with a tagged target type. Keep bookmark table columns. Convert between the tagged Swift value and `kind` plus raw target text at the store boundary.

This is a source-level type refactor. It does not require a SQLite schema migration or data rewrite. Persisted IDs remain the same ULID strings.

Primary touch points include:

- `Sources/WikiFSTypes/PageID.swift` and `Sources/WikiFSTypes/SourceID.swift`
- `Sources/WikiFSCore/Sources/SourceSummary.swift`
- `Sources/WikiFSCore/Sources/SourceVersioning.swift`
- `Sources/WikiFSCore/Sources/SourceMarkdownVersion.swift`
- `Sources/WikiFSCore/Store/WikiStore.swift`
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift`
- `Sources/WikiFSCore/Store/WikiStoreModel.swift`
- `Sources/WikiFSCore/Core/QueueTypes.swift`
- `Sources/WikiFSCore/Core/WikiSelection.swift`
- `Sources/WikiFSCore/Core/WikiRenderContext.swift`
- `Sources/WikiFSCore/Core/BookmarkNode.swift`
- Source code in `WikiFSEngine`, `WikiFSFileProvider`, `WikiCtlCore`, `wikid`, and `WikiFS`
- Affected Swift Testing suites in `Tests/WikiFSTests` and `Tests/WikiFSAppTests`

Do not change SQL column types, schema versions, table layouts, indexes, or foreign keys. Do not regenerate ULIDs or rewrite stored IDs. Do not change canonical links such as `[[source:<ULID>|Name]]`, File Provider item strings, staged filenames, CLI text, or agent-facing raw IDs. Do not add implicit `PageID` to `SourceID` conversion or cross-type equality.

## Documentation contract markers

Identifier boundary: `PageID` identifies pages. `SourceID` identifies source entities. A typed API must use the identifier for its entity.

No-migration decision: This refactor does not change the SQLite schema version or stored identifier text. Store code binds `rawValue` to the existing `TEXT` columns.

Raw-string boundaries: SQL bindings, primitive JSON fields, CLI arguments and output, File Provider identifiers and paths, staged filenames, agent manifests, and canonical wiki links remain raw strings at their external boundaries.

Deferred identifier work: `ChatID`, `SourceVersionID`, and `SourceMarkdownVersionID` remain deferred. Chat IDs and source version IDs must not become `SourceID` in this change.

## Implementation record

Phase 1 characterization found that a top-level legacy `PageID` encodes as a primitive JSON string. A queue payload with a source value uses `{"sourceIDs":["LEGACY-SOURCE-ID"]}` after JSON normalization. `SourceID` must retain this encoding.

The implementation keeps page, source, chat, and version namespaces distinct. `BookmarkNode.Content` carries a tagged page, source, chat, or folder value. The store maps that value to the existing `kind`, `label`, and `target_id` columns.

The active test sources record the identifier characterization contract. The recorded command evidence is `swift test --filter DocumentationContractTests`, which passed with one test. The final SwiftPM build, complete test suite, lint, and diff checks remain release gates for this branch.

## Implementation plan

### Phase 1: Characterize the wire format and add `SourceID`

1. Before defining `SourceID`, characterize synthesized `PageID` encoding with the `JSONEncoder` and `JSONDecoder` that `QueueStore` uses.
2. Record the top-level encoded `PageID` shape.
3. Record the exact normalized JSON object for a pre-refactor `QueueItemPayload` with source IDs.
4. Insert that literal payload into a queue database fixture. Prove that the current decoder reads it.
5. Treat the fixture as the compatibility contract. Do not assume `RawRepresentable` encodes as one JSON string. `PageID` has synthesized `Codable` and can encode as an object with `rawValue`.
6. Add `SourceID` as `Hashable`, `RawRepresentable`, `Sendable`, and `Identifiable`.
7. Implement or synthesize `Codable` so `SourceID` matches the characterized representation exactly.
8. If production data has more than one observed historical shape, add tolerant decoding for every observed form. Document one canonical encoding.
9. Keep `PageID` documented as a page identifier. Remove source-oriented justification from `SourceSummary`.
10. Add `PageIDLegacyCodableCharacterizationTests.pageIDTopLevelShape`, `PageIDLegacyCodableCharacterizationTests.queuePayloadSourceIDShape`, `SourceIDTests.sourceIDMatchesLegacySourceValueShape`, `SourceIDTests.sourceIDPreservesRawValue`, and `QueueStoreTests.preRefactorPayloadFixtureDecodes`.
11. Compare normalized JSON objects. Compare exact bytes only when encoder configuration and key ordering make bytes contractual.
12. Do not add conversion initializers between identifier types. Boundary code constructs the correct type from raw text.

### Phase 2: Convert source models and store contracts

1. Use `SourceID` for `SourceSummary.id`, `SourceVersion.sourceID`, `SourceMarkdownVersion.sourceID`, `PageSourceLink.sourceID`, `SourceEmbedDescriptor.id`, and other source-row descriptors.
2. Keep `PageSourceLink.pageID` as `PageID`.
3. Keep `SourceVersion.id`, `SourceVersion.parentID`, `SourceMarkdownVersion.id`, and `SourceMarkdownVersion.parentID` in their current version-ID namespaces.
4. Change every source-specific `WikiStore` requirement to accept or return `SourceID`. This includes source resolution, content, deletion, provenance, versioning, extraction, search, links, sibling source, and bookmark-reference operations.
5. Keep page methods on `PageID` and chat methods unchanged.
6. Replace an ambiguous `WikiStoreError.notFound(PageID)` with tagged errors such as `pageNotFound(PageID)` and `sourceNotFound(SourceID)` if sources use it. Update throw sites and tests.
7. Update all conforming stores and test doubles in this phase so the protocol builds.

### Phase 3: Update GRDB boundaries without migration

1. Change source-facing GRDB signatures and local values to `SourceID`.
2. Decode `sources.id`, `source_versions.source_id`, `source_markdown_versions.file_id`, `source_links.to_source_id`, `source_search.source_id`, and source-owned references with `SourceID(rawValue:)`.
3. Bind `sourceID.rawValue` into existing `TEXT` columns.
4. Keep page columns decoded as `PageID`. Keep version columns in their existing namespaces.
5. Audit source-summary, source-version, Markdown-version, embed-descriptor, and page-source-link constructors. Do not make a broad replacement of `PageID(rawValue:)`.
6. Add fixture tests that load existing raw source rows as `SourceID` and write the exact raw identifier text.
7. Run `StoreEmissionTests`, `StoreEmissionReentrancyTests`, and `GRDBEmissionReentrancyTests`. Add explicit source and bookmark mutation events for changed public mutators. Do not rely on an absent `StoreEmissionExhaustivenessTests` symbol.

### Phase 4: Type queue, engine, daemon, and staging flows

1. Change `QueueItemPayload.sourceIDs` from `[PageID]` to `[SourceID]`. Keep `lintPageIDs` and page collections as `PageID`.
2. Update queue ingestion, extraction, transcription, reconciliation, event envelopes, and activity tracking to use `[SourceID]` and `Set<SourceID>`.
3. Update engine requests, providers, workers, launcher inputs, daemon request handling, and app queue adapters that carry source entity IDs.
4. Update `AgentStaging`, filename helpers, operation requests, and source materialization.
5. Convert to raw strings only at SQL, JSON string contracts, CLI input/output, File Provider identifiers and paths, staged filenames, and agent-facing manifests.
6. Add a literal pre-refactor `QueueItemPayload` fixture using the Phase 1 shape. Decode it as `[SourceID]` and re-encode it to the same normalized object.
7. Add `QueueRestartTests.legacySourcePayloadRecoversAsSourceID` and `QueueEventEnvelopeTests.sourceIDJSONContractIsUnchanged` from literal persisted JSON.
8. Verify queue persistence, restart recovery, event transport, extraction, transcription, ingestion, and lint isolation.

### Phase 5: Convert model, render, navigation, and source UI state

1. Update `WikiStoreModel` source catalogs, lookups, source actions, callbacks, and caches to use `SourceID`.
2. Change `WikiSelection.source(PageID)` to `WikiSelection.source(SourceID)`. Keep `.page(PageID)` and `.chat(PageID)` unchanged.
3. Use `SourceID` keys for `WikiRenderContext.sourceIDToName`, the outer keys of `sourceDerivedChain`, and source keys and sibling-source values in `siblingMaps`.
4. Keep version values in their current namespace.
5. Use `SourceID` for display-name, embed, and pinned-extraction inputs that identify a source entity.
6. Update source routes, reader state, source-detail state, source-list selection, extraction sheets, open, reveal, share, and queue activity views.
7. Update AppKit callback structures in `SourcesListView` so a source selection cannot reach page APIs.
8. Update omnibox, address bar, drag payload, and wiki-link routing. Keep raw ULID URL and drag representations unchanged.
9. Consult `swiftui-pro` before and after UI work. Filter its advice for macOS 15 and Swift 6.0. Preserve SwiftUI and `NSViewRepresentable` state-update discipline. This is not a visual redesign.
10. Run source reader, routing, selection, hosted-view, extraction, and queue activity tests.

### Phase 6: Replace ambiguous bookmark state

1. Replace independent mutable `BookmarkNode.kind`, `label`, and `targetID` with `BookmarkNode.Content`.
2. Model content as `.folder(label: String)`, `.page(PageID)`, `.source(SourceID)`, and `.chat(PageID)`.
3. Derive `BookmarkNodeKind`, optional label, and raw target text as computed persistence projections. Do not retain independently settable typed target state.
4. Keep `bookmark_nodes.kind`, `label`, and `target_id`. Decode `Content` by validating the whole row tuple.
5. Add `WikiStoreError.invalidBookmarkRow(id:reason:)` or an equivalent concrete error.
6. A folder requires a non-empty label and a null target. A page, source, or chat reference requires a null label and a non-null target. Unknown kinds and every other tuple are invalid.
7. Throw for unknown kinds, missing or empty folder labels, folders with targets, reference labels, and missing reference targets.
8. Remove the fallback that converts unknown kinds to `.folder`.
9. Encode valid enum cases into the same existing kind value, label, and target text. Do not migrate the schema or stored values.
10. Make bookmark creation accept `BookmarkNode.Content`, or provide typed convenience methods for page, source, and chat targets.
11. Keep any raw persistence initializer internal and throwing.
12. Update bookmark trees, pickers, drag and drop, context menus, snapshots, and restoration to switch on `Content`.
13. Add raw SQL fixtures for every invalid tuple. Add valid page, source, chat, and folder round trips that compare exact stored columns.

### Phase 7: Convert File Provider, CLI, links, and final boundaries

1. Change File Provider source projections and lookup helpers to `SourceID` internally.
2. Preserve item identifiers, projected paths, `sources.jsonl`, and canonical wiki links as raw strings.
3. Make CLI source commands construct `SourceID` at argument parsing. Page commands construct `PageID`.
4. Update link canonicalization, rendering, rewriting, and indexing APIs where source entity IDs cross module boundaries.
5. Keep intentionally neutral cross-kind index rows as raw strings. Convert only in typed source adapters.
6. Search Swift sources and tests for `PageID` near source terminology. Classify every remaining use as a true page ID, source-version or Markdown-version ID, chat ID, raw boundary, or unresolved source entity ID.
7. Add positive type-check fixtures for correct page and source calls. Add negative fixtures that exchange types. A test script or Swift Testing wrapper must run `swiftc -typecheck` using built module search paths. Positive fixtures pass. Negative fixtures fail with the expected type-mismatch diagnostic.
8. Add a source-API signature manifest for public source properties and methods that must use `SourceID`. Check it from a test or script. Do not use proximity regex or an allowlist of all `PageID` matches.
9. Keep a reviewed audit list for intentional `PageID` in source-related files. Use `rg` as a final human audit only.

### Phase 8: Documentation, review, and final verification

1. Keep this document as the design and implementation record. Explain namespaces, unchanged persistence formats, changed APIs, and deferred identifier types.
2. Add this document to `PLAN.md`.
3. Record phases, decisions, and exact verification results in `PROGRESS.md`.
4. Use STE-flavored prose for the plan, progress entry, and pull request text.
5. After automated tests pass, run the repository review process. If no repository guidance exists, use a general-purpose reviewer.
6. Fix or explicitly rebut every review finding. Repeat review after a critical finding until no critical finding remains.
7. Work on a feature branch. Push it and open a pull request. Never merge it to `main`.

## Acceptance criteria and verification

| Criterion | Required proof |
| --- | --- |
| AC.1 | `SourceID` is public in `WikiFSTypes`, has the legacy raw string and JSON shape. Test `PageIDLegacyCodableCharacterizationTests` and `SourceIDTests`. |
| AC.2 | Source APIs use `SourceID`, page APIs use `PageID`, and type-check fixtures reject exchanged identifiers. |
| AC.3 | Existing source rows load with no migration and writes preserve raw text. Test `SourceIDPersistenceTests`. |
| AC.4 | `PageSourceLink.pageID` is `PageID` and `.sourceID` is `SourceID`. Test `WikiLinkStoreTests.pageSourceLinkRoundTripKeepsTypedDirection`. |
| AC.5 | Legacy queue payloads decode and re-encode with the same normalized JSON object. Test queue store and restart fixtures. |
| AC.6 | Extraction, transcription, ingestion, restart reconciliation, staging, and activity tracking retain `SourceID` internally. |
| AC.7 | `WikiSelection.source` carries `SourceID`. Sidebar, tab, reader, omnibox, and background navigation retain resource identity. |
| AC.8 | Source-keyed render maps use `SourceID`, while version IDs remain separate. Test render, pinning, transclusion, and sibling resolution. |
| AC.9 | Tagged bookmark targets round trip through existing columns. Invalid raw tuples fail. |
| AC.10 | File Provider, filenames, indexes, links, CLI, and staging raw contracts remain unchanged. |
| AC.11 | `make prompts`, `swift build --build-tests`, focused suites, `swift test`, lint, and `git diff --check` pass under SwiftPM. |
| AC.12 | Documentation covers the boundary, no-migration decision, raw boundaries, and deferred IDs. `DocumentationContractTests` checks it. |
| AC.13 | The signature manifest passes. The final `rg -n 'PageID' Sources Tests` audit classifies remaining source-related cases. |

Required named coverage also includes `QueueExtractionTests.sourceIDReachesExtractionProvider`, `QueueTranscriptionTests.sourceIDReachesTranscriptionProvider`, `QueueIngestionTests.sourceIDsReachIngestionProvider`, `QueueActivityTrackerReconcileTests.sourceIDSetsReconcileAfterRestart`, `AgentStagingTests.sourceIDFilenameContractIsUnchanged`, `WikiSelectionTests.sourceSelectionRetainsSourceID`, `WikiReaderRoutingTests.sourceULIDRouteOpensSource`, `EditorTabTests.sourceSelectionRestoresCorrectTab`, `OmniboxResultTests.sourceResultOpensSourceSelection`, `WikiRenderContextTests.sourceMapsUseSourceID`, `Phase6PinningPureTests.sourceIDAndPinnedVersionRemainDistinct`, `TransclusionEmbedTests.sourceEmbedResolvesBySourceID`, and `SiblingResolutionRenderTests.sourceIDSiblingImageProjectionResolves`.

`BookmarkNodeStoreTests` must cover valid page, source, chat, and folder targets. It must also cover unknown kind, missing label, empty label, folder target, reference label, and missing reference target rows. `ProjectionTreeTests`, `WikiCtlCommandTests`, `WikiLinkCanonicalizerTests`, `FilenameEscapingTests`, and `IndexGeneratorTests` must assert unchanged raw source contracts.

Run verification in this order:

1. `make prompts`
2. `swift test --filter SourceIDTests`
3. `swift test --filter SourceIDPersistenceTests`
4. `swift test --filter 'WikiLinkStoreTests|Phase6PinningPureTests|Phase6PinningStoreTests|WikiRenderContextTests'`
5. `swift test --filter 'QueueStoreTests|QueueEventEnvelopeTests|QueueExtractionTests|QueueTranscriptionTests|QueueIngestionTests|QueueActivityTrackerReconcileTests'`
6. `swift test --filter 'BookmarkNodeStoreTests|BookmarkCommandTests|BookmarkTreeBuilderTests|BookmarkStateSnapshotTests|SidebarDragPayloadTests'`
7. `swift test --filter 'ProjectionTests|WikiReaderRoutingTests|SourcesTests|SourcesListContentGatesTests|WikiCtlCommandTests'`
8. `swift build --build-tests`
9. `swift test`
10. `make lint`
11. `git diff --check`

Mutation testing is optional because this refactor changes nominal types more than runtime logic. Run scoped mutation testing for bookmark validation when practical.

## Review strategy

Before execution handoff, run `plan-reviewer` against this plan. Fix critical and high findings, or record a specific rebuttal. Run another review after each critical or high correction.

During implementation, consult `swiftui-pro` before and after source UI and navigation conversion. Keep all code compatible with macOS 15, Swift 6.0, and command-line SwiftPM builds.

After implementation and automated verification, review the full diff for source entity IDs that remain `PageID`, version IDs accidentally changed to `SourceID`, altered JSON or SQL contracts, altered File Provider, CLI, or link formats, ambiguous bookmark reconstruction, bare `try?`, incorrect logging, missing store emissions, and fixtures that omit legacy data. Fix or explicitly rebut all findings. Repeat after critical findings until none remain.

## Documentation strategy

This document must record the old shared `PageID` problem, the new namespaces, invalid compile-time calls, intentionally mixed tagged enums, unchanged SQLite and JSON, raw-string boundaries, the rule for source version IDs, deferred `ChatID`, `SourceVersionID`, and `SourceMarkdownVersionID` work, and final verification evidence.

Add this document to `PLAN.md`. Add phase progress and test results to `PROGRESS.md`. Do not change user-facing documentation because visible behavior and external formats do not change.

## Risks, blockers, and decisions

- Source-related files contain both source entity IDs and version IDs. Convert by model and SQL-column meaning. Do not use a broad replacement.
- Bookmark rows require tagged reconstruction because `target_id` depends on `kind`. Preserve the two-column storage contract and reject invalid combinations.
- The legacy source-ID JSON shape is unknown until Phase 1. Capture literal normalized fixtures before implementation.
- This feature changes public APIs in many modules. Keep each phase internally buildable where possible.
- Closures, generic dictionaries, AppKit callbacks, drag payloads, and neutral index rows can hide source IDs. Use compiler errors and the final audit.
- Split ambiguous errors instead of rebuilding a `SourceID` as `PageID` merely for reporting.
- No database migration should occur because the schema already separates page and source columns.
- Existing Swift Testing fixtures cover persistence, queue JSON, bookmarks, File Provider projections, and SwiftPM verification. Extend those mechanisms.

## Delivery requirements

Run all commands from the repository root. Use SwiftPM only. Test every new function, method, code path, bookmark validation branch, and compatibility decoder path.

Use `DebugLog` for diagnostics. Do not add `print` or bare `try?`. Write scratch files only in project-relative `tmp/`.

If a compile or design problem blocks work for more than 10 minutes, commit the current work with a `// STUCK: <description>` comment, push, notify the operator, and stop.

Push the feature branch and open a pull request. Do not merge it. After opening the pull request, run `polytoken-notify 'PR #N opened for PageID and SourceID separation, CI running'`. If blocked, run `polytoken-notify 'STUCK on PageID and SourceID separation: <description>'`.

## Final verification evidence

- `make prompts` passed.
- `swift build --build-tests` passed.
- The focused acceptance run passed 458 tests in 25 suites.
- The real-API positive and negative compiler fixtures and source API
  signature manifest passed 4 tests in 2 suites.
- `swift test` passed 2,505 tests in 193 suites.
- `make lint` reported 0 violations in 378 files and no new bare `try?`.
- `git diff --check` passed.
- The final review found no critical or high issues. It found no schema or raw
  format drift, invalid bookmark reconstruction, missing mutation emissions,
  source-version or chat-ID conversion, or remaining source entity typed as
  `PageID`.
