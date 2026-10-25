---
timestamp: 2026-10-24T120000Z
title: W5a staged-proposal repair tier
branch: feature/generalized-page-validity-lint
status: active
---

# W5a staged-proposal repair tier

## Progress

The engine/daemon/store half of the staged-proposal repair tier is done (no UI). The operator's trust ladder replaced eval-as-gate: an evaluated configuration repairs directly (tier 1), ANY unevaluated configuration still lints and fixes but stages its hunks for human review (tier 2), and report-only is degradation only (tier 3).

The acceptance manifest moved to schema 3 and lost `defaultReportOnly` — enabled now simply means approval rows exist. `LintRolloutSelection` gained `.stagedProposal(reason:)` with ordered gate semantics: invalid manifest degrades to report-only; a matching row on the live pipeline authorizes repairs; a matched-but-drifted row or any unmatched configuration selects staged proposal. `WikiLintEvalRunner manifest` dropped `--enable`.

Tier 2 is wired end to end without UI: the breaker records `userRejected` (new outcome kind, undo-equal thresholds) and `verificationFailure` for tier-2 runs under a key built from the live pipeline digest plus the provider/model/effort tuple — no approval row involved. The `lintSelectedPageProposal` lease policy pins the selected page, stays read-only, and earns exactly one allowance: `page propose-patch` against that page. The daemon validates proposals with the same `PagePatchValidator` rules and budget discipline as `page patch` (a rejection closes the run plus audit entry), requires the current receipt, then stages — never writes — at most one proposal per page per run. The staged record survives run teardown.

`LintProposalApplyService` applies an approved hunk subset through the existing `patchPage` exact-body CAS path, re-verifies with the W2a written-head machinery, auto-reverts and records breaker evidence on failure, refuses stale proposals untouched, and lands every outcome in a trusted `--kind lint` audit entry. Human rejection records `userRejected`. The per-page durable record carries `proposals=N` and `staged_proposal=<id>` labels that `LintPageRecordFacts` parses back.

The task template gained a `{{tierSection}}` placeholder: tier 1 renders empty (patch text unchanged), tier 2 instructs `page propose-patch` with the one-proposal-per-page rule and the `unresolved|staged proposal <id>` report mapping. The shipped manifest was regenerated for the new prompt hash; rows stay empty.

## Verification

Gate checks ran per commit. `make prompts`, `make build`, and `make test` pass. The targeted filter run `WIKIFS_APP_TESTS=1 swift test --filter 'Lint|PagePatch|ProposePatch|DaemonLint|DaemonScope|QueueReport|AgentOperationRunner'` passes: 128 tests in 20 suites, 178 tests in 25 suites, and 22 tests in 2 suites.

New suites: `DaemonLintProposalTests` (staging over the real scoped socket: happy path, one-per-page, validator parity, receipt discipline, budget closure, state bookkeeping), `PageProposePatchCommandTests` (parser parity and wire round trip), `LintProposalApplyServiceTests` (apply with one page event and preserved provenance, stale refusal, budget at apply, verification failure auto-revert plus breaker trip, rejection recording), and `LintProposalAudit` round trips inside the record-facts suite.

Updated suites: `LintAcceptanceGateTests` (three-way selection table, schema-3 validity, rows-non-empty pipeline guard), `LintRepairBreakerTests` (tier-2 authority wiring, rejection trips, tier-2 key without approval row), `DaemonLintPolicyTests` (five-policy matrix, propose seam, payload cannot select policy), `LintPromptContractTests` (tier sections render per tier; AC.1 system-prompt lint-free checks stay green), and the request-mode migrations in the plan/launcher tests.
