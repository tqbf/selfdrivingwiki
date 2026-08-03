# Source Markdown Version ID Separation

Issue: #956

## Goal

Add `SourceMarkdownVersionID` for `source_markdown_versions.id` and `source_markdown_versions.parent_id`. Enforce this namespace across extraction, history, pinning, rendering, compare, nomination, and rollback APIs without changing stored or external strings.

## Boundary Record

### Identifier boundary:

- `SourceID` names `sources.id` and `source_markdown_versions.file_id`.
- `SourceVersionID` names `source_versions.id`, `source_versions.parent_id`, and `source_markdown_versions.source_version_id`.
- `SourceMarkdownVersionID` names `source_markdown_versions.id`, `source_markdown_versions.parent_id`, `refs.version_id` when `kind = 'source-derived'`, and `source_links.pinned_version_id`.
- `PageID` remains the page identifier. Chat and page-content version namespaces are unchanged in this work.

### No-migration decision:

This issue is a Swift namespace correction only. It must not alter SQLite
tables, columns, indexes, foreign keys, `PRAGMA user_version`, stored ULID
text, or any existing raw-string contract at a persistence or external
boundary.

### Raw-string boundaries:

Queue payload JSON and agent-facing manifests intentionally carry no
Markdown-version identifier field; their existing raw `sourceIDs`-only shape
stays unchanged. File Provider identifiers and paths, wiki-link `@vN` syntax,
CLI input and output, and staged filenames stay raw strings at their
boundaries. The nominal type is constructed only inside typed Swift APIs.

### Polymorphic refs and source-link pins:

`refs.version_id` remains a polymorphic `TEXT` column. `source-content` rows use
`SourceVersionID`; `source-derived` rows use `SourceMarkdownVersionID`; page
refs stay in the page-version namespace. `source_links.pinned_version_id` is a
markdown-version identifier in Swift, but its stored text and null behavior do
not change.

### Rejected cross-namespace calls:

Markdown-version APIs must reject `PageID`, `SourceID`, `ChatID`, and
`SourceVersionID`. Source content-version APIs must reject
`SourceMarkdownVersionID`. The compiler fixtures and API signature manifests in
this issue are the durable proof of those rejected calls.

## Implementation Summary

Add a public nominal identifier in `WikiFSTypes` that follows the existing `SourceVersionID` pattern. Convert each Swift API by the meaning of its model property or SQL column.

Keep these adjacent namespaces separate:

- `SourceID` identifies `sources.id` and `source_markdown_versions.file_id`.
- `SourceVersionID` identifies `source_versions.id`, `source_versions.parent_id`, and `source_markdown_versions.source_version_id`.
- `SourceMarkdownVersionID` identifies `source_markdown_versions.id`, `source_markdown_versions.parent_id`, `source-derived` ref values, and source-link `pinned_version_id` values.
- `PageID` stays the page identifier. Chat and page-content version namespaces do not change.

Primary files include:

- `Sources/WikiFSTypes/SourceMarkdownVersionID.swift`
- `Sources/WikiFSCore/Sources/SourceMarkdownVersion.swift`
- `Sources/WikiFSCore/Integrations/ExtractionAlternative.swift`
- `Sources/WikiFSCore/Store/WikiStore.swift`
- `Sources/WikiFSCore/Store/GRDBWikiStore.swift`
- `Sources/WikiFSCore/Store/WikiStoreModel.swift`
- `Sources/WikiFSCore/Core/WikiRenderContext.swift`
- `Sources/WikiCtlCore/SourceCommand.swift`
- Source UI, reader, File Provider, daemon, and queue adapters that carry Markdown-version IDs
- `Tests/WikiFSTests/Fixtures/IdentifierBoundaryTypecheck/`
- A new Markdown-version API signature manifest and its Swift Testing suite
- `plans/source-markdown-version-id-separation.md`, `PLAN.md`, and `progress/`

Do not change SQLite tables, columns, schema versions, refs, raw ULID text, queue JSON, wiki-link `@vN` syntax, File Provider identifiers, CLI output, or agent-facing formats. Do not add implicit conversions or cross-type equality.

## Implementation Plan

### Phase 1: Record compatibility and add the identifier

