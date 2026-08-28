---
timestamp: 2026-08-28T060000Z
title: Typed MIME route selections
branch: feature/extractor-route-selections
status: complete
---

# Typed MIME route selections

## Progress

Extraction selection gained a typed route identity as the foundation for the
registration-driven Settings routing table.

- `ExtractorRouteID` (WikiFSTypes) identifies one byte-extraction route by
  `ExtractorKind` plus a normalized `ExtractorMIMEType`. It is its own type —
  not a kind, not a backend kind, not a raw MIME string. Canonical constants
  cover the two routes execution supports: PDF (`application/pdf`) and HTML
  (`text/html`).
- `ExtractorRouteSelectionRecord` (WikiFSCore) pairs one route with one
  version-free `ExtractionBackendReference`.
- `ExtractionConfig.routeExtractors` stores records as a deterministically
  sorted array, not a string-keyed dictionary. A missing key decodes to an
  empty list; a malformed record is dropped through the logged decode seam;
  duplicate records for one route resolve deterministically (canonically-
  greatest record wins, independent of file order) with one bounded
  diagnostic and a non-advancing-coder stall guard.
- `extractorSelection(for:)` applies the precedence: exact route record, then
  the matching legacy reference field for a canonical route, then none.
  `setExtractorSelection(_:for:)` dual-writes the matching legacy field so old
  builds stay truthful; `backend` / `htmlBackend` remain owned by the Settings
  mapping.
- `ExtractorSelectionResolver` gained a route-aware entry point. `resolvePDF`
  and `resolveHTML` delegate through the route accessor, preserving result
  types, ranking, diagnostics, and fixed fallbacks exactly. Execution
  dispatch, the registry adapter enum, source dispatch, queue routing, and
  process execution are unchanged.

Design notes: `plans/dynamic-extractor-packages.md` § "Route selections: typed
MIME routes".

## Verification

The following gates passed on 2026-08-28:

```text
swift test --filter 'ExtractorRouteTests|ExtractionConfigTests|ReviewedLegacySelectionMappingTests'
42 tests passed

make build
make test
swift build
swift test
```

New regression coverage: route namespace distinctness, canonical-route MIME
normalization, kind-then-MIME ordering, keyed coding round-trip, record
normalization winner determinism, legacy configs without `routeExtractors`
resolving exactly as before, deterministic persisted record order through the
real `JSONSidecarConfig.save` path, replacement/removal preserving unrelated
routes, canonical dual-write truthfulness, duplicate/malformed record decode
resilience, and route-aware resolution parity with the legacy entry points.
