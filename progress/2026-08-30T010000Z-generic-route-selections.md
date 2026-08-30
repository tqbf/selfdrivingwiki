---
timestamp: 2026-08-30T010000Z
title: Generic route records are the sole extractor selection
branch: feature/docx-extractor-package
status: complete
---

# Generic route records are the sole extractor selection

## Progress

`routeExtractors` is now the only persisted extractor selection. A route
record names a typed extraction route and one generic reference: a host
adapter identity, an installed package lineage, or the explicit no-default
value. The reference carries no PDF, HTML, or DOCX cases — the route
supplies the input format, the reference names only the implementation.

The retired `backend`, `htmlBackend`, `pdfExtractor`, and `htmlExtractor`
keys are decode-only migration inputs. The decoder adopts each retired value
into the matching route record when no record claims the route (`localPdf2md`
leaves the record absent, so the bundled default fills it), and encode never
writes the retired keys again. Fresh installs resolve through the bundled
default-route policy (`Sources/WikiFSCore/Resources/Extraction/
default-routes.json`): PDF defaults to the reviewed pdf2md lineage, DOCX to
the reviewed docx2md lineage, HTML to no default with the tag-based
execution floor.

Execution and resolution read one precedence: stored record, then bundled
default record, then nothing. A host adapter ID resolves to the registry
key `(route.kind, adapterID)`; the three migrated legacy names
(`localPdf2md`, `doclingServe`, `defuddle`) remap to their reviewed package
lineages. An explicit no-default record disables the shipped default for its
route instead of being refilled.

Settings writes generic records only: the prompt choices write `.none`
records, connected-service and tag-based picks write host references, and
reviewed picks write package lineages. The retired fields are never
rewritten.

## Verification

- `make build` and `make test` pass (3995 tests, 424 suites, including the
  extractor-package drift gate).
- Opt-in app suites pass: `WIKIFS_APP_TESTS=1 swift test --filter
  'ExtractionRouteTableHostedTests|ExtractorRouteRecoveryPresenterTests|
  ExtractorPackageSettingsTests'`.
- Reviewed package launch suites pass: `ReviewedLegacySelectionMappingTests`,
  `ReviewedDoclingLegacyMappingTests`.
