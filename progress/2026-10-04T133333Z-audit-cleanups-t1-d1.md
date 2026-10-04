---
timestamp: 2026-10-04T133333Z
title: Operator-approved conceptual-audit cleanups T1 and D1 applied
branch: feature/wiki-strategies-cumulative-ingestion
status: complete
---

# Operator-approved conceptual-audit cleanups T1 and D1 applied

## Progress

An independent conceptual-drift audit
(`tmp/claude-conceptual-drift-audit.md`, Claude Opus 4.6, reviewed SHA
`ff5988aea03b2d66cf11d2e1734576a53c0a674e`) found no structural findings.
The operator approved two optional cleanups. This task implemented exactly
those two cleanups and nothing else.

1. T1 — commit `ac8b2236`, `test(prompts): remove duplicate
   PromptResourceSyncTests byte-sync suite`. The struct in
   `Tests/WikiFSTests/AgentPromptContractTests.swift` duplicated
   `AgentPromptContractTests.agentPromptsMatchBundledResources` in the same
   file. Both asserted the canonical-to-bundled byte-sync invariant over the
   same nine prompt files in the same order. Verification preceded deletion:
   the only reference to `PromptResourceSyncTests` was its own declaration.
   The canonical test stays, and
   `CumulativeIngestContractTests.reconciliationContractHoldsOnCanonicalAndBundledPromptFiles`
   keeps the reconciliation-lens coverage. Verdict: redundant test removed,
   no assertion weakened.
2. D1 — commit `ccaedb8e`, `docs(user-guide): state the wiki strategy reset
   revision behavior precisely`. The guide said a reset wiki "keeps its last
   revision number". Both reset paragraphs in
   `docs/user-guide/wiki-strategy.md` now say: a reset that removes custom
   instructions advances the revision by one and keeps the revision record;
   a reset of a wiki already at Default is a no-op. This matches
   `GRDBWikiStore.saveWikiStrategy`, which writes a tombstone row with
   `revision.next` for a changed reset and returns `.unchanged` for a wiki
   already at Default. The guide makes no claim that every reset increments
   the revision.

Scope limits, stated plainly: the audit's T2, T3, T4, and D2 findings were
not touched. No live-app restart, no live wiki writes, no paid model calls,
no push, no merge, and no rebase ran.

## Gate outcomes at tested SHA `ccaedb8ed14a363fe216862f46ebb4a153cd56c4`

| Gate | Result |
|---|---|
| `make prompts` parity | pass — no tracked drift after regeneration |
| `make build` | pass — exit 0, app built and signed |
| `caffeinate -i make test` | pass — exit 0, 4757 tests in 513 suites across 10 runs, 0 issues |
| bare `swift build` | pass — exit 0 |
| `caffeinate -i swift test` | pass — exit 0, 4757 tests in 513 suites across 10 runs, 0 issues |

A targeted run passed first: `swift test --filter
'AgentPromptContractTests|PromptResourceSync|CumulativeIngestContract|DocumentationContract|WikiStrategyStore'`
reported 46 tests in 5 suites, exit 0. The `PromptResourceSync` alternative
matched no suite after the deletion.

The suite total is one test lower than the 4758 baseline recorded at
`0faa6da4`. The deleted duplicate accounts for the difference. Logs:
`tmp/gates/audit-cleanups-targeted.log`, `audit-cleanups-make-prompts.log`,
`audit-cleanups-make-build.log`, `audit-cleanups-make-test.log`,
`audit-cleanups-swift-build.log`, `audit-cleanups-swift-test.log`.

## Verification

1. The branch and index were verified before every edit and commit. The
   branch is `feature/wiki-strategies-cumulative-ingestion`, never `main`.
   `git status --porcelain` showed only the two intended files before the
   commits and was empty after every gate. No foreign change was staged or
   committed.
2. The duplication was verified before deletion, not assumed from the audit.
   File list, order, directories, and the byte-sync invariant match between
   the two tests. The surviving tests cover the same invariant.
3. All five gates ran in sequence at `ccaedb8e` with the outcomes above.
4. `DocumentationContractTests` re-ran green with this entry present, so the
   committed progress set still satisfies the template contract.

## Accepted gaps

- T2 (unreachable template-scenario code after the declared blocker) stays
  as-is. Issue #1357 tracks the template-menu testing gap for a separate PR.
- T3 (narrower cumulative-update contract test) and T4 (overlapping CAS
  coverage at different integration levels, kept by design) were outside the
  operator approval. Only T1 and D1 were approved and applied.
- The opt-in template-menu scenario failure (6/7) remains operator-accepted
  and is not part of the default suite.
