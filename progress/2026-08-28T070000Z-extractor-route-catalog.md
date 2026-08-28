---
timestamp: 2026-08-28T070000Z
title: Registration-driven route presentation
branch: feature/extractor-route-catalog
status: complete
---

# Registration-driven route presentation

## Progress

The Settings route table's data layer is now a pure, fully tested projection
on top of PR 1's route selections. The Settings view itself still uses the
old pickers; the view consumes this in the next PR.

- Batch registrations carry manifest-derived presentation metadata
  (`ExtractorRegistrationPresentation`: display name, package name, declared
  kinds, MIME types, filename extensions). The trusted definition factory
  sources it from the validated manifest — nothing is inferred from package
  or registration IDs, and the UI never re-reads a manifest.
- `ExtractionBackendRegistry.installedRegistrationSnapshots()` projects one
  snapshot per active exact registration; built-ins never appear; snapshots
  drop with batch disposal.
- Reconciler observation now reports the exact revisions whose hosted
  definitions are waiting for activation (`waitingRevisionIDs`), by retaining
  the desired definition → revision map across reconciles.
- `ExtractorRouteTableBuilder` builds one deterministic row per route from
  host descriptors, active registration snapshots, and saved selections:
  - rows: host order (PDF, HTML) first, then typed route order;
  - choices: prompt / reviewed / installed (by package ID) / connected /
    built-in, with multiple exact versions deduplicated into one logical
    choice showing the highest active revision;
  - statuses: available, using a named fixed fallback, waiting for host
    service, failed activation.
- Presentation value types: `ExtractorRouteDescriptor`, `ExtractorRouteChoice`
  (closed source-category enum), `ExtractorRouteSettingsRow`,
  `ExtractorRouteStatus`. Host choices for the canonical routes match the
  pickers they will replace; no direct Anthropic or Gemini API choice exists.

Design notes: `plans/dynamic-extractor-packages.md` § "Route presentation:
registration-driven rows".

## Verification

The following gates passed on 2026-08-28:

```text
swift test --filter 'ExtractorRouteTableBuilderTests|ExtractionBackendRegistryBatchTests|ExtractorPackageSettingsSnapshotTests'
17 tests passed

make build
make test
swift build
swift test
```
