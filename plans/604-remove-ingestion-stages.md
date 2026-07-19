# Plan: Remove "Ingestion Stages" section + plumbing (#604)

> **Issue:** https://github.com/tqbf/selfdrivingwiki/issues/604
> **Scope chosen by operator:** FULL — UI section **AND** `stageAssignments`
> plumbing on `AgentProvidersConfig` **AND** `resolvedProvider(for:)` routing
> in `AgentLauncher`. Every ingest stage (planner/executor/finalizer) will use
> the **app default provider** going forward.
> **Branch:** `feature/remove-ingestion-stages`
> **House rules:** never merge to `main`; `DebugLog` not `print`; no bare
> `try?`; Swift Testing for new/changed tests.

---

## 1. Problem statement

The Agent settings tab exposes an "Ingestion Stages" `Section`
(`AgentsSettingsView.stagesSection`) that lets a user assign a provider/model
per ingest stage (Planner / Executor / Finalizer). This knob
(`AgentProvidersConfig.stageAssignments` + `resolvedProvider(for:)`) is
operator-facing complexity with no proven value, and it doubles the routing
surface the launcher must maintain (`StageRouting`, `resolveStageRouting`,
`stageBackendCache`). The operator has decided to remove the per-stage
assignment entirely: all three stages now resolve to the **app default
provider** + its `selectedModelId`, identical to the single-session ACP ingest
and the interactive chat path.

The three-stage *architecture* (planner → executors → finalizer) stays. Only
the per-stage *provider/model assignment* goes.

### Why collapse the per-stage backend too (the simplification decision)

`resolveStageRouting` builds a `StageRouting` per stage and caches backends in
`stageBackendCache` keyed by `providerId|modelId`. **When `stageAssignments`
is always empty, `resolvedProvider(for:)` always returns
`(selectedProvider(), selectedModelId(forProvider: selectedProvider().id))` —
i.e. the SAME `(provider, modelId)` for planner, executor, and finalizer.**
Therefore the cache always has **exactly one entry**, and all three phases
share one backend instance.

Keeping the `StageRouting` / `resolveStageRouting` / `stageBackendCache`
scaffolding would be dead indirection: a single-keyed cache wrapping a single
provider resolution that the single-session path already does inline. The
**simpler correct shape** is to resolve ONE backend at the top of
`runACPIngestPlannerExecutors` using the *same* pattern the single-session
`run()` path already uses (`AgentLauncher.swift`:950-965):

```swift
let provider = resolveSelectedProvider()
self.backend = resolveBackend(policy, permissionBudget)
guard let spawn = resolveACPProviderSpawn(provider) else { … }
// SpawnModelGuard.validate(provider:modelId:) — refuse spawn without a model
let modelId = providersConfig().selectedModelId(forProvider: provider.id)
let providerHints = AgentBackendFactory.providerHints(
    provider: provider, resolvedCommand: spawn.command,
    apiKey: spawn.apiKey, selectedModelId: modelId)
```

…then pass `(backend, provider, providerHints)` into the planner, executor,
and finalizer phases directly (each still calls `backend.start()` / `send()` /
`closeSession()` independently — the Phase-3 session-efficiency lifecycle is
unchanged; only the *backend cache* is gone because there's exactly one backend
by construction).

**Justification:**
- Same provider + same model ⇒ one backend instance. A dict that always holds
  one entry is a struct.
- The single-session `run()` path proves this resolution pattern is correct and
  already guarded by `SpawnModelGuard`.
- Removes the `StageRouting` struct, the `resolveStageRouting` method, the
  `stageBackendCache` local, and the trailing `for (_, backend) in
  stageBackendCache { await backend.cancel(…) }` teardown — one `self.backend`
  to cancel instead.
- The `runACPIngestFallback(routing:)` helper takes a `StageRouting`; it now
  takes `(backend:provider:providerHints:)` directly (or a small private tuple
  the implementer may keep for readability — not a public type).

