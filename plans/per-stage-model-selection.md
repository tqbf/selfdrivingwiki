# Plan: Per-Stage Model Selection for the ACP Ingestion Pipeline

**Status:** Investigation + design (no code changed). Targets macOS 15 / Swift 6.0.
**Rev 2** — addresses plan-review findings: HIGH #1 (AC.9 verification target),
HIGH #2 (stale `currentModelId` on the fork path), HIGH #3 (un-automatable
integration tests), MEDIUM (DRY refactor signature), LOW (slice-1 compilability).
**Goal:** Let the planner, executor, and finalizer phases of a multi-phase ACP
ingest run use **different models** (e.g. `glm-5.2` planner → `glm-5.2-fast`
executors → `glm-5.2-short` finalizer), restoring the per-stage differentiation
PR #604 removed.
**Hard constraint (operator directive):** per-stage is the goal. Per-operation
(chat/ingest/lint) *provider* overrides (#704) are NOT wanted and are assessed
for removal below.

---

## 1. Current single-model root cause (verified, file:line)

Ingestion has three phases — **Planner** (writes `plan.json`) → **Executors**
(one per source file, serial or parallel via `forkSession`) → **Finalizer**
(`index.md` + log). Today **one** provider + **one** `selectedModelId` is
resolved a single time and shared by all three.

The choke-point is `AgentLauncher.runACPIngestPlannerExecutors`
(`Sources/WikiFSEngine/AgentLauncher.swift:1357`). It resolves the provider and
model **once at the top** and threads that single value through every phase:

- `Sources/WikiFSEngine/AgentLauncher.swift:1410` —
  `let provider = providersConfig().providerForIngest()` (one provider).
- `Sources/WikiFSEngine/AgentLauncher.swift:1411` —
  `let modelId = providersConfig().selectedModelId(forProvider: provider.id)`
  (one model).
- `Sources/WikiFSEngine/AgentLauncher.swift:1424` —
  `SpawnModelGuard.validate(provider: provider, modelId: modelId)` validates that
  **one** model.
- `Sources/WikiFSEngine/AgentLauncher.swift:1429-1433` — one `providerHints`
  dict (carrying `acpSelectedModelId`) is built and **reused verbatim** by:
  - planner profile (`:1453-1457`),
  - executor profile (`:1520-1524`, `:1550-1554`),
  - finalizer profile (`:1609-1613`),
  - parallel-executor profile (passed into `runParallelExecutors` at `:1538`).
- The single-session `run()` fallback path (`runACPIngestFallback :1929`) takes
  the same `providerHints` as a parameter (`:1937`) and never re-resolves.

The `#604` collapse is documented at the choke-points:
- `Sources/WikiFSEngine/AgentLauncher.swift:1345-1356` (comment block —
  "per-stage provider/model assignment was removed … resolves the
  (provider, modelId, spawn, providerHints) ONCE at the top").
- `Sources/WikiFSEngine/SpawnModelGuard.swift:16-17` ("#604 collapsed the removed
  per-stage routing into a single resolution").
- `Sources/WikiFSCore/Sources/IngestPlan.swift:11` ("per-stage assignment was
  removed; every phase shares one backend").
- `Sources/WikiFSCore/Core/AgentProvidersConfig.swift:128-133` (the legacy
  `stageAssignments` JSON key is silently dropped — not in `CodingKeys`).

The same single-resolution pattern is used by the non-multi-phase `run()`
(`Sources/WikiFSEngine/AgentLauncher.swift:1121-1128`, `:1221-1225`) and by
interactive chat `startInteractiveQuery` (`:2336-2337`, `:2465`). Those are
unaffected by this change (see §6).

### How the model is actually applied per session

The single `selectedModelId` rides inside `providerHints` under the key
`HintKey.acpSelectedModelId` (`Sources/WikiFSEngine/HintKey.swift:13`). The
factory threads it in:
`Sources/WikiFSEngine/AgentBackendFactory.swift:69-71`
(`hints[HintKey.acpSelectedModelId.rawValue] = selectedModelId`).

`ACPBackend.createSession` consumes it right after `client.newSession`
(`ACPBackend.swift:549-568`):
- reads `profile.providerHints[HintKey.acpSelectedModelId.rawValue]`,
- calls the pure `ACPModelSelectionResolver.resolve(selectedModelId:
  currentModelId: advertisedModelIds:)`
  (`Sources/WikiFSCore/Core/AgentProviderModelCache.swift:60-94`) which returns
  `.apply(selectedId:)` or `.useAgentDefault` (validates the id is advertised;
  falls back to the agent default on a stale/unknown selection), and
- on `.apply`, calls `client.setModel(sessionId:modelId:)` (`:559`).

**Critical executor-path constraint (the design hinges on this):**
`ACPBackend.forkSession` (`Sources/WikiFSEngine/ACPBackend.swift:1170-1215`)
creates a forked executor session that **inherits the planner's
`modelsInfo`/`configOptions` (`:1205`) and does NOT call `setModel`**. So today a
forked executor always runs on the planner's model. `createSession` (used by the
planner, the finalizer, and the *fresh-start executor fallback* at
`runPhase :1882-1888`) is the only path that honors `acpSelectedModelId`. This
is why a real neuralwatt run showed `glm-5.2` for all three phases even though
the catalog offers `-flex`/`-fast`/`-short` variants.

**Two more facts the design depends on (HIGH #1 / HIGH #2):**
- `setModel`'s return is **discarded** (`_ = try await`, `ACPBackend.swift:559`),
  and the `ACPSession` stored at `:571-582` keeps the **ORIGINAL** pre-`setModel`
  `modelsInfo` (`:576`). So the stored `modelsInfo.currentModelId` is never
  refreshed — every downstream read (`sessionUsage(for:)` at `:1242`, the run
  `summary.json`, the debug artifact) reports the advertised default, not the
  applied model.
- `logSessionNew` runs at `ACPBackend.swift:532` **BEFORE** the setModel block
  (`:549-568`), so `debug/session-new*.json` captures the PRE-setModel model; and
  `forkSession` (`:1170-1215`) does **no debug logging** at all, so forked
  executors never produce a `session-new*.json`. Both are why AC.9 cannot assert
  against `session-new*.json` (see §9).

The PDF extraction client (`ACPExtractionClient`) also reads
`selectedModelId(forProvider:)` (`Sources/WikiFSEngine/ACPExtractionClient.swift:262`)
— it is a separate single-session path, unchanged by this work.

---

## 2. What #704 added: reusable vs removable

PR #704 (commit `b63c155`, "Allow per-operation provider overrides (chat / ingest
/ lint)") added a **per-operation provider pin layer** on top of the pre-existing
**per-provider model** infrastructure.

### Reusable (KEEP — per-stage selection builds directly on this)
- `AgentProvidersConfig.selectedModelIds: [String: String]`
  (`Sources/WikiFSCore/Core/AgentProvidersConfig.swift:47`) — the per-provider
  model map. This is exactly the storage per-stage needs, just keyed differently.
- `selectedModelId(forProvider:)` (`:330-333`) + `settingSelectedModel(_:forProvider:)`
  (`:362-379`) — read/write the per-provider model.
- `providerModels` / `cachedModels(forProvider:)` (`:41`, `:323`) — the discovered
  catalog (the source of the `-flex`/`-fast`/`-short` entries).
- `ACPModelSelectionResolver.resolve` (pure) + `ACPBackend.createSession` setModel
  block (`ACPBackend.swift:549-568`) — the per-session application seam.
- The `Provider default / Agent default` model `Picker` UI pattern
  (`Sources/WikiFS/Settings/AgentsSettingsView.swift:628-669`) — reused verbatim
  for per-stage pickers.

### Removable (the per-operation *provider* pin layer — what #704 actually shipped)
- `chatProviderId` / `ingestProviderId` / `lintProviderId` fields
  (`AgentProvidersConfig.swift:72-74`) + their `CodingKeys` (`:106-108`) +
  decoder (`:125-127`).
- `providerForChat/Ingest/Lint()` (`:203-218`).
- `settingChatProvider/IngestProvider/LintProvider(id:)` (`:229-275`).
- The per-op pin threading in `settingDefault` / `settingCachedModels` /
  `settingSelectedModel` / `togglingFavoriteModel` / `loadOrSeed`
  (`:298-306`, `:347-355`, `:370-378`, `:410-418`, `:478-486`).
- `AgentLauncher.setChatProvider/setIngestProvider/setLintProvider`
  (`AgentLauncher.swift:408-452`).
- The per-op resolution in `run()` (`AgentLauncher.swift:1124-1126`), in
  `runACPIngestPlannerExecutors` (`:1410` → would become `providerForIngest()` →
  `selectedProvider()`), and in `startInteractiveQuery` (`:2336` →
  `providerForChat()` → `selectedProvider()`).
- The UI: `PermissionsSettingsView.providerAssignmentSection` + `operationRow`
  + `setChatProvider/setIngestProvider/setLintProvider`
  (`Sources/WikiFS/Settings/PermissionsSettingsView.swift:131-229`).
- Tests: `Tests/WikiFSTests/AgentProvidersConfigPerOpProviderTests.swift`
  (whole file), plus references in `AgentLauncherSpawnRefusalTests.swift` and
  `ChatViewPreflightBannerTests.swift` (which use `providerForChat()` — these
  would switch to `selectedProvider()`).

---

## 3. Keep-vs-remove recommendation for #704's per-operation code

### Recommendation: REMOVE the per-operation provider pin layer as part of this work.

**Rationale:**

1. **It does not do what it was intended to do.** The directive states #704 was
   "intended to restore per-stage selection ('override #604')". It did not: it
   pins the *provider* per coarse operation (chat/ingest/lint), which is a
   strictly different axis from per-*stage* (planner/executor/finalizer) model
   selection. Keeping it would leave two overlapping, confusing selection axes.

2. **It does not compose with per-stage selection.** Per-stage selection
   deliberately stays on ONE provider and varies the *model* across stages
   (`glm-5.2` vs `glm-5.2-fast` are the same provider). The per-op layer varies
   the *provider* per operation. Leaving both means a user can pin ingest to a
   different provider while also setting per-stage models — two orthogonal
   knobs fighting over the same spawn, with no clear precedence and extra
   fall-back complexity.

3. **It is unused in practice for its stated purpose.** The real neuralwatt run
   used `glm-5.2` for all phases with no per-op provider differentiation; the
   catalog variants are model-level, not provider-level. The per-op pins add
   state and fall-back logic (`providerForXxx().flatMap { provider(id:) } ??
   defaultProvider`) that per-stage selection never needs.

4. **It expands the surface to maintain and test.** It adds 3 fields, 6 methods,
   a Settings section, and a dedicated test suite — all of which become dead
   weight once per-stage is the single source of truth for ingest and chat/lint
   keep using `selectedProvider()`.

### What to KEEP (non-negotiable)
- The underlying per-provider `selectedModelId` + model-picker infrastructure
  (§2 "Reusable"). Per-stage selection is implemented *on top of* this; removing
  the per-op pins must not touch it.

### Removal scope (concrete)
- Delete `chatProviderId`/`ingestProviderId`/`lintProviderId` + their
  `CodingKeys`/decoder + the six resolver/mutator methods from
  `AgentProvidersConfig`.
- Simplify the carried-field initializers (the per-op args drop out of every
  `AgentProvidersConfig(...)` constructor call).
- Collapse `run()` resolution (`:1121-1127`) to a single
  `let provider = config.selectedProvider()`.
- Collapse `runACPIngestPlannerExecutors` (`:1410`) and
  `startInteractiveQuery` (`:2336`) to `selectedProvider()`.
- Delete `setChatProvider/setIngestProvider/setLintProvider` from `AgentLauncher`.
- Delete `PermissionsSettingsView.providerAssignmentSection`/`operationRow`/the
  three setters; **replace** it with the per-stage model section (§5).
- Delete `AgentProvidersConfigPerOpProviderTests.swift`; update
  `AgentLauncherSpawnRefusalTests.swift` / `ChatViewPreflightBannerTests.swift`
  to use `selectedProvider()`.

**Migration:** A live `agent-providers.json` that already has `chatProviderId`/
etc. simply ignores those keys on decode (they leave `CodingKeys`), exactly as
#604 handled the legacy `stageAssignments` key (`AgentProvidersConfig.swift:128-133`).
No migration step, no behavior regression for users who never set a pin.

> Note: the operator directive says "omit per-operation provider overrides from
> the plan entirely." The *feature design* below therefore assumes the per-op
> layer is gone and `run()`/`startInteractiveQuery` resolve via
> `selectedProvider()`. The removal is listed here for completeness; it is a
> clean, self-contained prerequisite slice (compiles + tests green on its own —
> §11, LOW), not entangled with the per-stage model plumbing.

---

## 4. Proposed design: per-stage model selection

### 4.1 Config shape

Add a new optional, forward-compatible field to `AgentProvidersConfig`
(`Sources/WikiFSCore/Core/AgentProvidersConfig.swift`):

```swift
/// Per-ingest-stage model overrides. Keyed by stage name. Each value is a
/// model id FOR THE SAME PROVIDER the run resolves via selectedProvider()
/// (per-stage selects a MODEL variant, not a provider). nil/empty = "use the
/// provider's selectedModelId" (today's behavior). Forward-compatible: a
/// pre-per-stage file decodes to [:] → every stage uses selectedModelId.
public var ingestStageModelIds: [String: String]
```

- **Keyed by stage name:** `"planner"`, `"executor"`, `"finalizer"`. A missing or
  empty value falls back to `selectedModelId(forProvider:)` — identical to today.
- **Same provider, different model:** this is the core design decision. The whole
  run resolves ONE provider (`selectedProvider()`); per-stage only varies the
  model id within that provider's catalog. This matches the neuralwatt use case
  (`glm-5.2` / `glm-5.2-fast` / `glm-5.2-short` are one provider) and keeps
  `providerHints` (the spawn config: exe path, args, API key, env) identical
  across phases — the warm subprocess is reused as-is.
- `Codable` + `decodeIfPresent ?? [:]` for forward-compat (same pattern as
  `maxConcurrent` at `:122`). Add `ingestStageModelIds` to `CodingKeys`.
- Pure accessors + a PURE mutator, mirroring the existing `settingSelectedModel`
  shape:
  ```swift
  public func modelId(forStage stage: String, fallbackProvider providerId: String) -> String? {
      if let id = ingestStageModelIds[stage], !id.isEmpty { return id }
      return selectedModelId(forProvider: providerId)
  }
  public func settingIngestStageModel(_ modelId: String?, forStage stage: String) -> AgentProvidersConfig { ... }
  ```
- Add `ingestStageModelIds` to every carried-field constructor call
  (`settingDefault`, `settingCachedModels`, `settingSelectedModel`,
  `togglingFavoriteModel`, `loadOrSeed`) so a stage edit doesn't wipe other
  fields — exactly the carry-through pattern the per-op pins used.

### 4.2 Stage enum

Introduce a small enum (in `WikiFSCore`, next to `IngestPlan`) so stage names
are compile-time-checked, not bare strings:

```swift
public enum ACPIngestStage: String, Sendable, CaseIterable {
    case planner, executor, finalizer
    public var label: String { /* "Planner" etc. */ }
}
```

### 4.3 Per-phase resolution in the orchestrator

In `runACPIngestPlannerExecutors`, replace the single resolution with a
per-phase model id while keeping ONE provider/spawn/hints base:

```swift
let provider = providersConfig().selectedProvider()        // ONE provider
let spawn    = resolveACPProviderSpawn(provider)            // ONE spawn
// Base hints WITHOUT a model (model is per-phase):
let baseHints = AgentBackendFactory.providerHints(
    provider: provider, resolvedCommand: spawn.command,
    apiKey: spawn.apiKey, selectedModelId: nil)

// Resolve each stage's model (falls back to selectedModelId when unset).
func modelFor(_ stage: ACPIngestStage) -> String? {
    providersConfig().modelId(forStage: stage.rawValue, fallbackProvider: provider.id)
}
// The orchestrator now knows ALL THREE stage ids up front — this matters for
// the fork-path baseline in §4.5 (the planner's *resolved* model is the baseline
// against which the executor's model is compared, NOT the stale stored modelsInfo).
let plannerModel    = modelFor(.planner)
let executorModel   = modelFor(.executor)
let finalizerModel  = modelFor(.finalizer)
// Guard each stage (see §6).
```

Then build a per-phase `providerHints` by injecting the stage's model:

```swift
func hints(for stage: ACPIngestStage) -> [String: String] {
    var h = baseHints
    if let m = modelFor(stage), !m.isEmpty {
        h[HintKey.acpSelectedModelId.rawValue] = m
    }
    return h
}
```

- **Planner** profile uses `hints(for: .planner)` (`:1453`).
- **Executor** profile uses `hints(for: .executor)` (`:1520`, `:1550`) — and the
  parallel path passes an executor-specific profile into `runParallelExecutors`
  (`:1535-1543`).
- **Finalizer** profile uses `hints(for: .finalizer)` (`:1609`).
- **Fallback** (`runACPIngestFallback`) uses the planner's hints — it's a
  single-session ingest; pass the planner's `providerHints` as the parameter
  (replacing the current shared `providerHints` param at `:1937`).

Because the provider/spawn is identical, `self.backend` (the warm
`ACPBackend` actor `run()` already built at `:1128`) is reused unchanged — no
new subprocess, no orphaned actor. Only the `acpSelectedModelId` hint differs
per phase.

### 4.4 Per-session `setModel` application + the DRY seam (MEDIUM + HIGH #1)

The `createSession` path (planner, finalizer, and the fresh-start executor
fallback at `runPhase :1882-1888`) applies the model correctly today: each reads
`acpSelectedModelId` and calls `setModel` (`ACPBackend.swift:549-568`). Giving
each phase its own hints → each gets its own `setModel`. But **three things** in
that block must change for this feature:

1. **The stored `ACPSession.modelsInfo.currentModelId` is never refreshed after
   `setModel`** (HIGH #1/#2 root). The `setModel` return is discarded
   (`_ = try await` at `ACPBackend.swift:559`) and the `ACPSession` stored at
   `:571-582` keeps the ORIGINAL `modelsInfo` (`:576`). So every downstream read
   — `sessionUsage(for:)` at `ACPBackend.swift:1242`, the run-level `summary.json`,
   and the debug artifact — reports the PRE-setModel model.
   **Fix:** after a successful `setModel`, refresh the session's stored
   `modelsInfo.currentModelId` to the applied id (reassign the struct in the
   actor's `sessions` map — mirror the in-place `configOptions` update already
   done for `.configOptionUpdate`).

2. **The debug artifact is written BEFORE `setModel`** (HIGH #1).
   `debugLogger?.logSessionNew(...)` runs at `ACPBackend.swift:532`, before the
   setModel block (`:549-568`), so `debug/session-new*.json` captures the
   advertised default, not the applied model; and forked executors produce NO
   `session-new*.json` at all. **Fix:** add a NEW post-setModel debug artifact
   `debug/session-setModel-*.json`, written inside the shared
   `applyModelIfNeeded` (§9).

3. **DRY refactor with an explicit baseline** (MEDIUM). Refactor the `:549-568`
   block into a shared actor method so the fork path reuses it. The two call
   sites have DIFFERENT data availability (see §4.5), so the resolver's
   `currentModelId` baseline must be an **explicit parameter**, never read from
   the stored `modelsInfo` (which is stale on the fork path — HIGH #2).

**Important:** the `createSession` path itself does NOT have the
stale-`currentModelId` bug (HIGH #2). It reads `modelsInfo` FRESH from
`client.newSession` (`ACPBackend.swift:525`) and passes
`modelsInfo?.currentModelId` (`:554`) to the resolver — an accurate baseline.
That staleness is specific to the fork path (§4.5). The DRY refactor must not
import the fork-path staleness into the createSession path: order is
**store-then-apply-with-refresh** (store the session first so the handle exists,
then apply + refresh `modelsInfo.currentModelId` in place).

### 4.5 The executor fork path — the real backend change (HIGH #2 + MEDIUM)

The executor path prefers `forkSession` from the planner session
(`runPhase :1874-1888`; `runParallelExecutors` child task `:1740`).
`forkSession` (`ACPBackend.swift:1170-1215`) inherits the parent's `modelsInfo`
(`:1205`) and does **not** call `setModel` — so a forked executor silently runs
the planner's model. Calling the resolver naively here would re-introduce the
exact bug being fixed, because of the **stale-`currentModelId` misfire**:

**HIGH #2 (verified):** the `currentModelId` the resolver compares against is
stale. `setModel`'s return is discarded (`ACPBackend.swift:559`); the
`ACPSession` stores the original pre-`setModel` `modelsInfo` (`:576`); and
`forkSession` copies `parent.modelsInfo` verbatim (`:1205`). So the inherited
`currentModelId` is the agent's *advertised default*, NOT the planner's
*actually-applied* stage model. The resolver's "already current → no-op" guard
(`AgentProviderModelCache.swift:90-92`) then misfires whenever the executor's
stage model happens to equal the advertised default but differs from the
planner's model: it reads `currentModelId (stale = agent default) == executor
selected` → `.useAgentDefault` → no `setModel` → the executor silently stays on
the inherited **planner** model (silent model bleed — the exact bug being fixed).
**The no-op guard is NOT unconditionally safe.**

**Fix — shared `applyModelIfNeeded` with an explicit baseline (MEDIUM + HIGH #2):**

```swift
/// Actor-isolated. Applies `selectedModelId` to an already-created session
/// (createSession OR a forked executor), using `baselineCurrentModelId` as the
/// resolver's "current" baseline (NOT the stale stored modelsInfo). On a
/// successful setModel it REFRESHES the session's stored
/// modelsInfo.currentModelId and writes the NEW session-setModel-*.json debug
/// artifact. Non-fatal on setModel failure (logs + proceeds, matching
/// ACPBackend.swift:560-565).
func applyModelIfNeeded(
    session sessionHandle: SessionHandle,
    selectedModelId: String?,
    baselineCurrentModelId: String?,
    advertisedModelIds: [String]
) async
```

- **createSession** calls it right after the `ACPSession` is stored, passing
  `baselineCurrentModelId = modelsInfo?.currentModelId` — the FRESH value from
  `client.newSession` (`ACPBackend.swift:525`). Here the no-op guard is correct
  (fresh baseline). Order: **store-then-apply-with-refresh** (§4.4).
- **Fork path (serial + parallel)** — `runPhase :1877-1879` and the
  `runParallelExecutors` child task `:1742` — call it right after a successful
  fork, passing `baselineCurrentModelId = the PLANNER stage's configured model
  id` (`plannerModel` from §4.3). The orchestrator knows both stage ids, so the
  executor baseline is the planner's *resolved* model, not the stale inherited
  `modelsInfo`. Result: executor model == planner model → resolver correctly
  no-ops; executor model ≠ planner model → `.apply` → `setModel`. The
  stale-inherited-`currentModelId` bug is NOT imported into the shared path.
- **Refresh on success:** after a successful `setModel`, set
  `sessions[handle.id].modelsInfo?.currentModelId = appliedId` so downstream
  reads (`sessionUsage(for:)` at `:1242`, `summary.json`, AC.9) are accurate.
- **New debug artifact:** write `debug/session-setModel-*.json` via a NEW
  `DebugRunLogger.logSessionSetModel(...)` (modeled on `logSessionNew` at
  `DebugRunLogger.swift:77-91`) recording the stage, the resolved decision, the
  baseline, and the APPLIED id. This is the artifact AC.9 asserts against (§9).

`runPhase` calls `applyModelIfNeeded` only when `backend is ACPBackend`
(`AgentLauncher.swift:1874`, `:1740`), passing the executor's stage model and
`plannerModel` as the baseline. Because the provider/spawn is identical across
phases, the warm subprocess is reused; only the `acpSelectedModelId` hint + the
post-fork `applyModelIfNeeded` differ per phase.

### 4.6 Parallel executors

`runParallelExecutors` (`:1667`) currently receives one `executorProfile`. Change
it to receive the executor-stage `providerHints` (or build the profile inside
from the passed hints) + `plannerModel`/`executorModel` so the child task can
call `applyModelIfNeeded` with the correct baseline. Every parallel executor is
the *same* stage (`.executor`), so they all share one executor model id — no
per-file differentiation needed. The `applyModelIfNeeded` call after each fork
(`:1742`) handles the per-session `setModel` uniformly across serial and
parallel executors.

---

## 5. Settings UI changes (build on #704's picker, NOT per-op pins)

Replace the removed `providerAssignmentSection`
(`Sources/WikiFS/Settings/PermissionsSettingsView.swift:131-229`) with a
**per-stage model section**, reusing the existing `Picker` pattern from
`AgentsSettingsView.swift:628-669` (`Provider default` / `Agent default` rows,
reads `cachedModels(forProvider:)`).

```swift
// In PermissionsSettingsView (or a new section in AgentsSettingsView)
private var ingestStageModelSection: some View {
    let provider = config.selectedProvider()           // ONE provider
    let models   = config.cachedModels(forProvider: provider.id)
    Section {
        ForEach(ACPIngestStage.allCases) { stage in
            Picker("\(stage.label) Model", selection: Binding(
                get: { config.ingestStageModelIds[stage.rawValue] ?? "" },
                set: { newID in setStageModel(stage, newID.isEmpty ? nil : newID) }
            )) {
                Text("Same as provider (\(config.selectedModelId(forProvider: provider.id) ?? "default"))").tag("")
                ForEach(models) { Text($0.displayLabel).tag($0.modelId) }
            }
            .disabled(models.isEmpty)
        }
    } header: { Text("Ingest Stage Models") }
    footer: { Text("Pick a different model for each ingest phase. Empty uses the provider's default model.") }
}
```

- The picker lists the **resolved provider's** cached models — so the user picks
  `glm-5.2-fast` from the neuralwatt catalog.
- "Same as provider" (empty) is the default → no behavior change for existing
  users.
- `setStageModel` calls `settingIngestStageModel(_:forStage:)` + `persist()`.
- This is per-*stage* (planner/executor/finalizer), explicitly **not** the
  per-operation (chat/ingest/lint) provider pins the directive excludes.

> Design-skill note: follow `macos-design` (a `Section` with a clear
> header/footer, native `Picker`) and `typography-designer` (consistent
> `.callout`/`.caption` weights matching the existing rows) so it reads as a
> native macOS settings pane. No custom controls.

---

## 6. SpawnModelGuard / ACPModelSelectionResolver updates

### SpawnModelGuard (`Sources/WikiFSEngine/SpawnModelGuard.swift`)
Today it validates ONE model (`:23`). For per-stage, validate each stage's
resolved model. Two approaches:

- **Per-stage validation at the orchestrator top:** after resolving
  `modelFor(.planner)`, `modelFor(.executor)`, `modelFor(.finalizer)`, run
  `SpawnModelGuard.validate(provider:modelId:)` for each. Fail fast with a
  phase-named message (e.g. "No model selected for the Planner stage …") before
  spawning. This is the lowest-touch option and keeps the guard's PURE,
  unit-testable shape.
- Optionally add a convenience `validate(stages:modelFor:)` overload, but the
  three explicit calls are clearer and avoid a new abstraction.

The guard itself does **not** need to change signature — it already takes
`(provider, modelId)`. The change is *where* it's called (three times, once per
stage) in `runACPIngestPlannerExecutors`, replacing the single call at `:1424`.

### ACPModelSelectionResolver (`Sources/WikiFSCore/Core/AgentProviderModelCache.swift:60-94`)
**No code change needed** — it stays pure and per-session: it validates a single
`selectedModelId` against a `currentModelId` baseline + `advertisedModelIds` and
returns `.apply`/`.useAgentDefault`. Per-stage just calls it three times (once
per session) with three different `selectedModelId` values.

**But the `currentModelId` baseline is load-bearing (HIGH #2).** The resolver's
"already current → no-op" guard (`:90-92`) is only correct when the baseline is
accurate. The new `applyModelIfNeeded` consumer (§4.5) must supply a fresh
baseline — `modelsInfo?.currentModelId` straight from `newSession`
(`ACPBackend.swift:525`) on the createSession path, and the planner's *resolved*
stage model on the fork path — **never** the stale stored `modelsInfo` (whose
`currentModelId` is never refreshed after `setModel`, `ACPBackend.swift:559/:576`).
Per-stage does not weaken the resolver; it makes the baseline contract explicit.

---

## 7. Test Strategy (HIGH #3 — automated tier vs manual validation)

The fork → `applyModelIfNeeded` → `setModel` integration **cannot** be driven by
an automated test in this codebase, for two reasons (both verified):

1. The swift-acp SDK `Client` is a concrete `public actor`, **not a protocol** —
   there is no fake `Client` to intercept `setModel`
   (`Tests/WikiFSTests/ACPTurnRecoveryTests.swift:21-30` documents exactly this
   gap: "the SDK `Client` is a concrete `public actor`, NOT a protocol — so there
   is no fake `Client`").
2. `runACPIngestPlannerExecutors` only takes the fork path when
   `backend is ACPBackend` (`AgentLauncher.swift:1874` in `runPhase`; `:1740` in
   the `runParallelExecutors` child task), so a generic `AgentBackend` stub
   cannot exercise fork→applyModel.

This follows the codebase's own precedent: `ACPTurnRecoveryTests` runs Tier 1
against the **pure seam** (`TurnRecoveryGrace` + holders) and validates the
integration **manually**. This plan does the same — do NOT imply automated
coverage that cannot exist.

### Automated tier (pure seams — directly unit-testable)

- **`AgentProvidersConfig` per-stage tests** (new file, mirror the deleted
  per-op test shape): `ingestStageModelIds` read/write;
  `modelId(forStage:fallbackProvider:)` falls back to `selectedModelId` when a
  stage is unset/empty; `settingIngestStageModel` round-trip + nil/whitespace
  normalization; carry-through (a stage edit preserves `selectedModelIds`/
  `providerModels`); Codable backward-compat (a pre-per-stage JSON decodes to
  `[:]` → all stages use `selectedModelId`).
- **`ACPModelSelectionResolver` per-stage decision** (pure, no subprocess):
  the resolver validates a single `selectedModelId` against a `currentModelId`
  baseline + `advertisedModelIds` (`AgentProviderModelCache.swift:60-94`). Add
  cases for the per-stage inputs: (a) executor selected ≠ baseline → `.apply`;
  (b) executor selected == baseline (the planner's resolved model) →
  `.useAgentDefault` (correct no-op); (c) stale/unadvertised stage model →
  `.useAgentDefault` (no 404). This proves the DECISION logic that drives
  `applyModelIfNeeded` without an actor or subprocess.
- **SpawnModelGuard per-stage:** assert a missing *executor*-stage model (with
  planner/finalizer set) produces a phase-named refusal, not a silent spawn.
- **Removal regression tests:** `AgentProvidersConfigPerOpProviderTests.swift`
  is deleted; `AgentLauncherSpawnRefusalTests.swift` /
  `ChatViewPreflightBannerTests.swift` switch `providerForChat()` →
  `selectedProvider()`.

### Manual validation tier (MV — real neuralwatt run; see Risks R3)

- **MV-1 (per-phase APPLIED model):** a real multi-phase ingest with
  `planner=glm-5.2`, `executor=glm-5.2-fast`, `finalizer=glm-5.2-short` shows
  three DISTINCT applied models in the NEW post-setModel debug artifact
  (`session-setModel-*.json`, §9) — planner applies `glm-5.2`, an executor
  applies `glm-5.2-fast`, the finalizer applies `glm-5.2-short`. (This IS the
  AC.9 assertion — the automated tier cannot stand in for it.)
- **MV-2 (executor == planner → no-op):** with executor and planner set to the
  same model, the forked executor's `session-setModel-*.json` records
  `.useAgentDefault` (no `setModel` round-trip) — confirms the no-op guard is
  correct WITH an accurate baseline.
- **MV-3 (planner ≠ agent-default edge case — HIGH #2 regression):** with the
  planner's stage model different from the agent's advertised default, an
  executor pinned to the advertised default still gets `setModel` (NOT a silent
  no-op driven by the stale inherited `currentModelId`). This is the regression
  case for HIGH #2 — it can ONLY be caught on a real run because it needs a real
  `setModel` on a real forked session.

> Optional future scope (flagged, NOT assumed): introducing a `Client` protocol
> seam in the SDK (or a local wrapper protocol the launcher builds against)
> would enable a fake `Client` that records `setModel` calls, making
> MV-1/MV-2/MV-3 automatable. That is a larger change needing operator scope —
> noted here, not part of this plan.

---

## 8. Risks

- **R1 — Executor fork + `setModel` interaction.** Some ACP agents may not
  accept `session/set_model` on a forked session, or may reset context on
  `setModel`. `applyModelIfNeeded` degrades safely: on setModel failure it logs
  + proceeds (the `ACPBackend.swift:560-565` pattern); the executor runs on the
  inherited (planner) model — same as today, not worse. Verify on a real run
  (MV-1).
- **R2 — Warm-subprocess model isolation.** All phases share one subprocess;
  if an agent caches model state at the process level (not the session level),
  per-session `setModel` may not isolate models. ACP models model selection as
  per-session (`session/set_model`), so it should hold; validate on a real run.
- **R3 — No automated coverage of the fork→applyModel→setModel integration
  (HIGH #3).** The SDK `Client` is a concrete actor (not a protocol), and fork
  is gated on `backend is ACPBackend` (`AgentLauncher.swift:1874`, `:1740`). The
  automated tier (§7) covers only the pure decision
  (`ACPModelSelectionResolver`), per-stage config, and `SpawnModelGuard`. The
  wiring (fork → `applyModelIfNeeded` → `setModel` → refresh stored
  `currentModelId` → `session-setModel-*.json`) is manual validation only
  (MV-1/MV-2/MV-3, §7). This mirrors the `ACPTurnRecoveryTests` precedent.
  Introducing a `Client` protocol seam would close this gap but is a larger,
  out-of-scope change (flagged, not assumed).
- **R4 — Stale `currentModelId` on the fork path (HIGH #2).** The resolver's
  "already current → no-op" guard is **NOT unconditionally safe**: the stored
  `modelsInfo.currentModelId` is never refreshed after `setModel` (return
  discarded `ACPBackend.swift:559`; original stored `:576`; forked copy `:1205`),
  so a naive resolver call on a forked session misfires (silent model bleed).
  Mitigation: `applyModelIfNeeded` takes an explicit `baselineCurrentModelId`
  (fresh from `newSession` on the createSession path, or the planner's resolved
  model on the fork path) and refreshes the stored `currentModelId` on success.
  The baseline parameter is load-bearing — never feed the stale stored
  `modelsInfo` into it.
- **R5 — Debug artifact timing (HIGH #1).** `session-new*.json` is written
  BEFORE `setModel` (`ACPBackend.swift:532`) and forked executors have NO
  session-new file at all (`forkSession :1170-1215` does no debug logging).
  AC.9 therefore asserts against the NEW `session-setModel-*.json` artifact
  (APPLIED model), not `session-new*.json`. (Coordination: workstream D is adding
  a `models.json` at ingest START recording the INTENDED model; this artifact
  records the APPLIED model per phase — complementary, not duplicated.)
- **R6 — Concurrency seam.** `ACPBackend` is an actor; `applyModelIfNeeded` is
  actor-isolated and called via `await` from `runPhase` / the parallel child task
  (both already `await` `backend.start`). `SessionHandle`/`Client`/`SessionId`
  are `Sendable` (`ACPBackend.swift:26-43`). The in-place
  `modelsInfo.currentModelId` refresh reassigns a struct in the actor's
  `sessions` map (mirror the existing `configOptions` update for
  `.configOptionUpdate`). Consult `docs/skills/swift-concurrency-pro/SKILL.md`
  (actors, structured tasks) — the existing `createSession` setModel block is the
  template.

> Note (LOW): the per-op removal is independently compilable + test-passing on
> its own (see §11 slice 1) — the three resolution sites collapse to
> `selectedProvider()`, the setters are deleted, and the UI section is deleted;
> no per-stage symbol is referenced until slice 2. There is no "won't compile"
> coupling between the removal slice and the per-stage plumbing.

---

## 9. Acceptance criteria

A real multi-phase ingest run (large source, e.g. a substantial PDF) with
per-stage models configured (`planner=glm-5.2`, `executor=glm-5.2-fast`,
`finalizer=glm-5.2-short`) must show **different APPLIED models per phase** in
the NEW post-setModel debug artifact.

- **AC.9 (rewritten for HIGH #1):** the assertion target is
  `debug/session-setModel-*.json` — a NEW artifact written by
  `applyModelIfNeeded` (via a new `DebugRunLogger.logSessionSetModel(...)`,
  modeled on `logSessionNew` at `DebugRunLogger.swift:77-91`) recording, per
  phase, the stage, the resolved decision, the baseline, and the APPLIED model
  id. It MUST show three distinct applied ids: planner → `glm-5.2`, an executor
  → `glm-5.2-fast`, the finalizer → `glm-5.2-short`.
- **Why NOT `session-new*.json`:** `logSessionNew` runs at
  `ACPBackend.swift:532` BEFORE the setModel block (`:549-568`), so
  `session-new*.json` captures the PRE-setModel (advertised default) model —
  asserting against it would give a false success. **Forked executors never
  produce a `session-new*.json` at all** (`forkSession :1170-1215` does no debug
  logging), so they appear ONLY in the new `session-setModel-*.json` artifact.
- (Complementary cross-check) The run-level `summary.json` (`writeDebugSummary`,
  `ACPBackend.swift:1223`) MAY be extended to record the per-phase applied model
  in `DebugRunSummary.PhaseBreakdown` (`DebugRunLogger.swift:276-283`) — a
  convenience, not the primary assertion target.
- **Coordination note:** workstream D is adding a `models.json` at ingest START
  recording the INTENDED model; the `session-setModel-*.json` records the
  APPLIED model per phase. They are complementary — reference D's artifact for
  intent-vs-applied reconciliation, do not duplicate it.
- The single-session `run()` path (chat / lint / tiny-source ingest) is
  unchanged: it still uses `selectedProvider()` + its `selectedModelId`.
- `swift build` and `swift test` pass (full suite, ~1.5 min via in-memory
  fixtures); the automated tier (§7) is green; MV-1/MV-2/MV-3 (§7) pass on a
  real neuralwatt run.

### Verifying from a run dir
```bash
# Resolve the chat caches (needs Full Disk Access on the shell)
D="$HOME/Library/Caches/Self Driving Wiki-agent/<chatULID>/runs/<latest>/debug"
# PRIMARY: the NEW post-setModel artifact (APPLIED model per phase).
for f in "$D"/session-setModel*.json; do echo "== $f =="; jq '. | {stage, decision, appliedModelId}' "$f"; done
# Expect three DISTINCT appliedModelId values across planner/executor/finalizer.
# (session-new*.json reflects the PRE-setModel advertised default — do NOT assert
#  against it; forked executors have no session-new*.json at all.)
```

---

## 10. Build / test commands

```bash
swift build                       # compile (regenerates GeneratedPrompts + Version via the Make prerequisite)
swift test                        # full suite (~1.5 min, in-memory SQLite fixtures)
swift test --filter AgentProvidersConfig   # config-level tests (per-stage + removal regression)
make prompts                      # ONLY if any prompts/*.md changed (none expected here)
```

> Note: bare `swift build` does NOT regenerate prompts — `make build`/`check`/
> `test` do. This plan touches no prompt markdown, so `swift build` then
> `swift test` suffice.

---

## 11. Suggested slice order

1. **Remove per-op provider layer** (§3): config fields/methods, launcher
   setters + 3 resolution sites → `selectedProvider()`, delete UI section +
   per-op tests, fix the 2 spawn-refusal tests. **Independently compilable +
   tests pass on its own** (the three resolution sites collapse to
   `selectedProvider()`, setters deleted, UI section deleted — no per-stage
   symbol is referenced until slice 2). No behavior change for a user without a
   pin; a clean prerequisite. (LOW: drops any "won't compile" coupling claim.)
2. **Add `ingestStageModelIds` + `ACPIngestStage` + accessors** (§4.1, §4.2) +
   pure config tests. Build green (feature unused yet).
3. **Per-phase resolution in `runACPIngestPlannerExecutors`** (§4.3, §4.4) —
   planner/finalizer apply via `createSession`→`applyModelIfNeeded` (with the
   modelsInfo refresh + new artifact). SpawnModelGuard per-stage (§6).
   Pure-resolver + per-stage-config tests (§7 automated tier).
4. **Executor fork `applyModelIfNeeded`** (§4.5 — explicit planner-model
   baseline) + parallel path (§4.6). MV-1/MV-2/MV-3 recorded as manual steps.
5. **Settings UI** (§5). Real-run validation against the acceptance criteria (§9).

---

## 12. Rev-2 change log (reviewer findings)

- **HIGH #1 (AC.9 target):** added a NEW `debug/session-setModel-*.json` artifact
  written inside `applyModelIfNeeded` (new `DebugRunLogger.logSessionSetModel`,
  modeled on `logSessionNew` `DebugRunLogger.swift:77-91`); rewrote AC.9 (§9) to
  assert the APPLIED model there; stated forked executors only appear in this new
  artifact (never `session-new*.json`); referenced workstream D's intent artifact
  as complementary. §1, §4.4, §8(R5).
- **HIGH #2 (stale `currentModelId`):** `applyModelIfNeeded` takes an explicit
  `baselineCurrentModelId`; createSession passes fresh `newSession` currentModelId,
  the fork path passes the planner's *resolved* model; on success it refreshes the
  stored `modelsInfo.currentModelId`. Restated §4.5, §6, §8(R4): the no-op guard
  is NOT unconditionally safe. Added MV-3 (planner≠default regression case).
- **HIGH #3 (un-automatable tests):** split §7 into an automated tier (pure
  resolver + per-stage config + SpawnModelGuard) and a manual tier
  (MV-1/MV-2/MV-3); cited `ACPTurnRecoveryTests.swift:21-30` + the fork gates
  (`AgentLauncher.swift:1874`, `:1740`); added R3; flagged the `Client` protocol
  seam as out-of-scope.
- **MEDIUM (DRY signature):** specified the shared
  `applyModelIfNeeded(session:selectedModelId:baselineCurrentModelId:advertisedModelIds:)`
  signature (§4.4/§4.5) with the baseline as an explicit parameter and the
  store-then-apply-with-refresh ordering so createSession's fresh state is not
  replaced by the fork path's stale state.
- **LOW (slice-1 compilability):** §8 dropped the "won't compile" coupling claim;
  §11 slice 1 states it compiles + passes tests on its own (no per-stage symbol
  referenced until slice 2).
- **Positive verification retained:** #704 removal loses no coverage, no dangling
  refs, migration safe (§3).
