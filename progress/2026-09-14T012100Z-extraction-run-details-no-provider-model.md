---
timestamp: 2026-09-14T012100Z
title: Extraction Run Details omit Provider and Model (#1253)
branch: bugfix/extraction-run-details-no-provider-model
status: complete
---

# Extraction Run Details omit Provider and Model (#1253)

## Progress

The Activity window's Run Details panel always rendered Provider and Model
rows. `runDetailsFacts` resolved them for every job: report header values
first, then the usage snapshot's provider/model mid-run. Extraction jobs
have no LLM provider and no model — they run managed extractor packages
under the seatbelt — so the panel showed "Not Reported" placeholders, or
stale agent vocabulary from a tracker snapshot, for jobs that can never
have either value.

The fix replaces the `providerText`/`modelText` optional pair on
`QueueRunDetailsFacts` with a new `QueueRunProviderModel` enum
(`QueueWorkspacePresentation.swift`). `.agent(provider:model:)` renders
both rows, with "Not Reported" placeholders for missing values.
`.extraction` renders neither row. The impossible combination — omitted
rows but present text — is no longer representable.

`ActivityWindowView.runDetailsProviderModel` now takes the item's
`QueueKind` and returns the enum. Extraction items (including the legacy
`.transcription` raw value) return `.extraction` without reading the
report header or any tracker snapshot, so agent metadata cannot leak onto
an extraction job. Agent runs (`.ingestion`, which includes lint) resolve
as before.

Usage rows are untouched. Tracker usage is keyed per item ID, and
extraction workers never record usage, so extraction jobs already show no
usage rows.

Design change 20 in `plans/integrated-queue-workspace.md` records the rule.
The extractor package name and version row suggested in the issue was
considered and deliberately deferred as a follow-up.

## Verification

- `make build` passed.
- `make test` passed (4378 tests) after the progress note was rewritten to
  the template; the first run failed only
  `DocumentationContractTests.progressEntriesFollowTemplate` because this
  note originally lacked the YAML front matter.
- New value tests pin the rule: `runDetailsProviderModelExtractionQueueHasNoIdentity`
  and `runDetailsExtractionFactsOmitProviderAndModelRows`.
