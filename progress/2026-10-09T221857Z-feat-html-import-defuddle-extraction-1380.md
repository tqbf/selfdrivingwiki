---
timestamp: 2026-10-09T221857Z
title: "feat: convert claimed HTML sources at ingest via Defuddle (#1380)"
branch: feature/html-auto-defuddle-extract
status: current
timestamp_source: session
---

# feat: convert claimed HTML sources at ingest via Defuddle (#1380)

## Progress

Issue #1380 asked HTML ingestion to run the Defuddle extractor instead of
storing the stock HTML representation. Issue #799 PR3 had removed HTML
auto-extraction at ingest and made the Extract button the trigger. This
change supersedes that decision for HTML only, and keeps the policy in
bundled data, not host kind branches.

**How it works:**

- `default-routes.json` gains an HTML route record (the reviewed Defuddle
  package, registration `article`) and a new `routeAutoExtraction` table
  that selects HTML for import-time conversion.
- `ExtractorRouteDefaults` decodes the new table (missing key decodes
  empty, the `routeFetchers` pattern) and exposes `autoExtractKinds`.
- `SessionsPlugin` derives `importAutoExtractionKinds` from claimed kinds
  intersected with (package-only kinds ∪ data-selected kinds). DOCX keeps
  its rule. HTML joins through data. A removed package drops the
  `text/html` claim, so the source lands verbatim as before the feature.
- `PreparedImportExtractor` gains an `.html` case. `prepareImportExtractor`
  resolves the effective selection and returns nil unless the adapter is
  package-backed. The tag-based floor and an explicit disable never
  convert at import.
- `runImportExtraction` dispatches `.html` through the existing
  `extractHtml(for:backend:extractor:)` path. `HtmlMarkdownExtractor` has
  no readiness probe, so runtime failures surface as skip-and-log, and the
  Extract button stays the surfaced retry.

**Tests:** `RouteAutoExtractionDefaultsTests` covers the bundled decode,
the applied selection label, and the missing-key decode. Three new tests
in `WikiStoreModelHtmlExtractionTests` cover the dispatch seeding a
package-technique head, the no-provider skip, and the gated ingest path.
Three `ExtractionConfigTests` expectations moved from "HTML resolves to no
selection" to the new bundled default, which mirrors the PDF decision
shape.

**Verification:** `make build` clean. `make test` green: 4451 tests in 456
suites. Two unrelated load flakes appeared in earlier runs
(`quitBackstopKillsAnInFlightManagedOperation`,
`membershipAdmissionTracksTheGeneratedPluginLifecycle`). Both pass in
isolation and passed on the final full run.

**Out of scope:** HTML sources ingested before this change stay verbatim.
The Extract button converts them on demand. A one-time backfill of
head-less HTML sources is a possible follow-up.
