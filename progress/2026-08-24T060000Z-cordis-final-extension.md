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
- Review remediation adds per-wiki chat-host single-flight creation, preserves
  combined CLI operation and cleanup errors, and normalizes fixture policy paths.

Implementation commits:

- `dfd284a4` and `eff71730`: daemon prepared stores, launcher factory, and
  explicit wiki chat routing.
- `38ad1e62`: CLI profile resolution, store bootstrap, and runner tests.
- `1d56bb35`: tightened source boundaries and synthetic violation tests.
- `a717d781`: independent-review lifecycle and boundary remediation.

Design record: `plans/cordis-final-extension.md`.

## Verification

- `make build` passed.
- `make test` passed with 3,588 tests in 360 suites.
- `make check-cordis` passed.
- The final opt-in Cordis selection passed with 66 tests in six suites after review remediation.
- `CLITantivyLegResolverTests` passed with 11 tests.
- `CordisBoundaryScriptTests` passed with 12 parameterized cases.
- The focused daemon store, launcher, chat, workload, and profile suites passed
  during their implementation phases.
- `GRDBWikiStore(` has no match in `Sources/wikid/WikiDaemon.swift` or
  `Sources/wikictl/main.swift`.

The complete opt-in app suite still has unrelated parallel-state failures. They
occur in MIME inference, a renderer source audit, chat sequence timing, and XPC
event-sink registration timing. The matching focused Cordis suites pass.
