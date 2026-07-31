---
timestamp: 2026-07-31T132000Z
title: Issue #1005 Phase 3 page-source provenance writers
branch: issue-1005-phase-3-page-provenance
status: complete
---

# Issue #1005 Phase 3 page-source provenance writers

## Progress

Added typed page-version source inputs to the page update, CAS, upsert,
workspace, and `wikictl page add` write paths. The store validates duplicate
inputs and missing sources before it writes a blob, activity, version, mirror,
ref, or edge. It writes edges in deterministic role and source-ID order.

Added the transaction-owned page-version writer. The caller owns the outer
transaction and event. The helper does not start a transaction or emit an
event. It distinguishes root seeding from later mirror-version increments, so
a new page remains at mirror version 1. No-op saves do not create a version,
edge, or event. A provenance change prevents an amend.

Added typed provenance deletion blockers. Source deletion queries all durable
page-version edges before it deletes the source. A referenced source returns a
non-empty typed restriction. An unreferenced source still deletes and emits one
source event. The result is input for issue #219. This phase adds no deletion UI.

Added `wikictl page add --source <source-id[:role]>`. The flag can repeat. A
missing role means `primary`. The CLI rejects empty or unknown roles at its
external-format boundary.

## Verification

- `make build` passed, including the signed development app bundle.
- `swift build` passed after the Make prerequisites synchronized generated
  resources.
- Targeted Phase 3 suites passed: 37 tests across
  `PageVersionSourceReadTests`, `PageVersionSourceWriterTests`,
  `ProvenanceDeletionRestrictionTests`, and `AgentCASTests`.
- `make test` passed: 2,842 tests in 229 suites.
- Bare `swift test` passed: 2,842 tests in 229 suites.
- `git diff --check` passed.
