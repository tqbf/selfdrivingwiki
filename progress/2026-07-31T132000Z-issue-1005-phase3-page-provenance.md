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

## Corrective pass for PR #1013

Centralized every page-version creation seam in
`createPageVersionWithProvenance(on:request:)`. Workspace writes, staged-page
minting, diff3 merge, workspace refresh, and conflict resolution now use the
same transaction-owned helper as main-page writes. The helper carries the
publication target, merge parent, and activity metadata. It does not open a
nested transaction or emit an event.

Added the reviewed manifest suites for store edges, typed-ID namespace audits,
writer seams, deletion restrictions, event emission, and mutator emission
classification. The source audit permits only the helper and two documented
legacy migration backfills to write `page_versions` directly.

The agent launcher now passes the ordered ingest queue source IDs to `wikictl`.
The CLI decodes that external value to typed inputs. The assigned source is
primary. Remaining distinct sources are supporting. Explicit `--source` flags
remain compatible and can add roles, but cannot remove the assigned evidence.

The Issue #219 handoff remains data-only. `Issue219DeletionAnalysisInput`
preserves the complete typed, ordered provenance blocker collection. This pass
adds no deletion UI, warning, recovery, or navigation.

## Verification

- Corrective pass: `make build` passed, including the signed development app
  bundle.
- `swift build` passed after the Make prerequisites synchronized generated
  resources.
- Targeted corrective suites passed: 85 tests across
  `PageVersionSourceStoreTests`, `PageSourceNamespaceAuditTests`,
  `PageVersionSourceWriterTests`, `ProvenanceDeletionRestrictionTests`,
  `MetadataEventEmissionTests`, `StoreEmissionExhaustivenessTests`,
  `AgentCASTests`, and `WorkspaceTests`.
- Corrective `make test` passed: 2,883 tests in 233 suites.
- Corrective bare `swift test` passed: 2,883 tests in 233 suites.
- `git diff --check` passed.
- Typed-ID audit found no raw PageID/SourceID comparison in the scoped
  provenance production code. The helper-seam audit found two legacy migration
  `page_versions` writes and one helper-owned version plus edge writer. The
  event and scope audits passed; no Phase 4 extraction or Phase 5 inspector
  files changed.
