---
timestamp: 2026-08-19T060000Z
title: Cordis agent provider composition
branch: feature/cordis-provider-runtime
status: in-review
---

# Cordis Agent Provider Composition

**Status:** In review

## Progress

This change makes Cordis the process-level composition boundary for agent provider services.

The app and daemon each own one runtime handle. Each process gives agent clients one stable `AgentProviderServices` facade.

## Contracts

`AgentProviderRuntime` provides these public, redacted values:

- typed provider descriptors;
- operation-specific policy values;
- frozen provider and model selections;
- process-local operation tokens;
- typed summary preparation.

The runtime stores private spawn records in actor-owned process memory. Public values do not contain commands, credentials, environment values, paths, prompts, or source content.

The service reads current configuration once at operation start. It freezes each ingest stage model and provider chain.

Fallback uses the frozen chain. It does not reload settings.

Backend reuse uses operation snapshot and provider ID. Planner, executor, and finalizer reuse one backend when the provider ID does not change.

## Composition

`AgentProviderRuntimeAssembly` registers typed Cordis components for configuration, command resolution, credentials, policy, backend construction, and the stable service.

`AgentProviderRuntimeHandle` hides the Cordis context. Handle disposal is idempotent and invalidates outstanding tokens.

`WikiFSApp` injects one facade into queue ingestion, settings, and every wiki session launcher.

`WikiDaemon` injects one facade into daemon queue ingestion, daemon chat, and every daemon launcher.

Assembly failure leaves the facade unavailable. Non-agent app and daemon features remain available.

## Summary boundary

App and daemon summary owners now request summary preparation from the provider service.

Default truncation does not create a backend. Model mode uses one frozen preparation for the pending batch.

Summary owners do not load provider settings, credentials, PATH, or backend profiles.

## Preserved ownership

Cordis does not own these values:

- `AgentLauncher`;
- `WikiSession` or `SessionManager`;
- wiki or queue stores;
- XPC objects;
- active subprocesses or sessions;
- SwiftUI views.

The existing queue runtime, handoff controller, output leases, and daemon ownership epochs do not change.

## Verification

These commands passed before review:

```text
make build
make test
swift build
swift test
swift test --filter StoreConcurrencyTests
WIKIFS_APP_TESTS=1 swift test --filter 'RetryStuckRegressionTests|LocalQueueRuntimeControllerTests|AgentLauncherCeilingWiringTests'
swift test --filter 'AgentProviderRuntime|AgentProviderCompositionBoundaryTests|AgentSummaryProviderBoundaryTests|MessageSummaryTests.unavailableProviderRuntimeFallsBackToDefaultSummary|QuotaFallbackCoordinatorTests|QuotaFallbackIntegrationTests'
swift test --filter 'CordisTests|QueueRuntimeAssemblyTests|QueueAssemblyContractTests|AgentLauncherPermissionModeTests|AgentLauncherStageKeyDispatchTests|ACPWiringTests|WikiDaemonQueueWireTests|LauncherChatAgentRuntime|DaemonChatHost'
```

Results:

- signed app bundle: built successfully;
- full default suite: 3,418 tests in 327 suites;
- review-fix regression gate: 71 tests in 10 suites;
- provider integration gate: 31 tests in six suites;
- Cordis and queue regression gate: 68 tests in 13 suites;
- app provider gate: 12 tests in two suites;
- store concurrency gate: 10 tests;
- real-provider smoke tests remained skipped by their existing opt-in guard.

## Review

The implementation used the OpenAI model family.

A preliminary same-family adversarial review found two high-severity defects:

- daemon queue readiness could admit work before provider assembly completed;
- completed operations retained private snapshots, credentials, tokens, and backend references.

The implementation now rejects daemon queue work until the runtime is ready. It also converts launcher preflight failures into queue failures.

The provider service now releases a complete operation snapshot by token. Release removes all derived tokens, private spawn records, and cached backend references.

Queue completion and daemon chat close await release. A launcher also awaits the prior release before it prepares another operation.

The preliminary re-review found no remaining critical or high issue.

A heterogeneous GLM 5.2 review ran through Paseo with the z.ai Coding Plan. The reviewer verified both high-severity fixes and found no critical or high issue.

The review requested five medium changes:

- preserve the provider-specific model when a chat provider override has no model override;
- preserve default summaries when the provider runtime is unavailable;
- add behavioral tests for the launcher service path and app readiness;
- force headless model summarization to use the bypass policy;
- resolve PATH and credentials once per provider snapshot, not once per stage and provider.

The implementation includes all five changes. It also stores the attempt token before backend creation so preflight cleanup can release failed preparations.

## Remaining work

Daemon cold starts now use one process-local `ChatRuntimePreparedStart`. The controller claims the turn with its redacted request. The launcher consumes its opaque provider preparation without another configuration read.

The Codable `ChatRuntimeStartRequest` remains token-free. Tests verify one configuration read, warm-session reuse, durable provider attribution, and the stable wire shape.

The final GLM re-review verified all five medium fixes and the token-release fix. It found no regression in actor isolation, secret boundaries, or summary batch coherence. The verdict was `APPROVE WITH NON-BLOCKING FINDINGS`.

The remaining low findings cover PATH error-message quality, daemon-only behavioral test gaps, a production test seam, the app runtime-handle state write, and unused thinking metadata. None blocks this pull request.

A follow-up removed the daemon cold-start duplicate configuration read. One process-local preparation now supplies claim attribution and launcher startup. Preflight failure closes the prepared runtime before retry, so a released token cannot become a permanent retry failure.

Follow-up verification passed `make build`, `make test` with 3,421 tests, the 10-test store concurrency gate, bare SwiftPM gates, and 112 focused chat/provider tests. GLM 5.2 reviewed the follow-up, found one medium retry defect, verified its fix, and returned `APPROVE WITH NON-BLOCKING FINDINGS`.

## Provider catalog follow-up

The provider runtime now owns ACP catalog discovery. The Cordis graph registers a typed `agent-provider.catalog-probe` capability.

The runtime resolves the draft provider command and credential through its declared dependencies. It returns only the typed catalog observation.

The provider settings view receives the existing stable facade. It no longer resolves the command or constructs `ACPProviderModelProbe`.

The view still owns draft input, refresh presentation state, and configuration persistence. Cordis does not own SwiftUI or persisted configuration state.

Focused tests cover shuffled registration, dependency routing, missing commands, disposal, the fixed service label, and the removed direct construction path.

Final verification passed `make build`. It also passed `make test` with 3,475 tests in 335 suites.

An independent review found two medium safeguards. The implementation now cancels stale provider refresh tasks and rejects stale completions. A source-policy test also restricts direct `AgentProviderRuntime` construction to the approved assembly file.
