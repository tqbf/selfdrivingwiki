---
timestamp: 2026-07-31T171428Z
title: Issue #1005 Phase 1 domain and schema foundation
branch: issue-1005-phase-1-domain-schema
status: complete
---

# Issue #1005 Phase 1 domain and schema foundation

## Progress

Added schema v48 and its guarded v47 upgrade. The upgrade rebuilds durable
chat turns with typed provider/model snapshots and optional usage, verifies
foreign-key enforcement before its immediate transaction, checks final foreign
keys before stamping, and rolls back typed hook/checker failures.

Added typed chat usage, page-version source roles and read models, extraction
provenance projections, and compatibility reads for read-only v47 databases.
Page-source and workspace-source relations are constrained in v48, but writer
threading remains deferred to Phase 3. Chat controller lifecycle wiring,
canonical extraction writers, and inspector UI remain out of this phase.

## Verification

- `make build` passed.
- `make test` passed: 2,780 tests in 224 suites.
- `swift build` passed.
- `swift test` passed: 2,780 tests in 224 suites.
- Focused migration, usage, transition, and page-source reader suites passed.
- Fresh-v48 and upgraded-v47 `sqlite_master` parity passed.
- `git diff --check` passed.
