---
timestamp: 2026-08-05T150000Z
title: Dynamic renderers Phase 5 B3/B4 inventory refresh
branch: feature/dynamic-renderers-05-webview
status: complete
timestamp_source: local-clock-america-los-angeles
issue: 1026
phase: 5
---

# Dynamic renderers Phase 5 B3/B4 inventory refresh

## Progress

This docs-only refresh records the Phase 5 B3/B4 test inventory. The
implementation SHA is `782338ffd5ee812b25d9974970876ffa2ec31b15`. The working
and audited head is `d38dad43b2803467137a8ccaca1c409fbb259aa4`.

This record updates the retained Phase 5 test inventory. The inventory covers
the integrated production range from `a1b1f28b592641dbb26333c58ac4c675dd231ec8`
to `782338ffd5ee812b25d9974970876ffa2ec31b15`.

The inventory maps all changed production paths. These paths include the
no-replace move C target, schema v2, activation cleanup, directory validation,
staging recovery, and install-record descriptor guards. The resolver verifies
each mapped path, test name, suite count, and total count.

The containment path now includes `RendererPackageStoreLayout.swift`. Its
lexical traversal regression is
`RendererPackageStoreLayoutTests.containmentRejectsLexicalTraversalWithinRoot`.
The four focused suites map 37 tests: activation 13, directory validation 5,
machine index 13, and store layout 6.

The official Docker image `swift:6.3-noble` ran Swift 6.3.3 on aarch64 Linux.
After it installed `libsqlite3-dev`, `swift build --target WikiFSCoreTests`
passed. The explicit four-suite renderer filter passed 37 tests. The literal
workflow command `swift test --filter WikiFSCoreTests` found 0 tests in this
container. This record does not claim that vacuous command as a pass.

## Deferred recovery

A crash after the no-replace move and before the index commit can leave an
unindexed installed root. The installer lifecycle must reconcile this state
under an exclusive startup barrier or an ownership-and-age lease. This slice
does not add that lifecycle.

Stale-staging recovery also remains deferred to the package-install lifecycle.
`recoverStaging` cannot run from read or activation because a concurrent
install can own a new UUID staging directory.

## Verification

- Four focused suites passed, with 37 tests total: activation (13), directory
  validation (5), machine index (13), and store layout (6).
- The Linux literal workflow filter found 0 tests in 0 suites. This result is
  vacuous and is not a pass.
- The full `make test` run was pending when this entry was written.
