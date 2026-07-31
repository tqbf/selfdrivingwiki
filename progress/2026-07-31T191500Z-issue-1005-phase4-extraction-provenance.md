---
timestamp: 2026-07-31T191500Z
title: Issue #1005 Phase 4 extraction provenance
branch: issue-1005-phase-4-extraction-provenance
status: complete
---

# Issue #1005 Phase 4: extraction provenance

## Progress

Phase 4 adds typed extraction provenance. The work stays within durable source
markdown records. It does not add inspector, hydration, or SwiftUI code.

- `ExtractionActivityPlan` and `ExtractionActivityPlanCodec` write a versioned
  Codable activity plan. The codec reads legacy backend/model JSON.
- `ExtractionProvenance` reads the plan when valid. It uses normalized activity
  and agent columns when plan JSON is invalid.
- `appendDerivedMarkdown` validates producer metadata before it writes. It
  writes the activity, markdown version, blob, source-version link, and active
  head in one transaction.
- `AppendDerivedMarkdownHooks.afterInitialWrites` is internal. Production uses
  a no-op hook. A thrown test hook rolls back the whole derived write and emits
  no source event.
- PDF extraction compatibility, HTML, materializer sidecars, transcript paths,
  and the `wikictl` refresh path route through the typed derived seam.

## Verification

The targeted Phase 4 suites passed on the implementation workspace before the
final full verification run. The passing groups included codec, projection,
derived-write, hook, event-emission, manifest, CLI, and source-version suites.

The final exact commit SHA and full command results are added after commit and
push.
