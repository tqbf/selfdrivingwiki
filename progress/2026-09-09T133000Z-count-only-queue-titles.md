---
timestamp: 2026-09-09T133000Z
title: Count-only queue titles
branch: feature/integrated-queue-workspace
status: complete
---

# Count-only queue titles

## Progress

Operator request: the job header title and the navigator list rows included
the first target's page/source name — the name when the target's wiki was
open, a raw page ID when it was closed. Remove the name from the title and
the navigator row entirely: **operation plus count only**. The Overview
inventory's clickable target-name rows and the Run Details Job ID row stay.

### Wordings

| Job | Navigator row | Header title |
| --- | --- | --- |
| Ingestion, N > 1 targets | `Ingest 12 sources` | `Ingestion: 12 sources` |
| Ingestion, 1 target | `1 source` | `Ingestion: 1 source` |
| Extraction/transcription, N > 1 | `12 sources` (unchanged count wording) | `Extraction: 12 sources` |
| Extraction/transcription, 1 | `Extraction` (kind label, unchanged) | `Extraction: 1 source` |
| Page lint, N > 1 | `Lint 3 pages` | `Lint: 3 pages` |
| Page lint, 1 | `Lint 1 page` | `Lint: 1 page` |
| Whole-wiki lint | `Lint <wiki>` (unchanged) | `Lint: <wiki>` |

Zero-target non-lint payloads keep the kind label (the old count path's
fallback) rather than speaking a wrong count.

### Implementation

- `ActivityWindowView.computeRowTitle(for:wikiName:)` — dropped the
  `names:` parameter and the first-target-name branch; titles are operation +
  count only. Still PURE + `nonisolated`, still pinned by the value suites.
- `ActivityWindowView.headerJobCountPhrase(for:wikiName:)` (new) — the
  count-only `<Job Details>` phrase `QueueWorkspaceMapper.headerTitle`
  prefixes. `headerPresentation` composes the header from it; the old
  `rowTitle(for:)` (whose only consumer was the header) is gone.
- Names still resolve exactly as before (live → recorded → read-only); they
  now feed only the navigator row tooltip and the search haystack. No
  tooltip or haystack change: search still matches target names.
- Out of scope, untouched: Overview inventory rows (names + click-through),
  Outputs rows, Run Details Job ID, `QueueWorkspaceMapper.headerTitle`
  itself (still a pure prefix composer).
- Tests: `QueueClosedWikiNameResolutionTests` —
  `closedWikiRecordedNamesStayOutOfRowTitles` (rewrote
  `closedWikiLintRowTitleUsesRecordedNames`: resolution still asserted,
  title pinned to `Lint 2 pages`), `legacyClosedWikiLintRowTitleFallsBackToCount`
  (new signature), and the new
  `closedWikiLegacyTitlesNeverContainRawTargetIDs` regression (legacy
  closed-wiki payloads: neither row nor header title contains a raw target
  ID; exact singular wordings pinned). `QueueWorkspaceIntegrationTests` —
  `headerTitleCarriesFullOperationLabel` repinned to count phrases; new
  `jobTitlesAreOperationAndCountOnly` pins every row/header wording and
  asserts no raw ID reaches either title.
- Docs: `plans/integrated-queue-workspace.md` (design change 9, layout-art
  row and header titles, navigator + header prose, change 8's "titles come
  from the effective index" corrected to names-only);
  `docs/user-guide/interface.md` (queue section: titles are count-only,
  names stay in the Overview inventory rows).

## Verification

- `make build` green (builds + signs).
- `WIKIFS_APP_TESTS=1 swift test --filter QueueClosedWikiNameResolutionTests`
  — 23/23.
- `WIKIFS_APP_TESTS=1 swift test --filter QueueWorkspaceIntegrationTests`
  — 34/34.
- `WIKIFS_APP_TESTS=1 swift test --filter QueueWorkspacePresentationTests`
  — 24/24 (adjacent value suite).
- Hosted: `WIKIFS_APP_TESTS=1 swift test --filter
  ActivityWindowWorkspaceHostedTests` — 15/15.
- Hosted: `QueueOverviewLayoutHostedTests` still dies silently mid-suite —
  pre-existing (reproduced identically on a pristine stash of this working
  tree at HEAD `5a39812e`; see
  `progress/2026-09-09T124500Z-closed-wiki-name-resolution.md`), not caused
  by this changeset.
- Full `make test`: **4284 tests in 465 suites, all pass** (final run on the
  merged tree). Earlier full runs failed only from collisions with a
  concurrent session landing the Run Details usage-rows refactor
  (`QueueWorkspacePresentation`/`QueueActivityTracker`/`QueueRunDetailsView`)
  in the same working tree mid-verification — its in-flight state, not this
  changeset; final runs used the merged tree. On the final merged run the
  three focused value suites total 90/90 and the hosted workspace suite
  15/15.
