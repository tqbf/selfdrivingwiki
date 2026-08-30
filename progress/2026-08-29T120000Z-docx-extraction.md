---
timestamp: 2026-08-29T120000Z
title: Word document (.docx) extraction via the reviewed docx2md package
branch: feature/docx-extractor-package
status: complete
---

# Word document (.docx) extraction

## Progress

A `.docx` source now gets an Extract button, a "Word" provenance chip, and a
stored Markdown version. Conversion runs through the fourth reviewed extractor
package, `org.selfdrivingwiki.docx2md` (mammoth + turndown, bundled with bun,
offline, no capabilities).

`ContentKind` gains `.docx` with `.docxBackend` and `shouldAutoIngest: false`:
raw docx bytes are a binary zip, so the ingest gate stays closed and extraction
runs on demand. The backend is package-only — the reviewed lineage is the
default selection, and an inactive package fails closed with one redacted
diagnostic. `ExtractionConfig.docxExtractor`, `resolveDOCX`, the Word route
row in Settings, and `WikiStoreModel.extractDocx` follow the HTML pattern,
including `.installedPackage` provenance.

`tools/docx2md/` holds the reviewed entry source with pinned dependencies and
an 11-case bun suite over a committed fixture document. Embedded images become
`![Figure N](figure-N.png)` placeholders plus a warning; the table rules adapt
turndown-plugin-gfm with a first-row-as-header fallback. The sync script
vendors the three upstream licenses, records the source digest in
sources.lock.json, and keeps the sources.lock (not byte-diff) check strategy
for the bun bundle.

## Verification

- `cd tools/docx2md && bun test` — 11 protocol and conversion tests pass.
- `swift run extractor-package-tool validate ExtractorPackages/Docx2md` exits
  0 and prints digest `ae5247e9…`; `protocol-smoke` replays a recorded real
  run to one terminal result frame.
- `make build` and `make test` pass (3984 tests), including the sync drift
  gate and the updated classification, config, selection, settings, store,
  and route-table suites.
- Manual live check is recorded as a checklist in the PR (no UI test harness).