> **What stays:** the fork-from-planner optimization in executors
> (`plannerSessionHandle`), the parallel-executor dispatch
> (`runParallelExecutors`), `runPhase`, `closePlannerSession`, and the whole
> multi-phase orchestration. The change is purely "where the backend + provider
> + hints come from."

---

## 2. Files & concrete implementation steps

### 2a. `Sources/WikiFSCore/Sources/IngestStage.swift` — DELETE THE FILE

`IngestStage` (enum: `.planner/.executor/.finalizer`) and `StageAssignment`
(struct: `providerId`, `modelId`) are used **only** by the stage-routing
surface being removed (verified by `rg -n 'IngestStage|StageAssignment'`):
- `AgentProvidersConfig.stageAssignments` field + `resolvedProvider(for:)`
- `AgentsSettingsView` stage pickers
- `AgentLauncher.resolveStageRouting` (3 call sites: planner/executor/finalizer)
- The tests covering that surface

No non-stage consumer references either type. **Delete the whole file.** (If
SwiftPM complains about a dangling target member, remove it from any
`Sources/…` directory glob — SwiftPM auto-includes by directory, so deleting
the file is sufficient.)

### 2b. `Sources/WikiFSCore/Core/AgentProvidersConfig.swift`

1. **Field (line 61):** delete
   `public var stageAssignments: [IngestStage: StageAssignment]` and its doc
   comment (lines 56-61).
2. **`init` (lines 69-88):** drop the `stageAssignments:` parameter (line 74)
   and the `self.stageAssignments = stageAssignments.filter { … }` assignment
   + pruning block (lines 82-86). The `normalizedProviders` let-binding is now
   only used for `self.providers`; keep it (it still feeds the `normalized`
   invariant). The pruning-on-construct was exclusively for stale stage
   assignments — with the field gone, nothing to prune here.
