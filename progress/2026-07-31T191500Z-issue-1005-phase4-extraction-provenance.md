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

## Exact-head audit correction

The corrective implementation commit
`21cced015a3e894ac6af987b77a8b6667b6a553b` closes the exact-head audit's
coverage findings without expanding into Phase 5 UI or hydration work.

- Added real writer-contract tests for every required PDF, backend, local-tool,
  materializer, transcript, and `wikictl` seam. Each writes through production
  code and reads the resulting typed `ExtractionProvenance`.
- Added compatibility tests that prove legacy `appendProcessedMarkdown` and
  transcript entry points reach `appendDerivedMarkdown` with typed producers.
- Added missing hook rollback assertions for activity plans, source-version
  links, active heads, blobs/refcounts, and no event emission.
- Added `ExtractionTool.vimeoTranscript` for imported Vimeo transcript
  compatibility and `ExtractionTool.bytelessOEmbedSynthetic` codec/projection
  coverage. This phase does not introduce a native Vimeo network fetcher.
- Reconciled the normative AC matrix and callable/branch manifest with the
  concrete test files and names.

## Verification

Implementation commit: `59381b25fed367c8cb054725a5fa1bc280f96451`.

- `make build` passed.
- `make test` passed: 2,920 tests in 236 suites, with two explicitly skipped
  opt-in ACP integration tests.
- `swift build` passed.
- `swift test` passed: 2,945 tests in 238 suites, with four existing opt-in or
  flaky skips.
- Focused codec, projection, derived-write, hook, event-emission, manifest,
  CLI, source-version, and legacy extraction regression suites passed.
- Corrective focused Phase 4 suites passed: 53 tests in five suites.
- Corrective Phase 4 plus Phase 3 regression suites passed: 139 tests in 15
  suites.
- `git diff --check` passed. The source audit found no new bare `try?`, no new
  raw page/source ID comparisons, and canonical routing through
  `recordMarkdownExtraction` or `appendDerivedMarkdown` at every reviewed
  writer seam.
