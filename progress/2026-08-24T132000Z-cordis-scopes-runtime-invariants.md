---
timestamp: 2026-08-24T132000Z
title: Cordis scope diagnostics and runtime invariants
branch: feature/cordis-scope-invariants
status: complete
---

# Cordis Scope Diagnostics and Runtime Invariants

Date: 2026-08-24

## Progress

### Delivered architecture

The implementation extends the existing Cordis context tree.

`ContextID` remains the runtime identity. `ContextRecord.parentID` remains the only parent relationship. Cordis disposal remains the only scope lifetime boundary.

Process roots now carry typed app or daemon descriptors. Per-wiki child profiles carry `WikiID` descriptors before configuration and activation.

The Cordis actor returns immutable scope snapshots. Snapshots include context identity, parent identity, descriptors, lifecycle, child count, and active registration count.

The invariant registry validates immutable filters and reserves typed owner labels. Each selected installer owns one child Cordis context. Failed installation disposes the child before owner reuse. The returned disposer is asynchronous and idempotent.

Violation sinks are nonthrowing. Tests use a deterministic lock-backed recorder. Production reporting uses `DebugLog`.

The wiki identity snapshot compares available scope, profile, session, store, event bus, database, and host identities. App and daemon host associations use a tagged enum.

`WikiEventBus` calls an optional diagnostic observer after sequence stamping and before asynchronous fan-out. The observer reports wrong wiki IDs and non-increasing sequences.

Queue and extraction services remain process-owned.

## Renderer authority

The shared built-in renderer factory input no longer exposes `WikiStoreModel`.

The Mermaid fallback receives a prepared `AnyView` projection. JSON Canvas receives a narrow action closure for the closed `JSONCanvasHostAction` enum.

Installed package protocol version 1 remains closed to `input.read`. Optional external links still use the trusted activation adapter. Existing navigation, CSP, nonce, replay, and session-isolation rules remain unchanged.

## Compatibility

Scope descriptors and invariant violations are runtime diagnostics. They are not Codable. They do not enter SQLite schemas or wire formats.

The public undescribed Cordis root initializer remains available for standalone runtimes and tests.

Page, rendering-job, chat, queue-item, and convergence scopes remain deferred. The design record defines their evidence gates.

## Verification

### Focused verification

The following focused gates passed:

- 5 scope descriptor and diagnostics tests
- 6 invariant registry and sink tests
- 7 composition and lifecycle tests
- 16 event and registry tests
- 14 identity, event, and app profile tests
- 22 renderer capability, bridge, navigation, and activation tests
- 18 Cordis boundary, compatibility, process ownership, and renderer policy tests

Existing `WikiEventBusTests`, `AppProfileBootTests`, `ProfileLifetimeTests`, and `ProcessPluginDependencyTests` pass in these focused runs.

### Full gates

The following repository gates passed:

- `make build`
- `swift build`
- `make test`: 3,613 tests in 370 suites
- `swift test`: 3,613 tests in 370 suites
- `git diff --check`
- language-server diagnostics for the changed scope, invariant, event, identity, and renderer files
- gated hosted renderer run with `WIKIFS_APP_TESTS=1`, `WIKIFS_RENDERER_SESSION_ISOLATION_TESTS=1`, and `WIKIFS_RENDERER_HOSTED_NETWORK_TESTS=1`: 30 tests passed

The first `make test` run found only missing progress-file front matter. The progress contract passed after the file followed `progress/TEMPLATE.md`.

### Mutation and review

The scoped Cordis mutation run completed in 12 minutes and 58 seconds. It reported a 100% score. The run killed two mutants, had no survivors, and had 338 unviable mutants. This result supports the focused tests but does not replace them.

The first independent review found missing production installation. It also found an owner-release edge case. The implementation now installs process-owned diagnostics for app and daemon profiles. It releases an invariant owner after terminal disposal, including cleanup failure.

The final concurrency review found coordinator startup races and a non-transactional event observer. The implementation now uses one owned coordinator startup task. It checks lifetime state after each suspension and cleans late startup results. Event observers use identity-scoped removal. Observer installation removes itself if Cordis rejects cleanup admission.

A blocker-only follow-up review found no remaining blockers.

### Fixture and policy corrections

The hosted renderer test helper changed the committed app profile while it edited a copied fixture. The committed profile now keeps `renderer-services` enabled. The exact fixture test and the focused profile suites pass.

The Cordis source policy now permits `RuntimeInvariantCoordinator.swift` as one explicit composition root. Application facades still cannot expose a Cordis context.

### Final delivery gates

The reviewed code passed these commands:

- `make build`
- `swift build`
- `make test`
- `swift test`

The final test suite ran 3,615 tests in 370 suites.

## Delivery

Commit `8b8c67c3` created the initial delivery. The branch is pushed, and pull request #1146 is open.

The pull request does not enable auto-merge. The operator owns the merge decision.