3. **`CodingKeys` (line 97):** delete `case stageAssignments`.
4. **`init(from:)` (lines 101-120):** delete the whole `stageAssignments`
   decode block (lines 112-117).
   - **LEGACY KEY HANDLING (migration):** because the `CodingKeys` enum no
     longer lists `stageAssignments`, a legacy config file that *still
     contains* a `"stageAssignments"` JSON key will have that key **ignored by
     `JSONDecoder`** (unknown keys are skipped, not error'd). Decoding
     succeeds; the data is silently dropped. **This is the desired, documented
     behavior** — no `.decodeIfPresent` needed because the key isn't in
     `CodingKeys` at all. Document this in a code comment at the decode site
     for future maintainers ("a legacy `stageAssignments` key in
     `agent-providers.json` is silently ignored — unknown CodingKey").
5. **Mutators that re-thread the field** — remove the `stageAssignments:`
   argument from each `AgentProvidersConfig(...)` call inside:
   - `settingDefault(id:)` (line 203)
   - `settingCachedModels(_:forProvider:)` (line 250)
   - `settingSelectedModel(_:forProvider:)` (line 271)
   - `togglingFavoriteModel(_:forProvider:)` (line 309)
   - `loadOrSeed(from:)` (line 389)
6. **`resolvedProvider(for:)` (lines 319-328):** DELETE the whole method + its
   `// MARK: - Ingestion stage routing` header (lines 313-328).
7. **`seed(discovered:)` (lines 345-349):** already doesn't pass
   `stageAssignments` (uses the default-`[:] param). After step 2 removes the
   param, this call site needs no change — but verify the compiler agrees (it
   passes only `providers:` + `selectedModelIds:`, so it's clean).

> **Net on the init:** the signature goes from 6 params to 5
> (`providers, providerModels, selectedModelIds, favoriteModelIds,
> maxConcurrent`). Every call site in the codebase that constructs
> `AgentProvidersConfig` must drop `stageAssignments:` — see §2c/§2d for the
> UI, and grep `AgentProvidersConfig(` across the repo to catch any missed
> call sites (e.g. tests).

### 2c. `Sources/WikiFS/Settings/AgentsSettingsView.swift`

1. **`stagesSection` (lines 332-344):** DELETE the `private var stagesSection:
   some View { … }` entirely, including its `Section { stageRow… } header {
   Text("Ingestion Stages") } footer { … }`.
2. **Remove the call site of `stagesSection`** from the view body. Find
   `stagesSection` referenced in the `body`/`Form` composition (above line
   330) and delete that single `stagesSection` reference line. (The other
   sections — `permissionSection`, the providers list, etc. — stay.)
3. **`stageRow(_:label:)` (lines 346-374):** DELETE the method.
4. **`providerPickerBinding(for:)` (lines 376-393):** DELETE the method.
5. **`modelPickerBinding(for:)` (lines 395-409):** DELETE the method.
6. **Five `AgentProvidersConfig(...)` call sites that re-thread the field** —
   each currently passes `stageAssignments: updated.stageAssignments` or
   `stageAssignments: config.stageAssignments`. Drop that argument from each:
   - `enabledBinding(for:)` setter (line 226)
   - `applyEdit(_:)` (line 258)
   - `addSeed(_:)` (line 276)
   - `addCustom()` (line 301)
   - `confirmDelete()` (line 323)

   The pre-existing comment on `confirmDelete()` ("re-normalizes … and prunes
   now-orphaned stage assignments") should be trimmed to just the
   re-normalization note — the pruning half no longer applies.
7. Leave **all other** `@AppStorage` pickers (e.g. the per-operation permission
   pickers from #606/#607) untouched.

### 2d. `Sources/WikiFSEngine/AgentLauncher.swift`

1. **`StageRouting` private struct (lines 1175-1180):** DELETE.
2. **`resolveStageRouting(_:policy:budget:cache:)` (lines 1182-1220):** DELETE.
3. **`runACPIngestPlannerExecutors` (lines 1222-1488):** rewrite the backend
   resolution to resolve ONCE at the top, then thread `backend`/`provider`/
   `providerHints` through the phases. Concretely, near the top of the method
   (after the `policy`/`permissionBudget` lines ~1266-1267 and before the
   `makeCLIProfile` closure), resolve exactly like the single-session `run()`
   path:

   ```swift
   let provider = resolveSelectedProvider()
   let modelId = providersConfig().selectedModelId(forProvider: provider.id)
   // NOTE: `run()` at AgentLauncher.swift:954 has ALREADY assigned self.backend =
   // resolveBackend(policy, permissionBudget) before delegating to this method at
   // :1022. Do NOT call resolveBackend again here — REUSE self.backend from run()
   // (overwriting would orphan the ACPBackend actor run() already built, even
   // though ACPBackend spawns lazily on backend.start() so no subprocess leaks).
   // The provider/model/spawn/providerHints below are CHEAP to re-resolve here
   // (no actor construction), so re-derive them. If you restructure run() to pass
   // them in, even better — but reusing self.backend is the load-bearing rule.
   guard let backend = self.backend else { ... }   // or just use self.backend directly
   guard let spawn = resolveACPProviderSpawn(provider) else {
       DebugLog.agent("runACPIngest: ACP exe missing — aborting")
       finish(status: -1)
       return
   }
   if let msg = SpawnModelGuard.validate(provider: provider, modelId: modelId) {
       preflightError = msg
       finish(status: -1)
       return
   }
   let providerHints = AgentBackendFactory.providerHints(
       provider: provider, resolvedCommand: spawn.command,
       apiKey: spawn.apiKey, selectedModelId: modelId)
   ```

   Then delete `var stageBackendCache: [String: AgentBackend] = [:]` (line 1268)
   and replace each `resolveStageRouting(.planner/executor/finalizer, …)` call
   with direct use of the resolved `backend`/`provider`/`providerHints`:
   - **Planner (line 1283):** drop the `guard let plannerRouting =
     resolveStageRouting(...)` block; use `self.backend`, `provider`,
     `providerHints` directly. `plannerProfile` already reads
     `plannerRouting.providerHints` → change to `providerHints`. The
     `plannerSession`/`captureAndCacheModels`/`captureProcessID` calls that
     read `plannerRouting.provider` → `provider`.
   - **Executor (line 1351):** the `if let executorRouting =
     resolveStageRouting(.executor, …)` block becomes a non-optional run
     (there's no per-stage failure to gate on anymore — the resolution already
     happened once at the top and either succeeded or `finish()`-ed early). Use
     `self.backend`, `provider`, `providerHints`. `runParallelExecutors(
     executorRouting: StageRouting, …)` (line 1513) changes signature to
     `(backend: AgentBackend, provider: AgentProvider, providerHints:
     [String: String], …)` — update its body's `executorRouting.backend` →
     `backend`, `executorRouting.provider` → `provider` (used in the
     `providerLabel:` arg at line 1560).
   - **Finalizer (line 1444):** same pattern — the `guard let finalizerRouting
     = resolveStageRouting(.finalizer, …)` block goes; use the resolved
     `backend`/`provider`/`providerHints` directly.
   - **Teardown (lines 1483-1485):** the `for (_, backend) in stageBackendCache
     { await backend.cancel(SessionHandle(id: "")) }` collapse to a single
     `await self.backend?.cancel(SessionHandle(id: ""))` (or guard on
     `self.backend` non-nil — match how `run()`'s own teardown cancels).
4. **`runACPIngestFallback(routing:)` (lines 1773-1800):** change signature from
   `routing: StageRouting` to a decomposition: `(backend: AgentBackend,
   provider: AgentProvider, providerHints: [String: String])` (or a small
   private struct if the implementer prefers readability — but NOT the deleted
   `StageRouting`). Its body reads `routing.providerHints`/`routing.backend`/
   `routing.provider` → swap to the named params. Both call sites in
   `runACPIngestPlannerExecutors` (plan-load + planner-failure fallbacks,
   lines 1308-1314 and 1339-1345) pass the now-resolved local
   `backend/provider/providerHints` instead of `plannerRouting`.
5. **Comment cleanup:** the comment at line 2175 ("Mirrors the ingest path's
   `resolveStageRouting` guard") references a method being deleted — update it
   to reference the new inline `SpawnModelGuard.validate` in
   `runACPIngestPlannerExecutors` (or just "the ingest path's
   `SpawnModelGuard` guard").
6. **`AgentBackendFactory`** — no stage-specific calls exist (the factory is
   provider-driven, not stage-driven). The only `providerHints` calls in the
   launcher are the one in the single-session path (line 1047) and the ones in
   the deleted `resolveStageRouting`; the new top-of-method call reuses the
   factory directly. **No change to `AgentBackendFactory.swift`.** (Grep
   confirmed: `rg -n 'stage|Stage' Sources/WikiFSEngine/AgentBackendFactory.swift`
   returns nothing.)

> **Verification the collapse is safe:** the only behavioral difference is that
> `stageBackendCache` could (in the old per-stage world) hold >1 backend when
> stages resolved to *different* providers. With `stageAssignments` removed,
> that multi-entry case is impossible by construction. The teardown loop over
> the cache becomes equivalent to cancelling the single `self.backend`.
> Fork-from-planner (`plannerSessionHandle`) is independent of backend caching —
> it forks a *session* from the planner's session handle, not a separate backend
> instance, so it is unaffected.

### 2e. `Tests/WikiFSTests/AgentProviderModelTests.swift`

These tests live in `AgentProvidersConfigPhase1Tests` (the suite doc at line
369 mentions "IngestStage/StageAssignment resolution + fallback + pruning").

**DELETE (assert per-stage routing that no longer exists):**
- `resolvedProviderUsesStageAssignment` (line 435) — asserts a stage assignment
  routes to a non-default provider.
- `resolvedProviderFallsBackToSelectedModelIdWhenAssignmentHasNoModel` (line 447)
- `resolvedProviderFallsBackToSelectedProviderWhenStageUnassigned` (line 460)
- `stageAssignmentPrunedWhenProviderDeleted` (line 470)
- `stageAssignmentPrunedWhenProviderDisabled` (line 489)

**REFACTOR (keep the intent, move off the removed API):**
- `resolvedProviderReturnsNilModelWhenNothingConfigured` (line 221): rename to
  e.g. `selectedModelIdIsNilWhenNothingConfigured`; replace
  `config.resolvedProvider(for: .planner)` with the direct resolution
  `let provider = config.selectedProvider(); let modelId =
  config.selectedModelId(forProvider: provider.id)`. Assert the same
  `provider.id == "opencode"` and `modelId == nil`. This pins the
  `SpawnModelGuard` precondition, which is the load-bearing correctness the
  plan must preserve.
- `oldJSONWithoutStageAssignmentsDecodes` (line 377): rename to
  `legacyJSONWithStagesKeyDecodesAndIgnoresIt` and **flip the payload to
  INclude** a stale `"stageAssignments"` key (e.g.
  `"stageAssignments":{"planner":{"providerId":"hermes","modelId":"x"}}`).
  Assert decoding succeeds, `loaded.providers` is intact, and there is no
  `stageAssignments` property to read anymore (just assert the providers +
  that `loaded.selectedProvider().id == "claude-acp"`). This is the
  migration-shim test — it pins "a legacy config with a stale stages key
  decodes cleanly and the key is ignored."

**KEEP unchanged:** `testProviderHints…` tests in `ACPIngestPlanTests` (they
exercise `AgentBackendFactory.providerHints`, which is not stage routing).
Also keep the non-stage `AgentProvidersConfig` tests (reseed, default
promotion, etc.).

### 2f. `Tests/WikiFSTests/ACPIngestPlanTests.swift`

**DELETE (assert per-stage routing):**
- `testResolvedProviderPerStageCanDiffer` (line 226) — the whole premise
  (stages routing to different providers) is the removed feature.
- `testResolvedProviderFallsBackWhenAssignedProviderDisabled` (line 249) —
  same; the disabled-provider-fallback was a stage-assignment pruning test.

**KEEP:** the rest of the suite (the `ACPIngestPlan` load/parse tests,
`testProviderHintsIncludesProviderEnv`, `testProviderHintsThreadsSelectedModelId`,
etc.).

### 2g. Add a NEW behavior test (Swift Testing)

The load-bearing correctness change is: **"all ingest stages use the app
default provider + its selected model."** Since `resolvedProvider(for:)` is
gone, pin this at the launcher-resolution seam instead — a pure unit test on
`AgentProvidersConfig` only:

```swift
@Test func ingestStagesResolveToAppDefaultProvider() {
    // After #604, stage routing is gone: the launcher resolves ONE
    // (provider, modelId) pair via selectedProvider() + selectedModelId,
    // and all three phases share it. Pin that this pair is what the
    // (removed) per-stage resolution would have returned, so a future
    // re-add of per-stage routing doesn't silently bypass the default.
    let config = AgentProvidersConfig(
        providers: [
            AgentProvider(id: "claude-acp", label: "Claude", command: ["bun"], enabled: true, isDefault: true),
            AgentProvider(id: "hermes", label: "Hermes", command: ["hermes","acp"], enabled: true, isDefault: false),
        ],
        selectedModelIds: ["claude-acp": "sonnet"])
    let provider = config.selectedProvider()
    let modelId = config.selectedModelId(forProvider: provider.id)
    #expect(provider.id == "claude-acp")
    #expect(modelId == "sonnet")
    // The planner/executor/finalizer no longer have a distinct API;
    // they all use this single resolution.
}
```

(This config-level test guards the "always app-default" invariant at the config
layer, but it would pass even if the launcher's per-stage routing were
reintroduced — it does NOT pin the launcher-level collapse. **Add a
launcher-level test** using the existing `ACPIngestPlanTests` infra (which
already has a `FakeAgentBackend recording` at ~:289) plus the injectable seams
on `AgentLauncher` (`backend` at `:193`, `resolveBackend` at `:205`). Stub
`resolveBackend` to return a `FakeAgentBackend`, call (or extract) the
resolution step of `runACPIngestPlannerExecutors`, and assert:
- exactly ONE backend instance was constructed (not one per stage)
- the fork-from-planner happens on that same instance (SessionHandle fork, not
  a fresh backend)
This pins the collapsed-resolution change at the layer it actually lives.
Without this test, the "multi-phase ingest still works end-to-end" AC is verified
by compilation only — note that explicitly in Risks if the launcher test is
deferred.)

### 2h. Repo-wide compile sweep

After the edits, run `rg -n 'stageAssignments|resolvedProvider\(for:|IngestStage|StageAssignment|StageRouting|resolveStageRouting|stageBackendCache' Sources/ Tests/`
and confirm **zero hits**. Any straggler (a test helper, a doc comment, a plan
reference in `plans/`) must be updated — though docs/plans describing the *old*
behavior can be left as historical (note in the PR which plan docs referenced
per-stage routing, e.g. `plans/acp-multi-provider.md`).

---

## 3. Migration

**Existing `agent-providers.json` files with a `"stageAssignments"` key must
not break decoding.**

- **Behavior:** `AgentProvidersConfig.CodingKeys` no longer enumerates
  `stageAssignments`. Swift's `JSONDecoder` ignores unknown keys by default,
  so a legacy file decodes successfully and the stale `stageAssignments`
  value is silently dropped. On next save, the file is re-serialized WITHOUT
  the `stageAssignments` key (the field is gone), so the legacy key is
  naturally migrated away the first time the config is written after this
  change.
- **Implementation:** nothing `decodeIfPresent`-style is needed — removing the
  `CodingKeys` case is sufficient. Add the code comment described in §2b step 4
  at the decode site so future maintainers know the legacy key is intentionally
  ignored.
- **Test:** `legacyJSONWithStagesKeyDecodesAndIgnoresIt` (the refactor of the
  old `oldJSONWithoutStageAssignmentsDecodes` test, §2e) pins this: feed a JSON
  blob *with* a `stageAssignments` key, assert decoding succeeds and the
  providers are intact.

No `migrate(from:)` ladder change is needed — this config is plain JSON
sidecar, not a SQLite schema version.

---

## 4. Test plan (Swift Testing)

| Suite | Action | Reason |
|---|---|---|
| `AgentProvidersConfigPhase1Tests.resolvedProviderUsesStageAssignment` | DELETE | Removed API |
| `…resolvedProviderFallsBackToSelectedModelIdWhenAssignmentHasNoModel` | DELETE | Removed API |
| `…resolvedProviderFallsBackToSelectedProviderWhenStageUnassigned` | DELETE | Removed API |
| `…stageAssignmentPrunedWhenProviderDeleted` | DELETE | Field gone |
| `…stageAssignmentPrunedWhenProviderDisabled` | DELETE | Field gone |
| `…resolvedProviderReturnsNilModelWhenNothingConfigured` | REFACTOR → `selectedModelIdIsNilWhenNothingConfigured` | Keep SpawnModelGuard precondition; use direct `selectedProvider()`/`selectedModelId(forProvider:)` |
| `…oldJSONWithoutStageAssignmentsDecodes` | REFACTOR → `legacyJSONWithStagesKeyDecodesAndIgnoresIt` | Migration shim: feed a *stages-keyed* legacy blob, assert decode succeeds + key ignored |
| `ACPIngestPlanTests.testResolvedProviderPerStageCanDiffer` | DELETE | Removed feature |
| `ACPIngestPlanTests.testResolvedProviderFallsBackWhenAssignedProviderDisabled` | DELETE | Removed feature |
| NEW `AgentProvidersConfigPhase1Tests.ingestStagesResolveToAppDefaultProvider` | ADD | Pin "all stages = app default" invariant |
| `ACPIngestPlanTests.testProviderHints*` | KEEP | Exercises `AgentBackendFactory`, not stage routing |

**Run locally before PR:**
```bash
swift test --filter 'AgentProvidersConfigPhase1Tests|ACPIngestPlanTests|AgentProviderModelTests'
make prompts && swift build
swift test   # full (or the fast-tier skip set from CI)
```

---

## 5. Acceptance criteria

- [ ] "Ingestion Stages" `Section` is gone from Settings → Agents tab; no
      "Planner/Executor/Finalizer" rows remain.
- [ ] `stagesSection`, `stageRow`, `providerPickerBinding(for:)`,
      `modelPickerBinding(for:)` are deleted from `AgentsSettingsView.swift`;
      the 5 init call sites in that file no longer pass `stageAssignments:`.
- [ ] `AgentProvidersConfig` has no `stageAssignments` field, no
      `stageAssignments:` init param, no `stageAssignments` `CodingKeys` case,
      and no `resolvedProvider(for:)` method.
- [ ] `Sources/WikiFSCore/Sources/IngestStage.swift` is deleted (`IngestStage` +
      `StageAssignment` types gone).
- [ ] `AgentLauncher` has no `StageRouting` struct, no `resolveStageRouting`
      method, no `stageBackendCache` local; `runACPIngestPlannerExecutors`
      resolves one backend at the top (same pattern as single-session `run()`)
      and threads it through all three phases.
- [ ] Multi-phase ingest still works end-to-end (planner → executors →
      finalizer), all stages on the app default provider. (If a live run can't
      be staged in CI, at least assert compilation + the new unit test pins the
      resolution.)
- [ ] An existing `agent-providers.json` containing a `stageAssignments` key
      decodes without error (the key is ignored); test
      `legacyJSONWithStagesKeyDecodesAndIgnoresIt` passes.
- [ ] `rg -n 'stageAssignments|resolvedProvider\(for:|IngestStage|StageAssignment|StageRouting|resolveStageRouting|stageBackendCache' Sources/ Tests/`
      → zero hits.
- [ ] Both Swift CI jobs pass: `swift` (fast tier) and `swift-integration`
      (full). Python/pdf2md unaffected (no change there).
- [ ] No bare `try?`; all diagnostics via `DebugLog`; no `print`. (The existing
      `try? seeded.save(to:)` in `loadOrSeed` is pre-existing — re-evaluate per
      house rules; if touching it, wrap in `do/catch` with `DebugLog.store`.)

---

## 6. Cross-cutting concerns

- **SQLite:** none. No schema, no store method touched (`stageAssignments`
  lived in the JSON `agent-providers.json` sidecar, not the DB). No
  `mutate(event:)` impact, no `ResourceChangeEvent` change.
- **Concurrency / main-actor:** none. This is pure-data + pure-UI removal. The
  launcher's `@MainActor` isolation is unchanged; the resolved `self.backend`
  is still assigned on the main actor exactly as the single-session path does.
  No new `Sendable` boundaries, no `AsyncStream` change, no off-main compute.
- **Event bus / File Provider:** none. No store mutator changes, so no
  `ResourceChangeEvent` impact.
- **Permissions (#606/#607):** unaffected — the per-operation permission
  pickers are separate `@AppStorage` keys; only stage-specific plumbing goes.
- **`SpawnModelGuard`:** still enforced (now once at the top of
  `runACPIngestPlannerExecutors`, mirroring the single-session + chat paths).
  This is the load-bearing correctness guarantee that ingest refuses to spawn
  without an explicit `selectedModelId`.

---

## 7. NOT in scope

- Changing the multi-phase ingest *architecture* (planner/executor/finalizer
  stages stay as a concept — only the per-stage *provider assignment* goes).
- Changing how the app default provider is selected (`selectedProvider()`,
  `defaultProvider`, `settingDefault(id:)`, the normalization invariant).
- Re-adding the per-stage UI under any other shape.
- Touching `AgentBackendFactory`, the `ACPBackend` actor, fork-session,
  `runParallelExecutors`, `runPhase`, or `closePlannerSession` internals
  (beyond signature updates for the removed `StageRouting`).
- Any SQLite/store/event-bus change.
- Touching `plans/acp-multi-provider.md` body (only note in the PR that the
  per-stage routing it described is now removed).
