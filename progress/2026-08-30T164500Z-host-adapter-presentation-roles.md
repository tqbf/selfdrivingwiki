---
timestamp: 2026-08-30T164500Z
title: Host adapter presentation roles centralize in ExtractorRouteHostCatalog
branch: feature/centralize-host-adapter-presentation
status: complete
---

# Host adapter presentation roles centralize in ExtractorRouteHostCatalog

Issue #1177.

## Progress

`ExtractorRouteHostCatalog` now owns the single map from well-known host
adapter IDs to presentation meaning. The new `ExtractorRouteHostRole` enum
names the roles: the connected-service ACP adapter, the retired direct-API
names (anthropic and gemini stay distinct so the provider picker can prefill
the right successor), the Docling family, the pdf2md and Defuddle lineages,
and the built-in tag-based HTML adapter. `role(forHostAdapterID:)` maps raw
IDs; `role(for:)` maps a saved selection, folding the Docling family across
namespaces (the retired host name and the reviewed installed lineage report
the same role). Unknown IDs and other references resolve to nil.

Five call sites in `ExtractionSettingsView.swift` had re-derived "which
well-known adapter is this?" from raw values: the connected-service tag in
`selection(for:)`, the PDF and HTML branches of
`ExtractorRouteSettingsMapping.selection`, the ACP provider prefill, and the
recovery presenter's `isACP` / `isDocling`. All five now ask the catalog.
Display and recovery behavior is unchanged.

Engine-side registry keys (`ExtractionPlugins`, `ProcessExtractionServices`)
still construct `ExtractionBackendKey` literals — that is execution wiring,
not presentation. `ExtractorRouteDefaults.htmlSelectionLabel` in WikiFSCore
also compares adapter IDs; it cannot use the engine catalog because
WikiFSCore sits below WikiFSEngine. Both stay as they are.

## Verification

- `rg` over `Sources/WikiFS` shows no raw-value comparisons against
  well-known adapter IDs outside the catalog.
- `make build` passes.
- `make test` passes: 4044 tests in 431 suites. Two earlier runs each hit
  one unrelated transient failure in live-process suites (a full rerun with
  no code change passed; the repo keeps
  `scripts/test-with-watchdog.sh` for exactly this).
- `WIKIFS_APP_TESTS=1 swift test --filter "ExtractorPackageSettingsTests|
  ExtractionRouteTableHostedTests"` passes: 37 tests in 4 suites, including
  the recovery presenter and route diagnostics suites.
- New `ExtractorRouteHostCatalogTests` pins the role map: well-known IDs,
  the cross-namespace Docling family, and nil for unknown IDs and other
  references.
