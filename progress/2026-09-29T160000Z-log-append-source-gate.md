---
timestamp: 2026-09-29T160000Z
title: log append --source — the Ingested stamp is ingest-only and asserted only after a completed ingest
branch: bugfix/log-append-source-ingest-gate
status: complete
---

# log append --source — the Ingested stamp is ingest-only and asserted only after a completed ingest

## Progress

Source `01M3NPAZM830381G655AXMK8Z3` showed "Ingested" in the UI without any
ingest: a chat agent imported a file (`source add --body-file`) and then ran
the ingest workflow's final step alone — `log append --kind ingest --source
<id>` — so the agent-asserted Ingested stamp fired for a plain import. Two
gaps caused it:

- `log append` stamped the source ingested for ANY `--source` pass,
  regardless of `--kind` (a query or lint entry naming a source would have
  flipped it too).
- The prompt taught the ingest ritual's log step but never stated the
  boundary — nothing told the agent that `--source` is the completed-ingest
  switch and that an import is not an ingest.

Fixes:

- The parser now rejects `--source` on any kind but `ingest`, with a usage
  message that says why. A flag the caller believes has an effect must fail
  loudly, not pass silently.
- `LogIndexCommand` gates the stamp on `kind == .ingest` as
  defense-in-depth for programmatic Action construction.
- The prompt's command reference and ingest step 6 now state the boundary:
  `--source` marks a COMPLETED ingest (pages written, index updated) and
  must never be passed — nor `--kind ingest` used — for a plain import.
- The two falsely stamped rows were cleared directly (data repair):
  `01M3NPAZM830381G655AXMK8Z3`, `01M3MC3P6D9BDBN9HAAYZCAH72`.

## Verification

- `make build` clean; full `make test` passes.
- `WikiCtlLogIndexTests` (16 tests) keeps the existing stamp coverage and
  adds: `--source` on `--kind query` is a parser usage failure, and a
  programmatic query-kind Action with a source leaves the file unmarked.