1. Characterize the current `PageID` raw value and `Codable` representation used for Markdown-version IDs before changing production types.
2. Record literal legacy fixtures for a `SourceMarkdownVersion` identity or the nearest persisted JSON carrier that actually crosses a Codable boundary.
3. If Markdown-version IDs do not have a direct Codable carrier, record this fact and test the shared primitive-string representation against `PageID` and `SourceVersionID`.
4. Add `SourceMarkdownVersionID` in `WikiFSTypes` as `Hashable`, `Codable`, `RawRepresentable`, `Sendable`, and `Identifiable`.
5. Use a `String` raw value and preserve primitive-string Codable output.
6. Do not add conversion initializers from `PageID`, `SourceID`, `ChatID`, or `SourceVersionID`.
7. Add focused tests for raw-value preservation, hashing, identity, Codable shape, and decoding of the characterized legacy representation.

### Phase 2: Convert core models and protocol contracts

1. Change `SourceMarkdownVersion.id` and `parentID` to `SourceMarkdownVersionID` and `SourceMarkdownVersionID?`.
2. Change the initializer parameters to the same types.
3. Keep `SourceMarkdownVersion.sourceID` as `SourceID` and `sourceVersionID` as `SourceVersionID?`.
4. Change `ExtractionAlternative.id` to `SourceMarkdownVersionID`.
5. Change `WikiStore.processedMarkdownAgentNames(sourceID:)` from `[String: String]` to `[SourceMarkdownVersionID: String]`. Convert the GRDB row key, model wrapper, and `SourceDetailView` lookup to the typed key.
6. Convert every `WikiStore` requirement whose argument or return value identifies a Markdown-version row. This includes processed-version lookup, append and revert results, active-ref selection, extraction recording, history, alternatives, producer lookup, derived chains, source-link pins, nomination, and rollback helpers found during the final exact-symbol audit.
7. Keep page APIs, source-entity APIs, source content-version APIs, and chat APIs in their current namespaces.
8. Add `WikiStoreError.sourceMarkdownVersionNotFound(SourceMarkdownVersionID)`. Use it for unknown Markdown-version revert, set-active, and nomination targets. Keep `notFound(PageID)` for real page failures.
9. Update all protocol conformers and test doubles with the typed contracts.

### Phase 3: Convert GRDB by SQL-column meaning

1. Update `GRDBWikiStore.readMarkdownVersion(from:)` so `source_markdown_versions.id` and `parent_id` decode as `SourceMarkdownVersionID`.
2. Keep `file_id` decoding as `SourceID` and `source_version_id` decoding as `SourceVersionID`.
3. Generate new Markdown-version row IDs as `SourceMarkdownVersionID(rawValue: ULID.generate())`.
4. Bind only `.rawValue` into existing `TEXT` columns.
5. Type all reads and writes of `refs.version_id` as `SourceMarkdownVersionID` only when `kind = 'source-derived'`. Keep the polymorphic raw SQL column and other ref kinds unchanged.
6. Type `source_links.pinned_version_id` as `SourceMarkdownVersionID` in source-link adapters. Keep the column, null behavior, role uniqueness, and stored strings unchanged.
7. Convert private helpers such as inline append, active-head resolution, producer lookup, history reconstruction, nomination, compare, and rollback by their column meaning.
8. Do not use a broad `PageID` replacement. Review each remaining `PageID` near source Markdown code.
9. Add legacy SQLite fixtures that insert exact raw IDs into `source_markdown_versions`, `refs`, and `source_links`. Reopen the store and assert typed values plus unchanged raw text.
10. Assert `PRAGMA user_version` does not change.

### Phase 4: Convert model, rendering, queue, CLI, projection, and UI flows

1. Change `WikiStoreModel` processed-version lookup, active selection, history, alternatives, and producer methods to `SourceMarkdownVersionID`.
2. Change pending pinned-extraction state and `selectSource(byID:pinnedExtractionID:)` to `SourceMarkdownVersionID?`.
3. Change `WikiRenderContext.sourceDerivedChain` to `[SourceID: [SourceMarkdownVersionID]]` in its property, initializer, and builder.
4. Convert render, transclusion, quote, `@vN`, and pinned-source-link inputs and outputs while preserving rendered link text and ordinal behavior.
5. Convert source compare, extraction alternative, history, provenance, nominate, set-active, and rollback UI state and callbacks.
6. Preserve view identity and selection behavior. This change is not a visual redesign.
7. Convert `wikictl source set-active` and related source commands at argument parsing. Parse raw text as `SourceMarkdownVersionID` and print the same raw text.
8. Convert File Provider projection, app queue ingestion, daemon queue ingestion, and reader adapters only where values identify Markdown versions.
9. Keep queue JSON, File Provider item identifiers and paths, staged filenames, wiki links, CLI text, and agent manifests as raw strings at their boundaries.
10. Consult `swiftui-pro` after the UI conversion. Filter advice for macOS 15 and Swift 6.0. Preserve the rule against synchronous SwiftUI state writes from `NSViewRepresentable` updates.

