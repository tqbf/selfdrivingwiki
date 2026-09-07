---
timestamp: 2026-09-07T160000Z
title: Write commands echo the new head_version_id
branch: feature/wikictl-head-version-echo
status: complete
---

# Write commands echo the new head_version_id

Implements [#1228](https://github.com/tqbf/selfdrivingwiki/issues/1228).

## Progress

The agent CAS loop cost one extra round trip: `page get` reports
`head_version_id` before a write, but the write commands printed only row ids.
After every `page add`, the agent had to run `page get` again before it could
issue the next `--expect-head` write.

Committing writes now echo the new head on stderr in the same
`head_version_id: <id>` form `page get` uses:

- `page add` on the main line: reads the head back from the store after the
  upsert, so the echo is the actual state, not a guess. The stderr payload
  keeps the fence-validation notice ahead of the head line.
- `page add --workspace`: `workspaceWritePage` returns the staged version, so
  the echo is direct. A workspace-CREATED page has no version row until merge,
  so there is no head to echo and stderr stays empty — it does not report a
  misleading main-line id.
- `page revert`: reads the repointed head after the revert.
- `source edit-markdown` and `source set-active`: read
  `processedMarkdownHead` after the write, so `set-active` reports the
  nominated head, not just the requested id.

stdout is byte-identical for every affected command; those formats are
compatibility contracts. Failed writes (CAS conflict, exit 3) return no
result, so no head line can leak from a failed write. `wikictl page add
--help` documents the echo.

## Verification

- `make test` passes: 4240 tests, 461 suites, including 9 new tests in
  `Tests/WikiFSTests/HeadVersionEchoTests.swift`. They cover create, update,
  workspace update, workspace created page (no echo), CAS conflict (no echo),
  revert, `source edit-markdown`, and `source set-active` nominating an older
  version (the echo reports the nominated head, not the latest).
- `FenceSyntaxValidatorTests` asserted upsert stderr was nil; that assertion
  now checks the actual contract — a fully-covered save emits no validation
  notice — because stderr legitimately carries the head echo.
