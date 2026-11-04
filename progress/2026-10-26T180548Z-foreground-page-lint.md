---
timestamp: 2026-10-26T180548Z
title: Foreground page lint replaces queued wiki lint
branch: feature/foreground-page-lint
status: complete
---

# Foreground page lint replaces queued wiki lint

## Progress

Page review moved from the queued ingestion lane to a foreground, single-page
sheet. The check pipeline (built-in wiki-link + markdownlint checks, plus an
isolated one-shot model pass on the new `.lintCheck`/`.lintRepair` provider
stages) produces typed findings against a one-transaction page snapshot. Each
finding offers validated repair choices; choosing one runs only that recipe and
shows the full candidate diff before anything saves.

Key decisions:

- All finding coordinates are UTF-8 byte offsets with expected text, converted
  to AppKit UTF-16 ranges through one adapter (`LintLocationAdapter`). An
  invalid location fails the producing step — never a page finding invented by
  the host.
- `lint-pipelines.json` (versioned, beside `agent-providers.json`) configures
  steps, recipes, and validators. Missing file = bundled defaults in memory;
  an invalid file is never overwritten — problems surface in the sheet.
- Model steps run on fresh non-cached backends with the deny-all `.plan`
  permission policy and the extraction-grade read-only sandbox baseline.
  Scripts run sandboxed (no writes outside scratch, no network, wiki-DB and
  daemon-socket denies last) under a versioned JSON request/response contract.
- Apply pins the expected head AND the previewed canonical body inside the
  composed store transaction; a moved title graph refuses with zero writes
  (`PageCanonicalizationConflictError`). Dirty drafts block lint start and
  Apply; lint never autosaves or discards a draft.
- Queued lint is retired at every boundary: enqueue refused (app, daemon, CLI),
  pending/recovered/retried legacy lint terminates visibly before any provider
  call, retry disabled for those rows, executable lint cases and prompts
  deleted. Historical rows, reports, and transcripts still decode; the raw
  `lint` queue kind maps to ingestion with a typed `isLegacyLint`
  classification preserved.
- `WikiStoreModel.preflightLint` (auto-saving preflight) was removed; the
  detection logic lives on read-only in `LintAnalyzer`.

## Verification

- `make build` — clean build + signed app.
- `make test` — full suite green (4,715+ tests; includes the retirement
  adaptations and the new suites below).
- `make lint` — 0 violations in 769 files.
- `swift build` — clean (all targets).
- New suites, all green: `LintLocationAdapterTests`,
  `LintPipelineConfigTests`, `LintEnvelopeDecoderTests`,
  `LintProposalBuilderTests`, `LintAnalyzerTests` (against the real vendored
  markdownlint bundle, including single-fix parity with `applyFixes`),
  `LintApplyStoreTests` (exact Apply semantics on the real GRDB store:
  canonicalization conflict refusal with zero writes, stale head, deleted
  page, double-Apply, append-only history),
  `QueueEngineTests/legacyLintPayloadIsRefusedAtEnqueue`.
- Queue retirement suites green (enqueue rejection, worker guard, history
  readability, ordinary ingestion unaffected).
- Not yet done (separate follow-up, per the plan's own gates): hosted-NSWindow
  workflow tests (AC.11), real subprocess/ACP fixture suites (AC.8/9), the
  independent full-capability review from a different model family, and live
  provider evaluation with human review. The deterministic suites prove
  orchestration and data safety, not model obedience.
