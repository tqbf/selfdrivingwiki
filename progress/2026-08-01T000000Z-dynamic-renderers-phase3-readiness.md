---
timestamp: 2026-08-01T000000Z
title: Dynamic renderers Phase 3 readiness handoff
branch: chore/dynamic-renderers-phase3-readiness
status: complete
---

# Dynamic renderers Phase 3 readiness handoff

## Progress

Added [`plans/dynamic-renderers-phase3-readiness.md`](../plans/dynamic-renderers-phase3-readiness.md) and indexed it in [`PLAN.md`](../PLAN.md). The note records the required dependency on PR #1062, the v49 migration position before the GRDB fallback, and the matching fresh-schema update.

It also records the machine package-store coordination options and required evidence, durable wiki and machine structures, named lease and retention policy constants without numeric values, payload-free Darwin routing, File Provider and Tantivy isolation, and the serialized cross-process test contract.

Unresolved coordination and policy values remain decisions for Phase 3 bootstrap. The note does not change the reviewed implementation requirements.

## Verification

- Read `AGENTS.md`, `PLAN.md`, `progress/README.md`, `progress/TEMPLATE.md`, `plans/dynamic-renderers.md`, and `plans/dynamic-renderers-implementation.md` PR 3.
- Read the current `GRDBWikiStore`, `StoreBackend`, `WikiChangeNotification`, `DarwinNotifier`, `WikiEventBus`, and GRDB adoption guidance.
- Confirmed PR [#1062](https://github.com/tqbf/selfdrivingwiki/pull/1062) is open with head `feature/dynamic-renderers-02-builtins`.
- Confirmed the worktree changes are documentation-only.
