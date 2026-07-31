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

Implementation commit: `59381b25fed367c8cb054725a5fa1bc280f96451`.

- `make build` passed.
- `make test` passed: 2,920 tests in 236 suites, with two explicitly skipped
  opt-in ACP integration tests.
- `swift build` passed.
- `swift test` passed.
- Focused codec, projection, derived-write, hook, event-emission, manifest,
  CLI, source-version, and legacy extraction regression suites passed.
- `git diff --check` passed. The source audit found no new bare `try?`, no new
  raw page/source ID comparisons, and only the intended user/source callers at
  the `appendProcessedMarkdown` compatibility boundary.