### Phase 5: Add compiler and signature guards

1. Extend `IdentifierBoundaryTypecheckTests` and its positive fixture so valid `SourceMarkdownVersionID` calls compile.
2. Add negative fixtures that pass `PageID`, `SourceID`, `ChatID`, and `SourceVersionID` to representative Markdown-version APIs.
3. Add the inverse fixture that passes `SourceMarkdownVersionID` to a source content-version API.
4. Assert exact type-mismatch diagnostics that name `SourceMarkdownVersionID`.
5. Update the existing `markdown-version-id-to-source-version-api.swift` fixture so it carries the new nominal type instead of obtaining a `PageID` from `SourceMarkdownVersion.id`.
6. Add `SourceMarkdownVersionAPISignatureManifestTests` and `Tests/WikiFSTests/Fixtures/SourceMarkdownVersionAPISignatures.txt`.
7. Enumerate the reviewed public and key private surfaces. Include the model properties, protocol methods, GRDB decode/generation sites, model methods, render chain, pinned extraction, source-link pin, compare, nomination, history, active ref, rollback seams, `sourceMarkdownVersionNotFound`, and the typed `processedMarkdownAgentNames` map.
8. Require each typed manifest fragment to contain `SourceMarkdownVersionID`.
9. Add a writer-adjacency guard that checks typed ULID generation occurs beside live `source_markdown_versions` inserts.
10. Add `ProcessedMarkdownTests.agentNamesUseMarkdownVersionIDKeys`. Verify that the producer-name map returns and resolves a `SourceMarkdownVersionID` key.
11. Add tests that unknown revert and set-active targets throw `sourceMarkdownVersionNotFound`. Keep a page-failure test that throws `notFound(PageID)`.

### Phase 6: Preserve behavioral contracts

1. Update `Phase6PinningStoreTests` to use `SourceMarkdownVersionID` for unknown IDs, derived chains, and source-link pins.
2. Keep tests for chronological `@vN` resolution, ordinal stability after append, distinct cite/embed pins, null pins, and processed-version lookup.
3. Extend persistence tests to cover parent chains, active `source-derived` refs, alternatives, history, producer lookup, nomination, compare inputs, and rollback or revert targets.
4. Update `WikiRenderContextTests`, pinning pure/model tests, `ProcessedMarkdownTests`, projection tests, transclusion tests, queue restart tests, CLI tests, and store emission tests.
5. Add explicit raw-contract assertions where an ID leaves typed Swift code. Compare exact output for CLI and projection contracts. Compare normalized JSON for queue contracts.
6. Keep all existing resource-change emissions. New or changed public store mutators must still route through the established mutation seam.
7. Use Swift Testing for new tests. Avoid bare `try?` and `print` diagnostics.

### Phase 7: Document and deliver

1. Create `plans/source-markdown-version-id-separation.md` as the design and implementation record.
2. Document the three source-related namespaces, the no-migration decision, polymorphic refs, source-link pins, raw-string boundaries, and rejected cross-namespace calls.
3. Add the plan to the documentation index in `PLAN.md`.
4. Record implementation progress, decisions, and exact verification results in `progress/`.
5. Use STE-flavored prose for repository documents and the pull request.
6. Work on a feature branch. Push it and open a pull request. Do not merge it.

## Acceptance Criteria

