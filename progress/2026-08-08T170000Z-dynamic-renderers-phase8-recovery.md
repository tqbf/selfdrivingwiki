---
timestamp: 2026-08-08T170000Z
title: Dynamic renderers Phase 8 recovery
branch: feature/dynamic-renderers-08-import-ux
status: final-gates-blocked-voiceover-and-approval
issue: 1026
phase: 8
base_sha: 609dc66f0e0b13c298ab528e46fdf74bf4a420ce
head_sha: 2e097ee5c0ab9309e5463ef6a78f14b7156545f4
---

# Dynamic renderers Phase 8 recovery

## Progress

The recovered implementation and its focused evidence are finalized on the
exact Phase 8 implementation head. The remaining release blockers are the
host-capability-blocked manual VoiceOver matrix and the required operator
approval on the exact PR head.

## Reconciliation

The retained Phase 8 work was reconciled against integrated Phase 7 main in a
disposable worktree. Ten conflicts were resolved using the approved Phase 8
semantics, including removal of per-wiki enablement controls, directory-only
import wording, validator-backed bundled Excalidraw bootstrap, and coordinated
same-hash activation. Recovery refs preserve the retained commits, pre-merge
snapshot, integrated main, and resolved candidate.

## Exact-head evidence

The implementation branch is clean at
`2e097ee5c0ab9309e5463ef6a78f14b7156545f4`, based on
`609dc66f0e0b13c298ab528e46fdf74bf4a420ce`. The updated machine-readable
inventory maps changed production symbols and success, error, boundary,
cancellation, and teardown paths to named tests.

The focused renderer settings, bootstrap, activation, staging, and
documentation suites passed after the bounded Foundation import, exact
expectation repairs, accessibility/status coverage, and bounded WIKI_STATE
reference change. The earlier exact-head gates were invalidated by those
changes and are being recorded again against the final pushed head.

## Verification

- The focused renderer settings, bootstrap, activation, staging, and
  documentation suites pass on the implementation head.
- \`make build\` passes and the moved app contains the Excalidraw package plus
  the bounded WIKI_STATE reference in the app, File Provider extension, and
  wikid XPC resources.
- \`make test\` passes: 3,261 tests in 293 suites.
- The final manual VoiceOver matrix remains blocked because the protected
  app-group registry prevents the runner from exposing an accessible window;
  it is not converted into an automated pass.
- PR approval is intentionally absent until the operator or a configured
  reviewer records approval on the final exact head.

## Scope boundary

This recovery does not add a renderer catalog, remote distribution, signing,
archives, destination selection, new package architecture, generic chat skill
execution, sandbox/plugin mutation, or security weakening. The runtime chat
payload is the bounded reference rather than the full maintainer guide, so the
recovery does not inflate generic chat context with maintainer instructions.
