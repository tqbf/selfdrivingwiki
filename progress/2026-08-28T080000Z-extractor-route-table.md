---
timestamp: 2026-08-28T080000Z
title: Scrollable extractor route table
branch: feature/extractor-route-table
status: complete
---

# Scrollable extractor route table

## Progress

Settings → Extraction's Default Extractors section now shows the native,
registration-driven route table from PR 2's projection.

- The fixed PDF and HTML pickers are replaced by one SwiftUI `Table` with
  Format / Default extractor / Status columns, constrained to a fixed height
  so it scrolls internally and the Settings window stays bounded.
- View state collapsed from two per-kind enums into one route-scoped
  `ExtractorRouteSettingsSelection` with typed associated values — no
  sentinel strings for prompt, unavailable, or default state.
- Each row's pop-up writes through `ExtractorRouteSettingsMapping`, which
  keeps the legacy `backend` / `htmlBackend` fields truthful exactly as the
  old mapping did, while `setExtractorSelection` persists the typed route
  record. Auto-save semantics are preserved; no writes happen from a
  representable update path (the table is fully native SwiftUI).
- ACP Provider and Docling Serve configuration sections appear only while the
  PDF route's selection is the corresponding connected service; Claude and
  Gemini remain choices inside the ACP provider picker only.
- A stale installed selection stays selected in its pop-up (one unavailable
  choice from the builder) while the status column reports the fixed
  fallback.
- Package import, inspection, readiness, removal, the trust warning, and
  lifecycle rows remain in Installed Extractor Packages below the table.
  Podcast transcript selection remains its own control outside the table.
- Accessibility: the table, each route picker (identifiers derived from the
  typed route, e.g. `extraction.routes.picker.pdf-application-pdf`), and
  status cells carry stable identifiers; pickers expose "Default extractor
  for PDF/HTML" labels and values combining the selected extractor and
  status. Spoken announcements remain covered by the manual VoiceOver smoke
  script, which now walks the table rows, statuses, and fallback help text.

Design notes: `plans/dynamic-extractor-packages.md`. User guide:
`docs/user-guide/extractor-packages.md` (Selection and fallback).

## Verification

The following gates passed on 2026-08-28:

```text
WIKIFS_APP_TESTS=1 swift test --filter 'ExtractorPackageSettingsTests|ExtractionRouteTableHostedTests'
25 tests passed

swift test --filter DocumentationContractTests
make lint
make build
make test
swift build
swift test
```
