---
timestamp: 2026-08-29T120000Z
title: Word document (.docx) extraction via the reviewed docx2md package
branch: feature/docx-extractor-package
status: complete
---

# Word document (.docx) extraction

## Progress

A `.docx` source dropped into a wiki is now recognized and extracted
automatically. The docx2md package's registration declares the Word MIME
type and the `.docx` extension; those declared inputs, folded from the live
registry into `RegisteredExtractionInputs`, are what recognize the file (a
`.docx` IS a zip the sniffer reports as `application/zip`). With the
registration active, extraction runs at import through the injected
coordinator and seeds the Markdown head with `.installedPackage` provenance;
the Extract button remains as the manual retry.

`ContentKind.docx` keeps `shouldAutoIngest: false` — raw docx bytes are never
staged to agents; the auto-extracted Markdown version is what ingestion
stages. `ExtractionConfig.docxExtractor`, `resolveDOCX`, the Word route row
in Settings, and `WikiStoreModel.extractDocx` follow the HTML pattern.

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
