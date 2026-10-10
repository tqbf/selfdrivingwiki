---
timestamp: 2026-10-09T232500Z
title: "fix: snapshot HTML ingest honors the import-extraction gate (#1390 follow-up)"
branch: bugfix/snapshot-html-import-extraction
status: current
timestamp_source: session
---

# fix: snapshot HTML ingest honors the import-extraction gate (#1390 follow-up)

## Progress

The #1390 merge wired the import-extraction gate into `storeMaterialized`
only. URL ingests where the page has images route through `storeSnapshot`
instead, which writes the image-rewritten tag-based sidecar and never
fired the gate. Image-bearing pages — most real pages — therefore kept
landing with the materializer sidecar as the active readable text, with
Defuddle never running.

Two changes:

- `storeSnapshot` now calls `autoExtractIfRegistered(pageSummary)` after
  the sidecar write. The gate is the same one `storeMaterialized` uses:
  no live claiming package, no run. The sidecar is the ingest-time
  fallback either way.
- The `.html` import dispatch nominates the package version as the
  active head after a successful extraction. Snapshot sources land with
  the sidecar as the default head, so without nomination the package
  version would ride as an alternative and the UI would keep showing the
  sidecar. On sidecar-less paths the import version is already the head,
  so the nomination is a no-op. Refresh does not route through these
  paths, so a later user nomination is never overridden.

The materializer sidecar stays in the alternatives list. Its images
carry rewritten stored URLs; the Defuddle version is cleaner text but
may drop or keep original image URLs. The user can re-nominate either.

**Tests:** `snapshotURLIngestNominatesPackageHeadOverSidecar` ingests an
image-bearing URL with the gate wired and asserts the package head is
active, the sidecar rides as an alternative, and the source blob stays
the original HTML. `snapshotURLIngestWithoutPackageKeepsMaterializerSidecar`
asserts the pre-#1380 behavior with no provider wired.

## Verification

`swift test --filter WikiStoreModelHtmlExtractionTests` green: 11 tests.
`make test` green: 4453 tests in 456 suites.
