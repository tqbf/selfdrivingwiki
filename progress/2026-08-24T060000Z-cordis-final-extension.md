---
timestamp: 2026-08-24T060000Z
title: Cordis final production extension
branch: feature/cordis-full-coverage
status: complete
---

# Cordis final production extension

## Progress

Completed the final production Cordis migration on
`feature/cordis-full-coverage`.

- The daemon resolves each wiki store from a prepared per-wiki child profile.
  Synchronous cache access returns a typed error before preparation.
- The per-wiki profile supplies `wiki.launcher-factory`. Chat hosts reuse one
  launcher pair per wiki session. Queue ingestion gets a new pair per operation.
- Chat RPC requests carry `WikiID`. The daemon owns one chat host for each wiki.
- Ordinary CLI commands boot a request-scoped CLI profile and resolve
  `wiki.store`. The profile shuts down after command success or failure.
- `StoreBootstrap` owns database creation and `Home` seeding for `wiki create`.
- `WikiCtlRunner` provides importable command orchestration and captured output.
- The boundary gate rejects concrete store and launcher construction at all
  migrated daemon and CLI paths.
- Each remaining construction boundary has a documented reason.

Implementation commits:

- `8ea3036f` and `eff71730`: daemon prepared stores, launcher factory, and
  explicit wiki chat routing.
- `38ad1e62`: CLI profile resolution, store bootstrap, and runner tests.
- `1d56bb35`: tightened source boundaries and synthetic violation tests.

Design record: `plans/cordis-final-extension.md`.

## Verification

- `make build` passed.
- `make test` passed with 3,586 tests in 360 suites.
- `make check-cordis` passed.
- `CLITantivyLegResolverTests` passed with 11 tests.
- `CordisBoundaryScriptTests` passed with 12 parameterized cases.
- The focused daemon store, launcher, chat, workload, and profile suites passed
  during their implementation phases.
- `GRDBWikiStore(` has no match in `Sources/wikid/WikiDaemon.swift` or
  `Sources/wikictl/main.swift`.

The final opt-in app suite and independent review run before the pull request.
