---
timestamp: 2026-10-26T120000Z
title: Foreground lint resource and content checks
branch: feature/foreground-page-lint
status: complete
---

# Foreground lint resource and content checks

## Progress

Extended the foreground page lint with deterministic resource and content
checks on `feature/foreground-page-lint`.

Capture is now version-aware and typed. `lintCapture` reads page, head,
namespaces, citation evidence, and the head's declared parent in one read
transaction. Citation occurrences parse through the shared span/syntax APIs
(alias-free links, aliases, names, ids, pins, quote and heading fragments;
code excluded). Each distinct (source id, version request) pair gets a
record with an explicit status: present, prefix, missing target, missing
version, unavailable extraction, read failure, budget omission. Names
resolve through a multiplicity-preserving index; ambiguity is reported with
candidates, never silently resolved. Named budgets (32 targets, 512 KiB per
version, 4 MiB aggregate, 512 KiB parent) clip only on Unicode scalar
boundaries. `WikiReadAccess.lintCapture` covers the pooled path; the model
offers `lintCaptureAsync` with a main-actor fallback and a throwing read
contract (nil is only a missing page).

New checks: footnote integrity (undefined/conflicting report-only, one safe
redundant-definition deletion), version-aware citations (pin validation,
projection-based quote correspondence mirroring the production reader,
partial-versus-full distinction, prefix honesty, ambiguity reporting,
canonicalization offer, encoding-only quote repair with a strict gate),
table structure (declared-column mismatch and alias-pipe cell severing from
authored pipes, report-only), and history-loss candidates against the actual
parent (tables, citation identities, named reduction thresholds; incomplete
parents qualify the comparison; never a restoration). Recipe ids
`redundant-footnote-deletion`, `source-canonicalization`,
`citation-encoding-fix` joined the defaults; steps are keyed by id.

Model review now receives bounded, version-labeled JSON evidence (8 records,
8 KiB per record, 16 KiB parent, 64 KiB total; 256 KiB page body and 384 KiB
task caps enforced by SKIPPING the model step with a visible notice rather
than clipping). Repair evidence leads with the finding's source targets.
Prompts mark all content untrusted and instruct the model to separate
internal contradictions from source-evidence conflicts, treat source
presence as non-proof, and allow uncertainty. Custom configured prompts are
captured at run admission and used verbatim. Session results carry typed
limit notices and derive Incomplete from unavailable evidence and checks.

Tests: `LintCaptureTests`, `LintExpandedChecksTests`, `LintEvidenceTests`
(pooled + in-memory capture, coherence across external commits, budgets,
footnote/table/history/projection matrices), `LintEvidenceSessionTests` and
`LintLiveEvaluationTests` (opt-in app tier; turn-boundary spies, captured
prompt bytes, evidence gates, live-driver guards), `LintReadOnlyPipelineTests`
(zero writes across the full detection pipeline).

Two stale app-tier files were repaired or removed: duplicate `onLint`
arguments in the sidebar hosted tests, and `AgentOperationRunnerTests`, which
tested the legacy `preflightLint` API removed by the earlier foreground-lint
commit (its coverage lives on in `LintAnalyzerTests`/`LintApplyStoreTests`).
`QueueIngestionError` gained `Equatable` for the retirement-contract tests.

## Verification

- `swift test --filter LintCaptureTests` — 8 passed.
- `swift test --filter "LintAnalyzerTests|LintCoreTests|LintPipelineConfigTests"` — 63 passed.
- `swift test --filter LintExpandedChecksTests` — 9 passed.
- `swift test --filter LintEvidenceTests` — 3 passed.
- `swift test --filter LintReadOnlyPipelineTests` — 1 passed.
- `WIKIFS_APP_TESTS=1 swift test --filter LintEvidenceSessionTests` — 4 passed.
- `WIKIFS_APP_TESTS=1 swift test --filter LintLiveEvaluationTests` — 3 passed;
  the live call test records its provider blocker to
  `tmp/lint-live-evaluation/last-run.txt`.
- `make build` — passed (app builds and signs).
- `make test` — passed (4753 tests, 489 suites, exit 0).
- `make lint` — passed (0 violations after fixing every new bare `try?`;
  baseline re-snapshotted for the moved literal-regex `try!` constants).
- `swift build`, `swift test` — passed.
- `swift test --filter "GeneratedPromptsParityTests|DocumentationContractTests"`
  — 35 passed.

Open, recorded honestly: `make test-app` (the opt-in hosted tier) is NOT
green on this branch. Five full-tier runs each failed a DIFFERENT
timing-sensitive hosted test (XPC event-sink registration, chat submit
suspension, wiki-change notification bridge, daemon exporter reply, PDF
stderr capture); every one passes in isolation, none touches lint code, and
several predate this change (two suites could not even compile because of a
duplicate `onLint` argument and the removed `preflightLint` API — repaired
here so the tier builds again). The lint-domain hosted suites pass
consistently. The tier's parallel-load stability is pre-existing debt, not
something this change regressed or can honestly claim.

Not done here, still open: the lint-specific hosted window driver (AC.8 of
the follow-up plan), the live provider run of the evaluation driver with six
seeded cases plus the manual semantic rubric review, and the original
subprocess/ACP fixture suites (existing tasks 8 and 9). A provider-less
environment cannot produce live-quality evidence; no model-quality claim is
made.
