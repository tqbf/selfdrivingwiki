# Issue #727 — Provider Quota-Exhaustion Detection + Fallback

**Status:** Implementation in progress (slices 1–5).
**Scope:** per-stage fallback chains; **ingestion-only** (chat deferred to a follow-up).
**Detection model:** passive, first-fail (no background polling).

---

## 0. TL;DR

When an agent provider returns a **quota-exhaustion** error, mark that provider
**dead until a reset time**, then **fall through to the next enabled provider** in the
ingestion stage's chain and retry the phase. Surface "exhausted → fallback active" in
the Activity window. All providers exhausted → fail the item with a clear message.

**Critical transport constraint:** the swift-acp SDK talks to agents over **stdio
JSON-RPC**, *not* HTTP. `sendPrompt` throws `ClientError.agentError(JSONRPCError)`
where `JSONRPCError` exposes only `.code: Int`, `.message: String`, and
`.data: AnyCodable?`. There is **no HTTP body, status code, or response header** at
any catch site. Detection operates **solely on the `JSONRPCError`**:

- **Claude:** match quota phrases ("session limit" / "weekly limit" / "Opus limit")
  in `JSONRPCError.message`.
- **z.ai/GLM:** match the numeric exhaustion code (`error.code` ∈ {1310, 1316, 1317,
  1318, 1319, 1308}) on `JSONRPCError.code`, or parse it out of `.message` /
  `.data`. Exclude transient codes {1302, 1305, 1313}.

---

## Architecture

```
ProviderQuotaDetector (pure: Error → QuotaSignal?)        ← WikiFSCore
        │
        ▼
QuotaFallbackCoordinator (dead-until map + chain walk)    ← WikiFSEngine, @MainActor
        │
        ▼
AgentLauncher.runACPIngestPlannerExecutors / runPhase     ← MODIFIED (retry loop)
        │
        ▼
ACPBackend.send() catch block → ACPBackendError.quotaExhausted  ← MODIFIED (detect)
```

**Decision:** the dead-provider map + fallback retry lives in the launcher's
`runACPIngestPlannerExecutors` / `runPhase` seam — NOT inside `ACPBackend`.
`ACPBackend` is a per-subprocess actor; falling back to a different provider means
spawning a new subprocess (a new `ACPBackend` instance).

---

## Slices

1. **Pure detection + config chain** — `TurnFailureReason.quotaExhausted`,
   `ACPBackendError.quotaExhausted`, `ProviderQuotaDetector`,
   `AgentProvidersConfig.providerChain(forStage:)`.
2. **Coordinator** — `QuotaFallbackCoordinator` (@MainActor, dead-provider map).
3. **runPhase typed outcome** — `PhaseOutcome` enum, detect `.turnFailed(.quotaExhausted)`.
4. **Fallback retry loop** — `runPhaseWithFallback`, chain walk, fresh backend per
   attempt, fork reconciliation (forkFrom=nil when executor provider differs from
   planner's actual post-fallback provider).
5. **Activity window surfacing** — verify progress line + transcript render.

---

## Cross-provider fork reconciliation (Slice 4 named step)

The executor's fork-from-planner optimization reuses the planner's backend AND
session. If the planner fell back to a *different provider*, the session handle
references a backend the executor won't use. Reconciliation:

1. Track the provider the planner ACTUALLY used (post-fallback).
2. At executor time, compare the executor's resolved provider to the planner's
   actual provider:
   - **Same provider** → fork is valid. Set `forkFrom = plannerSessionHandle`.
   - **Different provider** → fork is INVALID. Set `forkFrom = nil` and start a
     fresh session on the executor's backend.

---

## Follow-up: Active quota probing (not needed for v1)

Paseo (`~/work/paseo/packages/server/src/services/quota-fetcher/`) uses **active
API polling** instead of passive error-text heuristics:

- **z.ai:** `GET https://api.z.ai/api/biz/subscription/list` (Bearer token from
  `ZAI_API_KEY`/`GLM_API_KEY`). Returns subscription status + validity.
- **Claude:** OAuth credentials from keychain, fetches from Claude's usage API
  (five_hour + seven_day utilization windows with `resets_at` timestamps).

The v1 passive approach (error-text heuristics on `JSONRPCError`) is simpler
and needs no additional auth. The active probe could be used as a follow-up
enhancement for the auto-revive path — instead of guessing reset times (5h/7d
defaults), the coordinator could optionally poll the provider's quota API to
check if a provider has revived. A `ProviderUsageFetcher` protocol (one method:
`fetchUsage() async throws -> ProviderUsage`) would mirror paseo's interface.

| File | Change |
|------|--------|
| `Sources/WikiFSCore/Core/AgentEvent.swift` | + `TurnFailureReason.quotaExhausted` |
| `Sources/WikiFSCore/Core/AgentProvidersConfig.swift` | + `providerChain(forStage:)` |
| `Sources/WikiFSCore/ProviderQuotaDetector.swift` | **NEW** — pure detection |
| `Sources/WikiFSEngine/HintKey.swift` | + `acpProviderId` case |
| `Sources/WikiFSEngine/AgentBackendFactory.swift` | + `providerId` param on `providerHints` |
| `Sources/WikiFSEngine/ACPBackend.swift` | + `.quotaExhausted` case, + `turnEndEvents` mapping, + detection in send catch, + stored `providerId` |
| `Sources/WikiFSEngine/QuotaFallbackCoordinator.swift` | **NEW** — dead-provider map |
| `Sources/WikiFSEngine/AgentLauncher.swift` | `runPhase` → `PhaseOutcome`, + `runPhaseWithFallback`, chain resolution |
| `Tests/WikiFSTests/FakeAgentBackend.swift` | + `recordedProfiles` |
| `Tests/WikiFSTests/ProviderQuotaDetectorTests.swift` | **NEW** |
| `Tests/WikiFSTests/QuotaFallbackCoordinatorTests.swift` | **NEW** |
| `Tests/WikiFSTests/QuotaFallbackIntegrationTests.swift` | **NEW** |
