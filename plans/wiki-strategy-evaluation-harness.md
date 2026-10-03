# Wiki strategy live semantic evaluation harness

Last verified: 2026-10-02

## What this is

An opt-in harness that measures whether the real ingestion pipeline follows a
wiki's editorial strategy when source B corrects or re-documents what source A
established. It is plan Phase 5.3-5.5 of `plans/wiki-strategies-and-cumulative-ingestion.md` (AC.7).

A live run uses the operator's real configured provider, the real
`AgentLauncher` ingest path, and real `wikictl` writes by the real agent. It
never touches the operator's wiki data.

## Isolation

- Every wiki the harness creates is a disposable SQLite database under the
  output directory (default `tmp/wiki-strategy-eval/<timestamp>/`).
- The harness refuses an output directory under `~/Library/Group Containers`.
- The agent writes through a new typed selector: `wikictl --database-path
  <file>` (or `WIKI_DB_PATH`). It is mutually exclusive with `--wiki` /
  `WIKI_DB`, and `wikictl` refuses a path inside the real App Group
  container. `--wiki` remains the only route to a live wiki.
- `AgentLauncher.wikiDatabaseOverride` routes every launcher-side database
  derivation (trusted prompts, child environment, seatbelt write fence) to the
  same file. Any new derivation must call
  `AgentLauncher.wikiDatabaseURL(for:container:)`, including the cumulative
  plan-validation title resolver.
- Provider configuration is read read-only from the operator's App Group
  container, with provider discovery disabled. Credentials stay in the
  Keychain and are read at spawn time by the production credential stores.
  Quota-fallback state is redirected to a file under the output directory.

## Usage

```sh
scripts/run-wiki-strategy-eval.sh                     # all scenarios, default budget
scripts/run-wiki-strategy-eval.sh --scenario characterHistoryAcrossSources
swift build --product WikiStrategyEvalRunner          # manual build
.build/debug/WikiStrategyEvalRunner inspect           # fixture validation, no provider
.build/debug/WikiStrategyEvalRunner run --live \
  --provider-config-dir ~/Library/Group\ Containers/<group-id> \
  [--budget-seconds 1200] [--max-tokens 4000000] [--max-cost 5] \
  [--keep-fixtures]
```

`run` refuses without `--live`. Exit codes: 0 all structural checks passed,
1 at least one failed, 2 usage or configuration error.

Outputs under the output directory:

- `results.json` — machine-readable, `runKind` is `live` for these runs only.
- `<scenario>.report.md` — check table, run metadata, the state markdown the
  agent saw, and the human rubric section to fill in by hand.
- `summary.md` — one table across scenarios.

## Scenarios

- `characterHistoryAcrossSources` — source A establishes a character fact and
  an initial interpretation; source B corrects it. Checks evidence retention,
  qualified supersession, citations, identity, history depth, provenance, and
  unrelated-page immunity.
- `supersededRepositoryDecision` — ADR 014's rationale is superseded by
  ADR 021. Checks stated-versus-current decision handling.
- `sameEvidenceDifferentDocumentationStrategy` — one source, two fresh wikis,
  a how-to strategy then a reference strategy. Checks strategy-shape markers
  on each leg and that the two outputs differ.

## What a result means

Structural checks are heuristics over known fixture phrases, database
source-link rows, and snapshots. A pass says the enumerated expectations held.
It is not a general correctness or truthfulness guarantee. The human rubric
section in each report is the authoritative semantic review, and it is never
machine-answered. Canned and dry-run outputs are labeled `canned` and
`dryRun`; they can never be labeled `live`.

## Evaluator negative controls

`Tests/WikiFSTests/WikiStrategyEvaluationHarnessTests.swift` feeds canned
captures through the same evaluator and asserts failure for: dropped
evidence, unsupported claims, stale-write loss (no version recorded),
unqualified repetition of a superseded claim, wrong documentation strategy,
recreated page identity, missing citation rows, and unrelated page edits. It
also proves the budget wrapper times out a runaway body through structured
cancellation plus a force-stop hook, and that canned results never claim the
live verdict.

`Tests/WikiFSTests/WikiCtlExplicitDatabasePathTests.swift` covers the typed
selector: invalid combinations, unchanged ordinary registry resolution, and
no registry writes for explicit resolution.
