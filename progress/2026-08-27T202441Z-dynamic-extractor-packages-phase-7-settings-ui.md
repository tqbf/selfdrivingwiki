---
timestamp: 2026-08-27T202441Z
title: Phase 7 extractor package settings UI slice
branch: feature/dynamic-extractor-packages
status: complete
---

# Phase 7 extractor package settings UI slice

## Progress

Settings → Extraction now owns the installed-package lifecycle, not just a
read-only list. Everything runs on existing seams: `ExtractorPackageCatalogWriter`
for mutation, `ProcessExtractionContext` for observation and wakes, and
`ExtractionConfig.pdfExtractor`/`htmlExtractor` for logical selection.

- Import: an "Advanced Local Package Import" disclosure (mirrors the renderer
  picker) opens a local-directory-only `NSOpenPanel`, shows the executable-code
  trust warning before any import, and validates the selection at the boundary
  (one directory, no files/archives). Import calls
  `ExtractorPackageCatalogWriter.importDirectory` from the app wiring only.
- Trust warning: fixed text states that packages contain executable code that
  runs with the app's permissions. It also states that Cordis lifecycle and
  capability controls do not create a security sandbox.
- Removal: per-row "Remove Package…" opens a confirmation dialog (package,
  version, built-in fallback note) and calls `writer.remove(revision:)`.
  `ExtractorPackageSettingsRow` now carries the exact
  `ExtractorPackageRevisionID` so removal targets the catalog's lifecycle
  granularity, not a display prefix.
- Readiness: active registrations show "Active"; catalog revisions whose
  activation failed appear as "Not ready" rows carrying the reconciler's
  redacted failure message, fed from the new `AppProcessServices.extractionContext`
  + `observationSnapshot()`. A busy indicator with per-operation messages and
  path-free fixed diagnostics (`ExtractorPackageMutationMessage`) cover import,
  removal, and refresh.
- Logical selection: per-kind "PDF Extractor"/"HTML Extractor" pickers list
  installed packages by version-free logical reference and persist through the
  same auto-save path into `ExtractionConfig.pdfExtractor`/`htmlExtractor`.
  "Built-in default" (nil) restores the legacy backend pickers' precedence.
- Accessibility: stable identifiers for every new control
  (`extraction.packages.import.*`, `.remove.<row>`, `.failure.<row>`,
  `.selection.pdf|html`, `.progress`, `.diagnostic`, `.error`), labels, and
  state values ("Active"/"Not ready"), plus VoiceOver announcements for busy,
  success, and failure states. A checked-in manual smoke script covers spoken
  order and focus behavior that hosted tests cannot automate.
- Mutation stays app-only: the writer's `.app` role gate plus a source-contract
  test asserting only `WikiFSApp.swift` and the pre-existing app-process
  `ReviewedExtractorBootstrap.swift` construct the writer. No second resolver,
  no schema change, no package payload in wiki state.

## Verification

The following gates passed on 2026-08-27:

```text
make build
make test
3,851 Swift tests passed in 403 suites

WIKIFS_APP_TESTS=1 swift test --filter ExtractorPackageSettingsTests
13 tests passed

git diff --check
```

The settings tests cover registry snapshots, refresh, import, exact-revision
removal, unavailable selections, path-free diagnostics, picker validation,
accessibility identifiers, and app-only mutation authority. The manual
VoiceOver smoke script remains a release-time human check.