- **AC.1:** `SourceMarkdownVersionID` is public in `WikiFSTypes`. Its raw value and Codable representation match the characterized legacy `PageID` representation.
- **AC.2:** `SourceMarkdownVersion.id` and `parentID` use `SourceMarkdownVersionID`. Their source entity and source content-version properties keep their existing types.
- **AC.3:** All reviewed Markdown-version APIs use `SourceMarkdownVersionID`. Page, source, chat, and source content-version APIs reject it.
- **AC.4:** Existing Markdown-version rows, parent chains, `source-derived` refs, extraction alternatives, and active selections load without migration and retain exact raw IDs.
- **AC.5:** `WikiRenderContext.sourceDerivedChain` has `SourceID` keys and `[SourceMarkdownVersionID]` values. `@vN` remains chronological and stable after append.
- **AC.6:** Source-link `pinned_version_id` reads and writes use `SourceMarkdownVersionID` in Swift. Existing null, cite, embed, and role behavior remains unchanged.
- **AC.7:** Pending pinned extraction, compare, nominate, producer lookup, history, set-active, and rollback or revert flows carry `SourceMarkdownVersionID` end to end.
- **AC.8:** Compiler fixtures reject `PageID`, `SourceID`, `ChatID`, and `SourceVersionID` at Markdown-version APIs. They also reject `SourceMarkdownVersionID` at source content-version APIs.
- **AC.9:** The Markdown-version API signature manifest covers the reviewed surface and fails if a typed signature loses `SourceMarkdownVersionID`.
- **AC.10:** SQLite schema, `PRAGMA user_version`, stored ULID text, queue JSON, wiki links, `@vN`, File Provider identifiers, CLI output, and agent-facing formats remain unchanged.
- **AC.11:** Pinning, rendering, extraction, queue restart, CLI, projection, persistence, and store emission tests pass.
- **AC.12:** `make prompts`, `swift build --build-tests`, full `swift test`, `make lint`, `git diff --check`, and CI pass under SwiftPM.
- **AC.13:** The new design document, `PLAN.md`, and `progress/` describe the final boundary and verification evidence.

## Test Strategy

| Acceptance criterion | Named test or check |
| --- | --- |
| AC.1 | `SourceMarkdownVersionIDTests.rawValueAndIdentityAreStable`, `SourceMarkdownVersionIDTests.codableShapeMatchesLegacyPageID` |
| AC.2 | `SourceMarkdownVersionIDPersistenceTests.modelKeepsThreeSourceNamespacesDistinct` |
| AC.3 | `SourceMarkdownVersionAPISignatureManifestTests.allMarkdownVersionSignaturesUseSourceMarkdownVersionID`, plus positive compiler fixture |
| AC.4 | `SourceMarkdownVersionIDPersistenceTests.legacyRowsParentsAndActiveRefRoundTripWithoutMigration` |
| AC.5 | `WikiRenderContextTests.sourceDerivedChainUsesTypedMarkdownVersionIDs`, `Phase6PinningStoreTests.ordinalResolvesChronologically`, `Phase6PinningStoreTests.ordinalStableUnderAppend` |
| AC.6 | `Phase6PinningStoreTests.replaceLinksWritesResolvedPin`, `Phase6PinningStoreTests.citeEmbedAndDistinctPinsCoexist`, `SourceMarkdownVersionIDPersistenceTests.legacySourceLinkPinKeepsRawText` |
| AC.7 | `Phase6PinningModelTests.pinnedExtractionRetainsMarkdownVersionID`, updated compare/history/nomination/producer/revert tests in `ProcessedMarkdownTests` and store suites |
| AC.8 | New `IdentifierBoundaryTypecheckTests` cases for page, source, chat, and source-version rejection, plus inverse source-version rejection |
| AC.9 | `SourceMarkdownVersionAPISignatureManifestTests.allMarkdownVersionSignaturesUseSourceMarkdownVersionID`, `SourceMarkdownVersionAPISignatureManifestTests.liveWritersGenerateTypedIDsAdjacentToRuntimeInserts` |
| AC.10 | `SourceMarkdownVersionIDPersistenceTests.schemaUserVersionAndRawIDsAreUnchanged`; `QueueRestartTests.restartPreservesLegacyQueueJSONWithoutMarkdownVersionFields`; `QueueEventEnvelopeTests.queueEventEnvelopeJSONIntentionallyCarriesNoMarkdownVersionField`; `Phase6PinningPureTests.canonicalAndRenderedPinnedLinkTextStayExact`; `ProjectionTests.sourceMarkdownByIDRoundTrip`; `ProjectionTests.sourceMarkdownNodeByIDFilenameIsULIDDotMD`; `WikiCtlCommandTests.parsesSourceSetActiveVersionIDAsExactRawString`; `WikiCtlCommandTests.sourceIDInputAndOutputRemainRawStrings`; `ModelsConfigRecordTests.writeProducesSortedPrettyJSONWithExpectedTopLevelKeys` |
| AC.11 | Focused suites: `SourceMarkdownVersionIDTests`, `SourceMarkdownVersionIDPersistenceTests`, `IdentifierBoundaryTypecheckTests`, `SourceMarkdownVersionAPISignatureManifestTests`, `Phase6PinningPureTests`, `Phase6PinningStoreTests`, `Phase6PinningModelTests`, `WikiRenderContextTests`, `ProcessedMarkdownTests`, `StoreEmissionTests`, `QueueRestartTests`, `QueueEventEnvelopeTests`, `WikiCtlCommandTests`, `ProjectionTests`, `ModelsConfigRecordTests`, and `TransclusionEmbedTests` |
| AC.12 | `make prompts`; `swift build --build-tests`; `swift test`; `make lint`; `git diff --check`; PR CI |
| AC.13 | `DocumentationContractTests.sourceMarkdownVersionIDBoundaryIsDocumented`, `DocumentationContractTests.planIndexesSourceMarkdownVersionIDDocument`, `DocumentationContractTests.progressRecordsSourceMarkdownVersionIDVerification` |

