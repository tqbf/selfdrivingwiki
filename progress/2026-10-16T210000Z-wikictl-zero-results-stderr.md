---
timestamp: 2026-10-16T210000Z
title: Zero-results stderr notice for wikictl list and search verbs
branch: fix/wikictl-zero-results-stderr
status: complete
---

# Zero-results stderr notice for wikictl list and search verbs

Addresses [#1230](https://github.com/tqbf/selfdrivingwiki/issues/1230).

## Gap

List and search verbs that matched nothing printed nothing and exited 0. An
agent — wikictl's primary audience — cannot tell "no results" from "silent
failure" without reasoning about exit codes, so it re-runs with different
flags to verify. axi.md principle 5 (definitive empty states): when the
answer is "nothing", say so explicitly.

## Contract

A zero-row run now prints one stderr line and changes nothing else:

- stderr: `wikictl: 0 results for <verb>` — the verb phrase names the kind
  and any filter value that determined the emptiness (the quoted `--query`
  for the three search verbs, the workspace id for `workspace conflicts`).
- stdout: byte-identical to before. Empty TSV stays empty; `--json` stays an
  empty JSON-lines stream. stdout is a parseable compatibility contract and
  the notice deliberately does not touch it.
- Exit: still 0. Empty is a success, not an error.

The check lives with the commands (`Result.stderrOutput`, the same channel
`page get` uses for the `head_version_id:` echo), not in the printer, so the
text and `--json` modes stay consistent.

## Verbs

Covered: `page list`, `page search`, `source list`, `source search`,
`chat list`, `chat search`, `bookmark list`, `wiki list`, `workspace
conflicts`, `job list`. The first eight are the issue's list; `job list` is
the same zero-rows gap (its stdout was a bare TSV header, or `[]` for
`--json`) and its notice is wired in `main.swift` where the verb renders.

Deliberately unchanged:

- `extractor list` — text mode already prints an explicit empty-state
  message on stdout ("No syncable acquisition packages are installed…"),
  which is the strongest form of the principle; its `--json` mode follows
  the same empty-stream convention the covered verbs keep on stdout.
- `queue status` — always renders a per-lane table with counts; it has no
  zero-row state.
- `workspace conflicts` — keeps its pre-existing stdout `(no conflicts)`
  marker byte-identical and adds the stderr notice with the workspace id.

## Tests

`Tests/WikiFSTests/WikiCtlZeroResultsTests.swift` pins, per verb: the exact
stderr notice, byte-identical stdout in both modes, no notice on non-empty
runs (fabricated BM25 legs for the search controls, per the post-#634 test
pattern), a real workspace-merge conflict for the conflicts control, and the
`WikiCtlRunner.output` seam (notice rides stderr, stdout zero bytes). `wiki
list` and `job list` render in the executable target and are covered by the
end-to-end CLI run documented in the PR.
