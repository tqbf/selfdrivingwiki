---
timestamp: 2026-09-07T120000Z
title: Scoped --help for every wikictl command and subcommand
branch: feature/wikictl-scoped-help
status: complete
---

# Scoped --help for every wikictl command and subcommand

Implements [#1224](https://github.com/tqbf/selfdrivingwiki/issues/1224).

## Progress

`wikictl` printed help only for a leading top-level `--help`. Every other help
attempt parsed as a command and failed with a usage error. An agent that asked
`wikictl source --help` learned nothing.

Help is now spec-driven. `Sources/WikiCtlCore/CLIReference.swift` describes the
whole command surface as data: families, subcommands, nested OKF operations,
options, summaries, examples. Three layers read the same table:

- Routing. `ArgumentParser` recognizes exactly the documented subcommands, and
  unknown-subcommand errors list the known set with a pointer to the scoped
  help.
- Option validation. The parser option bag accepts exactly the options the
  table lists. An unlisted option is now a loud usage error. Before, an
  unknown option with a value was silently ignored.
- Help text. `wikictl [<command> [<subcommand>]] --help` generates its text
  from the table, so help cannot drift from parsing.

Accepted forms: `wikictl --help`, `wikictl source --help`,
`wikictl source add --help`, `wikictl page okf verify --help`,
`wikictl version --help`, `wikictl --dump-config --help`. `-h` works as an
alias. Help intercepts before wiki resolution, so it never needs `--wiki` or
`WIKI_DB`. Help surfaces show purpose, usage, arguments, required and
repeatable options, examples, and exit status.

Two behavior changes are deliberate:

- Unknown options now fail with exit 2. Previously they were ignored when they
  carried a value. No prompt, script, or test in the repo relied on this.
- A usage error no longer dumps the whole usage block to stderr. It prints the
  error and one line that points at `wikictl --help` (or the nearest scoped
  help), per the axi.md guidance the issue cites.

`ArgumentParser.usageText` stays as the public top-level text, but it now
computes from `CLIReference` instead of a hand-maintained string literal.

## Verification

- `make build` passes.
- `make test` passes: 4232 tests, 460 suites, including 21 new tests in
  `Tests/WikiFSTests/CLIHelpTests.swift`. The new suite covers top-level,
  family, leaf, and OKF-operation help, help without a wiki or `WIKI_DB`,
  loud unknown-option and unknown-subcommand errors, and a spec-to-parser
  consistency check that fails if a documented subcommand is not routable.
- Manual smoke tests of the built binary: `wikictl source --help`,
  `wikictl source add --help`, `wikictl page okf verify --help`,
  `wikictl chat --help`, `wikictl --help` all exit 0 with no wiki selected.
  `wikictl --wiki W source bogus`, `wikictl --wiki W source list --bogus`,
  and `wikictl page list` (no wiki) still exit 2 with clear messages.