Run focused tests after each phase. Run final verification in this order:

1. `make prompts`
2. `swift test --filter 'SourceMarkdownVersionIDTests|SourceMarkdownVersionIDPersistenceTests'`
3. `swift test --filter 'IdentifierBoundaryTypecheckTests|SourceMarkdownVersionAPISignatureManifestTests'`
4. `swift test --filter 'Phase6PinningPureTests|Phase6PinningStoreTests|Phase6PinningModelTests|WikiRenderContextTests'`
5. `swift test --filter 'ProcessedMarkdownTests|StoreEmissionTests|WikiCtlCommandTests|ProjectionTests|TransclusionEmbedTests'`
6. Run the queue restart and ingestion suites identified by the final symbol audit.
7. `swift build --build-tests`
8. `swift test`
9. `make lint`
10. `git diff --check`

Mutation testing is optional because this change primarily adds nominal type safety. Run scoped mutation tests only if implementation changes ordinal, pin, or rollback logic.

## Review Strategy

Run the `plan-reviewer` before handoff. Fix or rebut all findings. Run another review if a critical or high finding remains.

During implementation, consult `swiftui-pro` before and after UI changes. Keep all code compatible with macOS 15, Swift 6.0, and command-line SwiftPM builds.

After implementation and automated tests, dispatch a `general-purpose` reviewer. Review the full diff for these errors:

- A Markdown-version ID remains `PageID`.
- A source entity or source content-version ID changed to the wrong type.
- A polymorphic `refs.version_id` value uses the wrong namespace.
- SQL, JSON, links, File Provider, CLI, or agent-facing raw text changed.
- Compiler fixtures omit one neighboring namespace.
- The manifest omits a public or load-bearing private seam.
- A store mutator loses its event emission.
- New code adds bare `try?`, `print`, magic sentinels, or implicit conversions.

Fix or explicitly rebut all findings. Repeat review after critical findings until no critical finding remains.

## Documentation Strategy

Create `plans/source-markdown-version-id-separation.md` and add it to `PLAN.md`. Use it as the design and implementation record for issue #956.

Update `progress/` with phases, compatibility evidence, focused test results, final SwiftPM results, lint results, and CI status. Extend `DocumentationContractTests` so the namespace boundary and no-migration rule cannot silently disappear.

No user-guide update is needed because visible behavior and external formats do not change.

## Risks, Blockers, and Required Decisions

- `refs.version_id` is polymorphic. Type it only after checking `RefKind`. Keep raw storage unchanged.
- `source_links.pinned_version_id` identifies a Markdown version, while `from_page_id` and `to_source_id` use different namespaces.
- The model, compare UI, and render path contain many `PageID` values that identify real pages. Convert by meaning, not by proximity.
- Some external carriers use raw strings and must stay raw. Construct `SourceMarkdownVersionID` only at typed boundaries.
- Synthesized Codable compatibility must be measured before implementation. Do not infer it from `RawRepresentable` conformance.
- Existing compiler-fixture and signature-manifest infrastructure is sufficient. No test-infrastructure blocker remains.
- No product decision remains. Issue #956 defines the namespace and compatibility behavior.
