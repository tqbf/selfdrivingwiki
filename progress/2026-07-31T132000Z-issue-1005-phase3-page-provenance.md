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

## AC-30 agent-ingest boundary follow-up

Made the CLI environment merge helper internal for direct coverage. The test
injects `WIKI_INGEST_SOURCE_IDS=a,b` and proves that `a` is primary, `b` is
supporting, and an explicit role for `b` adds evidence without replacing either
automatic edge. A launcher-level test constructs an ordered `.ingest` request
and proves that it serializes the same ordered value for the CLI boundary.

## Exact-head provider-hint and large-source corrective pass

Corrected the launch boundary so ordered ingest provenance is inserted as
`HintKey.env("WIKI_INGEST_SOURCE_IDS")`. `ACPBackend.resolveSpawnConfig` now
exports it into the child environment instead of silently ignoring a raw
provider-hint key.

The large-source planner, serial and parallel executors, finalizer, and
per-provider fallback profiles receive the same queue-derived environment.
`ACPWiringTests` drives a real `.ingest` request through the launcher hint
builder and the production spawn-config resolver. The large-source integration
test runs a two-source planner/executor/finalizer flow with the existing fake
backend, captures both real executor profiles, and verifies that each resolves
`WIKI_INGEST_SOURCE_IDS` to `a,b` in declared queue order.

## Verification

- Final corrective pass: `make build` exited 0 and produced the signed
  development app bundle.
- Final corrective pass: `make test` exited 0 with 2,885 tests in 233 suites.
- Final corrective pass: `swift build` exited 0 after Make prerequisites had
  synchronized generated resources.
- Final corrective pass: bare `swift test` exited 0 with 2,885 tests in 233
  suites.
- `WIKIFS_APP_TESTS=1 swift test --filter '(ACPWiringTests|ACPIngestCollapsedRoutingTests|AgentLauncherStageKeyDispatchTests|PageVersionSourceWriterTests|AgentCASTests|WorkspaceTests|StoreEmissionExhaustivenessTests|PageVersionSourceStoreTests|PageVersionSourceReadTests|ProvenanceDeletionRestrictionTests|PageSourceNamespaceAuditTests|MetadataEventEmissionTests)'`
  exited 0: 126 tests in 12 suites passed. One pre-existing ACP smoke test
  remained intentionally skipped because `ACP_SMOKE` was not set.
- `git diff --check` exited 0. The no-new-`try?` scan was empty.
- The typed-ID audit passed through the named namespace suite and found no
  newly added raw PageID/SourceID comparison. The helper-seam audit found two
  documented legacy migration `page_versions` writes and one helper-owned
  version plus edge writer. The event audit found the required emit-once and
  emit-nothing tests plus public-mutator classification. The scope audit found
  only agent-launcher, test, plan, and progress files: no Phase 4 extraction or
  Phase 5 inspector work.
