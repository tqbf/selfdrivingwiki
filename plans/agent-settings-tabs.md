# Agent Settings — Operation Tabs (Chat / Ingestion / Lint)

> Plan doc (v2 — revised after plan-reviewer) for restructuring the **Agents**
> settings tab into a 3-tab layout (Chat / Ingestion / Lint), each with a
> per-stage provider dropdown (incl. "Default") + a dependent model dropdown.
>
> Target: macOS 15 / Swift 6.0.
>
> **v2 changelog** — incorporates all plan-reviewer findings:
> - HIGH: `loadOrSeed` reconstruction now carries `stageProviderIds` (was dropped
>   on every load → would break "persists across restart").
> - HIGH: all `selectedProvider()` launch sites enumerated; extraction &
>   queue-probe explicitly scoped out (was incorrectly "three sites").
> - HIGH: lint `run()` model application rewired to the per-stage resolver (the
>   lint model dropdown was cosmetic); SpawnModelGuard scope corrected.
> - HIGH: composer vs chat-pin reconciled via **Decision A** (Chat tab
>   authoritative; composer reflects the effective provider).
> - MEDIUM: field name standardized to `stageProviderIds`; stale model override
>   cleared on provider-pin change; AC→test mapping; `save()` bare-`try?` fixed.
> - LOW: nested-TabView style committed; doc comment on the model-override map
>   extended to cover chat/lint keys.

---

## 1. Goal & current-state summary

### Goal

Reorganize the **Agents** settings pane so each agent *operation* gets its own
sub-tab:

| Tab           | Stages it owns                                            |
|---------------|-----------------------------------------------------------|
| **Chat**      | Chat Model                                                 |
| **Ingestion** | Planner Model, Executor Model, Finalizer Model            |
| **Lint**      | Lint Model *(new — does not exist as a concept today)*    |

Every stage gets a **provider dropdown** that includes a **"Default"** option,
and a **model dropdown** whose options are **dependent on the chosen provider**
(populated from that provider's cached model list).

### Current state (file paths)

| Concern                        | File / Type                                                                 |
|--------------------------------|-----------------------------------------------------------------------------|
| Settings container (TabView)   | `Sources/WikiFS/Window/WikiFSApp.swift:500-514` — `Settings { TabView }`    |
| Agents settings view           | `Sources/WikiFS/Settings/AgentsSettingsView.swift` (~1010 lines)            |
| Provider editor sheet          | `AgentsSettingsView.swift:583` `ProviderEditorView`                         |
| Add-provider sheet             | `Sources/WikiFS/Settings/AddProviderSheet.swift`                            |
| Composer provider+model picker | `Sources/WikiFS/Settings/ProviderSelector.swift`                            |
| Persisted config (the model)   | `Sources/WikiFSCore/Core/AgentProvidersConfig.swift`                        |
| Provider unit                  | `Sources/WikiFSCore/Core/AgentProvider.swift`                               |
| Ingest stage enum              | `Sources/WikiFSCore/Sources/IngestPlan.swift:8` `ACPIngestStage`            |
| Config persistence protocol    | `Sources/WikiFSCore/Core/JSONSidecarConfig.swift`                           |
| Launcher (default resolution)  | `Sources/WikiFSEngine/AgentLauncher.swift`                                  |
| Per-stage model resolution     | `AgentLauncher.swift:1373-1376` `modelId(forStage:fallbackProvider:)`       |
| Chat resolution                | `AgentLauncher.swift:2413` `startInteractiveQuery`                          |
| Lint/query one-shot            | `AgentLauncher.swift:1069` `run()` (provider) + `:1181-1185` (model)        |

### Current AgentsSettingsView structure

```
AgentsSettingsView (body → providersSection)
├── "Providers" header (Text)
├── List(config.providers) { providerRow }            ← one row per provider
│     providerRow: Toggle(enabled) + label + command + inline modelPicker(▾)
│     (modelPicker: "Agent default" + cachedModels for THAT provider)
├── providerActionBar                                  ← Add / Remove / Make Default / Edit…
├── ingestStageSection                                 ← Form{Section} — per-stage MODEL picker
│     ForEach(ACPIngestStage.allCases):
│       Picker("\(stage.label) Model")                 ← planner/executor/finalizer
│         "Same as provider (model)" .tag("")
│         ForEach(cachedModels of the DEFAULT provider)
├── footer caption
└── save(_:) at :545-548  ← BARE try? (fixed in §6.6)
```

**Key observations:**
- There is **no provider dropdown per stage** today. The whole view has ONE
  shared default provider (`selectedProvider()`); the per-stage pickers only
  vary the *model id* within that one provider's catalog.
- `ACPIngestStage` = `.planner, .executor, .finalizer` only. There is **no chat
  stage and no lint stage enum.**
- The "Default" concept today = `AgentProvider.isDefault` (exactly one provider
  is default; enforced by `normalized()`). "Default" is a *provider* property,
  NOT a per-stage property.

---

## 2. Target design

### 2.1 Top-level layout

Keep the existing Settings `TabView` (Zotero / Extraction / Agents) in
`WikiFSApp.swift` unchanged at the top level. Inside `AgentsSettingsView`,
introduce a **nested `TabView`** (Chat / Ingestion / Lint) below the existing
Providers section:

```
Settings TabView (unchanged)
└── AgentsSettingsView
    ├── [existing] Providers section (provider list + Add/Remove/Edit…)  ← KEEP AS-IS
    └── OperationTabs  ← NEW nested TabView (Chat / Ingestion / Lint)
        ├── Chat tab      → StageProviderModelPicker(stageKey: "chat", label: "Chat Model")
        ├── Ingestion tab → ForEach(ACPIngestStage.allCases) { StageProviderModelPicker }
        └── Lint tab      → StageProviderModelPicker(stageKey: "lint", label: "Lint Model")
```

**Tab control decision (LOW finding):** commit to a **nested `TabView`** with an
explicit `.tabViewStyle(...)` chosen so it does not collide with the top-level
toolbar-tab style. **Visual validation is an acceptance criterion** (§8). If the
implementer finds the nested `TabView` renders an awkward double-bar inside the
settings `Form`/`VStack`, fall back to a **`Picker(selection:).pickerStyle(.segmented)`**
driving a `switch` over the three operation panes — this is the cleaner inline
macOS idiom and satisfies the "tabs per operation" requirement.

**Why keep the Providers section global:** providers (command/env/API key/cached
models) are operation-agnostic subprocess configurations. The new tabs are about
*which provider+model runs each operation/stage*, not editing provider details.

### 2.2 The shared stage picker component

Build a **new** reusable SwiftUI view: **`StageProviderModelPicker`**

**Location:** `Sources/WikiFS/Settings/StageProviderModelPicker.swift` (new file)

**Purpose:** One provider dropdown (incl. "Default") + one dependent model
dropdown. Reused for Chat Model, Planner/Executor/Finalizer Models, and Lint Model.

**Proposed API:**

```swift
/// A provider + model picker for a single agent stage/operation.
///
/// - `stageKey`: stable string key into the per-stage overrides
///   (`"chat"`, `"planner"`, `"executor"`, `"finalizer"`, `"lint"`).
///   For ingest stages this is `ACPIngestStage.rawValue`.
/// - `config`: the live config (binding so edits flow back through `save()`).
/// - `containerDirectory`: for persistence (save on change).
/// - `label`: human-readable stage label shown as the row title.
struct StageProviderModelPicker: View {
    let stageKey: String
    @Binding var config: AgentProvidersConfig
    let containerDirectory: URL
    let label: String
}
```

**Behavior:**

1. **Provider dropdown** (`Picker`):
   - First option: **"Default"** (tag `""` = inherit the global default provider).
   - Then one entry per `config.enabledProviders`.
   - Selection reads/writes `config.stageProviderIds[stageKey]` (the NEW field, §4).
2. **Model dropdown** (`Picker`, dependent):
   - Options = the **resolved provider's** cached models.
   - When the provider is "Default", resolve via `config.provider(forStage:)` →
     `selectedProvider()`, then list ITS cached models.
   - First model option: **"Same as provider"** (tag `""`) = the provider's
     `selectedModelId` (legacy semantics, so existing overrides keep working).
   - Reads/writes `config.ingestStageModelIds[stageKey]` (the existing field).
   - Disabled + placeholder ("Chat with this provider to discover models") when
     the resolved provider has no cached models.
3. **Stale-model safety (MEDIUM finding):** when the user changes the **provider**
   pin for a stage, **clear that stage's model override** (`ingestStageModelIds[stage]
   = ""`) so a model id from the previous provider's catalog is never sent to the
   new provider. The user then re-picks (or leaves "Same as provider").
4. **On change:** persist via the **corrected** `save(_:)` helper (§6.6 — no bare
   `try?`; `do/catch { DebugLog.store(...) }`).

### 2.3 What goes in each tab

| Tab | Stages rendered |
|-----|-----------------|
| **Chat** | One `StageProviderModelPicker(stageKey: "chat", label: "Chat Model")` |
| **Ingestion** | `ForEach(ACPIngestStage.allCases)` → one `StageProviderModelPicker(stageKey: stage.rawValue, label: "\(stage.label) Model")` per planner/executor/finalizer |
| **Lint** | One `StageProviderModelPicker(stageKey: "lint", label: "Lint Model")` |

---

## 3. "Default" sentinel handling & resolution

### The existing "Default" concept

- Today, "Default" is a property of a *provider*: `AgentProvider.isDefault`.
  Exactly one provider is default (`normalized()` enforces this).
- `config.selectedProvider()` = the default provider if enabled, else the first
  enabled provider, else `claudeAcpDefault`.
- There is **no per-stage "default provider"** today — every stage implicitly
  uses `selectedProvider()`. The per-stage override only changes the *model id*.

### New per-stage "Default" sentinel

- **Provider sentinel:** empty string `""` in `stageProviderIds[stage]` means
  "use the global default provider". This mirrors the existing model sentinel
  (`""` = "Same as provider") for UX consistency. No collision risk: `""` is not
  a valid provider id.
- **Model sentinel:** empty string `""` in `ingestStageModelIds[stage]` means
  "use the resolved provider's `selectedModelId`" (unchanged).

### Resolution helpers to add (on `AgentProvidersConfig`, pure)

```swift
/// Resolve the concrete provider for a stage: the stage's pinned provider
/// when set + enabled, else the global `selectedProvider()`.
public func provider(forStage stage: String) -> AgentProvider {
    if let pinnedId = stageProviderIds[stage],          // ← stageProviderIds (NOT ingestStageProviderIds)
       !pinnedId.isEmpty,
       let p = provider(id: pinnedId), p.enabled {
        return p
    }
    return selectedProvider()
}

/// Resolve the concrete model id for a stage using the stage-resolved provider.
public func modelId(forStage stage: String) -> String {
    let p = provider(forStage: stage)
    return modelId(forStage: stage, fallbackProvider: p.id)   // existing resolver
}
```

And a pure mutator `settingStageProvider(_ providerId: String, forStage stage: String)`
that returns a copy with `stageProviderIds[stage] = providerId` and (per §2.2.3)
clears `ingestStageModelIds[stage]` to `""` when the provider pin changes.

### Where "default" resolution happens — ALL launch sites (HIGH finding)

The launcher is the single source of truth for turning "default" into a concrete
provider+model. **Every** `selectedProvider()` call site that drives an actual
agent subprocess must be enumerated. Confirmed sites:

| Site | Path | Action in this change |
|------|------|-----------------------|
| Ingest planner/exec/finalizer | `AgentLauncher.runACPIngestPlannerExecutors` ~`:1373` | **WIRE** — resolve each stage's provider via `config.provider(forStage: <stage>)` instead of always `selectedProvider()`. Per-stage *model* via `modelId(forStage:)`. |
| Chat | `AgentLauncher.startInteractiveQuery` ~`:2413` | **WIRE** — resolve via `config.provider(forStage: "chat")`. |
| Lint / query / small-source ingest (shared `run()`) | `AgentLauncher.run()` ~`:1069` (provider) + `:1181-1185` (model) | **WIRE via operation-kind dispatch (v3 fix).** `run()` is the SHARED one-shot entry for `.ingest`/`.query`/`.lint` (kind switch at `:1036-1042`; large-source ingest returns early at `:1156`, so small-source ingest + all `.query` fall through to the `:1069` provider). Derive `stageKey` from the operation kind: `.lint`/`.lintPage → "lint"`, `.query → "chat"`, small-source `.ingest → "planner"`. Then BOTH `:1069` (`provider(forStage: stageKey)`) and `:1185` (`modelId(forStage: stageKey, fallbackProvider: provider.id)`) use that SAME key — do NOT hardcode `"lint"` (that mis-routes small-source ingest + query to the lint provider). Add tests: small-source ingest does NOT use the lint stage's pinned provider; query does NOT use the lint provider. |
| Extraction subprocess | `ACPExtractionClient.make(...)` ~`:246-255` (`acpProviderId` else `selectedProvider()`) | **SCOPE OUT** — extraction is a distinct operation with its own `acpProviderId` override and is NOT one of Chat/Ingestion/Lint. Leave unchanged. |
| Queue provider probe | `AppQueueIngestionProvider` ~`:55` | **SCOPE OUT** — detection-only (probes which provider can run); not a stage launch. Leave unchanged. |
| Default-provider closure | `AgentLauncher.resolveSelectedProvider` ~`:259` (default closure) | **VERIFY** — confirm it is the fallback used by `selectedProvider()` and does not need a stage pin (it is the "Default" resolution target itself). Leave unchanged. |

> The plan no longer claims "three sites". There are **three wired** (ingest /
> chat / lint) and **two scoped out** (extraction, queue-probe) plus one verified
> fallback closure.

### SpawnModelGuard scope (HIGH finding #3, corrected)

`SpawnModelGuard.validate(provider:modelId:)` is called at exactly **two** sites
today — ingest (`:1397`) and chat (`:2434`) — **NOT** in `run()` (lint). The
original gotcha "validate against the stage-resolved provider" applies to ingest
+ chat only. **Decision:** add `SpawnModelGuard` validation to the **lint**
`run()` path as well, validating the lint stage's resolved model against the
stage-resolved provider's cache, for consistency. (If the team prefers minimal
surface, the fallback is to leave lint unguarded as today — but then the lint
model dropdown's validity is unchecked; the plan recommends adding the guard.)

---

## 4. Persistence & config-model changes

### This plan DOES require a config-model change

The current `AgentProvidersConfig` stores per-stage **model** overrides only
(`ingestStageModelIds: [String: String]`). There is **no per-stage provider**
field, and **no chat model / lint model** concept.

### NEW field on `AgentProvidersConfig`

```swift
/// Per-stage PROVIDER overrides. Keyed by stage name ("chat", "planner",
/// "executor", "finalizer", "lint"). Value = provider id. Missing/empty ("")
/// = "use the global default provider" (`selectedProvider()`).
/// Backward-compatible: a pre-this-change file decodes to `[:]`.
public var stageProviderIds: [String: String]
```

### EXISTING field — keep, extend doc comment (LOW finding #10)

Keep `ingestStageModelIds` as the per-stage **model** override map (it already
accepts arbitrary string keys, so `"chat"` / `"lint"` work with no schema change).
**Extend its doc comment** to state it now holds model overrides for ALL stages
(chat / planner / executor / finalizer / lint), not just ingest — so future
readers don't "clean up" non-ingest keys. (A rename to `stageModelIds` is a
possible future refactor but is NOT in scope here — it would touch more call
sites and the persisted JSON key for no behavioral gain; backward compat is
trivially preserved by keeping the name.)

### Backward compatibility & loadOrSeed (HIGH finding #1) — CRITICAL

Two construction paths must carry the new field, or it is silently dropped:

1. **`init(from:)` decode:** add `stageProviderIds` to `CodingKeys` + decode with
   `decodeIfPresent(...) ?? [:]` (same pattern every other new field uses).
2. **`loadOrSeed` reconstruction (the trap):** `loadOrSeed` (~`:441-447`) is a
   static factory that RECONSTRUCTS the config via the memberwise init with an
   **explicit field list**. The file's own comments (`:173-174`) warn that this
   reconstruction silently drops any defaulted field not listed. **`stageProviderIds`
   MUST be passed through** the `loadOrSeed` reconstruction (`... stageProviderIds:
   config.stageProviderIds ...`) or the just-decoded value is reset to `[:]` on
   every load — breaking "survives restart".

**Mutator carry-through:** carry `stageProviderIds` through EVERY existing pure
mutator exactly as `ingestStageModelIds` is carried — the verified-complete list:
`replacingProviders`, `settingDefault`, `settingIngestStageModel`,
`settingCachedModels`, `settingSelectedModel`, `togglingFavoriteModel`. (And, per
above, through `loadOrSeed`'s reconstruction.)

### What NOT to change

- `AgentProvider` (the provider unit is fine as-is).
- `ACPIngestStage` (keep planner/executor/finalizer — chat/lint are string keys, not ingest stages).
- `JSONSidecarConfig` protocol or the `save(to:)` / `load(from:)` / `loadOrSeed(from:)` shape.

---

## 5. Exact files to add / modify

### NEW files

| Path | Purpose |
|------|---------|
| `Sources/WikiFS/Settings/StageProviderModelPicker.swift` | Shared provider-dropdown + dependent-model-dropdown component (§2.2). |

### MODIFIED files

| Path | Change |
|------|--------|
| `Sources/WikiFSCore/Core/AgentProvidersConfig.swift` | Add `stageProviderIds` field + `CodingKeys` + `init(from:)` (decode-if-present). **Carry `stageProviderIds` through `loadOrSeed` reconstruction (`:441-447`) AND all 6 pure mutators.** Add `provider(forStage:)`, `modelId(forStage:)` (pure resolvers) + `settingStageProvider(_:forStage:)` (pure mutator that also clears the stage model override). Extend `ingestStageModelIds` doc comment. |
| `Sources/WikiFS/Settings/AgentsSettingsView.swift` | Add nested `TabView` (Chat/Ingestion/Lint) below the Providers section; move `ingestStageSection`'s per-stage pickers into the Ingestion tab; add Chat + Lint tabs via `StageProviderModelPicker`. **Fix `save(_:)` (`:545-548`) bare-`try?` → `do/catch { DebugLog.store(...) }`** (§6.6). |
| `Sources/WikiFS/Settings/ProviderSelector.swift` | **Decision A (HIGH finding #4):** the composer chip must reflect the *effective* chat provider. Read the displayed provider from `config.provider(forStage: "chat")` (not bare `selectedProvider()`) so when chat is pinned the chip shows the pinned provider — no silent mismatch. The composer picker KEEPS setting the global default via `setSelectedModelAndDefault(...)` (unchanged behavior); picking in the composer still affects everything that follows "Default", just not a pinned chat. |
| `Sources/WikiFSEngine/AgentLauncher.swift` | Wire stage launches to `config.provider(forStage:)`: ingest `runACPIngestPlannerExecutors` (~`:1373`), chat `startInteractiveQuery` (~`:2413`). For the SHARED `run()` one-shot (`:1069` + `:1185`), derive `stageKey` from the operation kind (`:1036-1042`): `.lint→"lint"`, `.query→"chat"`, small-source `.ingest→"planner"`; use it for BOTH the provider (`:1069`) and the model builder (`:1185`). Add `SpawnModelGuard` to the lint path (§3). Leave extraction + queue-probe unchanged. |

### NOT modified (explicitly scoped out — verified compatible)

| Path | Why |
|------|-----|
| `Sources/WikiFSCore/Sources/IngestPlan.swift` (`ACPIngestStage`) | Stays planner/executor/finalizer. Chat/lint use string keys. |
| `Sources/WikiFS/Window/WikiFSApp.swift` | Top-level Settings `TabView` unchanged. |
| `Sources/WikiFS/Settings/AddProviderSheet.swift` | Provider CRUD is separate from per-stage pinning. |
| `Sources/WikiFSEngine/ACPExtractionClient.swift` | Extraction is its own operation with its own `acpProviderId` override. |
| `AppQueueIngestionProvider.swift` | Queue probe is detection-only. |

---

## 6. The shared picker component — detailed spec

### 6.1 `StageProviderModelPicker`

```swift
struct StageProviderModelPicker: View {
    let stageKey: String
    @Binding var config: AgentProvidersConfig
    let containerDirectory: URL
    let label: String

    var body: some View {
        VStack(alignment: .leading) {
            // --- Provider dropdown ---
            Picker("\(label) Provider", selection: providerBinding) {
                Text("Default").tag("")            // sentinel = global default
                ForEach(config.enabledProviders) { p in Text(p.label).tag(p.id) }
            }
            // --- Model dropdown (dependent on resolved provider) ---
            Picker("\(label) Model", selection: modelBinding) {
                Text("Same as provider").tag("")
                ForEach(resolvedModels, id: \.modelId) { Text($0.displayLabel).tag($0.modelId) }
            }
            .disabled(resolvedModels.isEmpty)
        }
    }

    private var resolvedProvider: AgentProvider { config.provider(forStage: stageKey) }
    private var resolvedModels: [CachedModelInfo] { config.cachedModels(forProvider: resolvedProvider.id) }

    // providerBinding reads/writes config.stageProviderIds[stageKey]
    //   on set: config = config.settingStageProvider(newValue, forStage: stageKey)
    //           (which ALSO clears ingestStageModelIds[stageKey] → "", §2.2.3)
    //           then save(config)
    // modelBinding reads/writes config.ingestStageModelIds[stageKey]
    //   on set: config = config.settingIngestStageModel(newValue, forStage: stageKey)
    //           then save(config)
}
```

### 6.2 Sentinel rules
- Provider = `""` (Default) → `provider(forStage:)` returns `selectedProvider()`.
- Model = `""` (Same as provider) → `modelId(forStage:)` returns the resolved
  provider's `selectedModelId`.

### 6.3 Stale-model clear
When `providerBinding` sets a non-empty provider pin, the mutator clears the
stage's model override (§2.2.3). Covered by a test (§7).

### 6.4 Field-name discipline (MEDIUM finding #5)
Provider pin → `stageProviderIds` (new). Model override → `ingestStageModelIds`
(existing, doc-comment-extended). The §3 snippets read `stageProviderIds` — not
`ingestStageProviderIds` (that was the v1 typo).

### 6.5 Composer reflection (Decision A)
`ProviderSelector` displays `config.provider(forStage: "chat")` (effective
provider). Keep `setSelectedModelAndDefault(...)` so the composer still sets the
global default. Covered by an AC (§8).

### 6.6 `save(_:)` fix (MEDIUM finding #8)
```swift
// BEFORE (AgentsSettingsView.swift:545-548) — violates house rule:
private func save(_ updated: AgentProvidersConfig) {
    config = updated
    try? config.save(to: containerDirectory)        // bare try? — HIDDEN failure
}
// AFTER:
private func save(_ updated: AgentProvidersConfig) {
    config = updated
    do { try config.save(to: containerDirectory) }
    catch { DebugLog.store("Failed to save agent-providers config: \(error)") }
}
```
`StageProviderModelPicker` routes persistence through this same corrected helper
(via the binding's on-set), so it does not diverge from the established pattern.

---

## 7. Testing plan

### NEW Swift Testing files

| Path | What it tests |
|------|---------------|
| `Tests/WikiFSTests/StageProviderModelPickerTests.swift` | Pure resolver logic only: provider `""` → `selectedProvider()`; model `""` → provider's selected model; enabled-pin → that provider; disabled-pin → fallback. (Not the View.) |

### MODIFIED Swift Testing files

| Path | What to add |
|------|-------------|
| `Tests/WikiFSTests/AgentProvidersConfigPerStageModelTests.swift` | `provider(forStage:)`: no pin → default; enabled pin → that provider; disabled pin → falls back. `settingStageProvider` carry-through (other fields survive). `"chat"`/`"lint"` keys via `modelId(forStage:)`. **Stale-model clear:** set stage model under provider A, change stage provider to B → model override cleared. **Lint model application path** is exercised indirectly via the resolver. |
| `Tests/WikiFSTests/AgentProvidersConfigSeedBackfillTests.swift` | Legacy `agent-providers.json` without `stageProviderIds` decodes to `[:]` (no crash, no behavior change). **NEW (HIGH #1):** a `loadOrSeed` round-trip test — write `stageProviderIds`, reload via `loadOrSeed`, assert the pins SURVIVE (catches the reconstruction drop). |

### AC → test mapping (MEDIUM finding #7)

| Acceptance criterion (§8) | Verification |
|---|---|
| Nested Chat/Ingestion/Lint tab bar renders | **Manual** (UI) |
| Providers section unchanged & works | **Manual** (UI) |
| Chat/Ingestion/Lint rows with provider+model dropdowns | **Manual** (UI) |
| Provider dropdown includes "Default" first | **Manual** (UI) |
| Selecting provider repopulates model dropdown | **Manual** (UI) |
| Selecting "Default" resolves to global default's models | `StageProviderModelPickerTests` + `AgentProvidersConfigPerStageModelTests` (`provider(forStage:)` empty-pin) |
| Composer chip reflects effective chat provider (pinned case) | **Manual** (UI) |
| Changes persist across restart | `AgentProvidersConfigSeedBackfillTests` (loadOrSeed round-trip) |
| Legacy file decodes; existing overrides still apply | `AgentProvidersConfigSeedBackfillTests` (legacy decode) |
| Stale model cleared on provider switch | `AgentProvidersConfigPerStageModelTests` (stale-model) |
| Lint model selection is actually applied at spawn | **Code review** (rewired `:1185`) — resolver covered by tests |
| No `print`; no bare `try?` | **Code review** + grep guard |
| New tests pass; full suite passes | `swift test` |

**Test strategy:** there is no SwiftUI render/snapshot harness in the repo. UI
ACs are therefore **explicitly downgraded to manual validation** (operator checks
in the running app), with a limitation note. All pure-logic ACs map to named
Swift Testing cases above.

### Conventions
- Swift Testing (`import Testing`, `@Suite`, `#expect`), NOT XCTest.
- Pure-logic tests only (no subprocess / no View rendering).
- Follow `docs/skills/swift-testing-pro/SKILL.md`.

---

## 8. Acceptance criteria

- [ ] The Agents settings pane shows a nested tab bar with **Chat**, **Ingestion**, **Lint**.
- [ ] The **Providers** section (list + Add/Remove/Make Default/Edit…) is unchanged and still works.
- [ ] **Chat tab** shows a "Chat Model" row with a provider dropdown + model dropdown.
- [ ] **Ingestion tab** shows Planner / Executor / Finalizer model rows, each with provider + model dropdowns.
- [ ] **Lint tab** shows a "Lint Model" row with provider + model dropdowns.
- [ ] Every provider dropdown includes a **"Default"** option as the first entry.
- [ ] Selecting a provider repopulates the model dropdown with **that provider's** cached models.
- [ ] Selecting "Default" resolves to the global default provider's models.
- [ ] **Composer chip reflects the effective chat provider** (shows the pinned provider when chat is pinned — no silent mismatch). *(Decision A)*
- [ ] **Lint model selection is actually applied** at spawn (rewired `:1185`, not cosmetic). *(HIGH #3)*
- [ ] **`run()` routes by operation kind** — small-source ingest does NOT use the lint stage's pinned provider, and query does NOT use the lint provider (`stageKey` derived at `:1036-1042`, used at both `:1069` and `:1185`). *(plan-reviewer v3)*
- [ ] Changes persist to `agent-providers.json` **and survive `loadOrSeed` restart** (round-trip test). *(HIGH #1)*
- [ ] An existing `agent-providers.json` (pre-change) decodes without error; existing per-stage model overrides for planner/executor/finalizer still apply.
- [ ] **Changing a stage's provider pin clears its stale model override.** *(MEDIUM #6)*
- [ ] No `print` statements; all logging via `DebugLog`.
- [ ] No bare `try?` — including the fixed `save(_:)` helper.
- [ ] New tests pass: `swift test --filter AgentProvidersConfigPerStageModelTests` (+ seed-backfill + picker tests).
- [ ] Full suite passes: `swift test` (or `make test`).
- [ ] **Manual:** nested tab control renders cleanly (no awkward double-bar) on macOS 15. *(LOW #9)*

---

## 9. Constraints & house rules (from AGENTS.md)

- **Never use `print`** — route diagnostics through `DebugLog` (`os_log`, subsystem `com.selfdrivingwiki.debug`).
- **Never use bare `try?`** — `do { try … } catch { DebugLog.store(…) }`.
- **Prefer Swift Testing** over XCTest.
- **Never commit or push to `main`** — feature branch → PR. Do NOT merge to main.
- **Build/test:** `make build` / `make test` (auto-regenerate `GeneratedPrompts.swift` + `GeneratedVersion.swift`); bare `swift build` does NOT — run `make prompts` first.
- **Scratch files** go in `tmp/` (gitignored), not `/tmp`.
- **Change signaling (#129):** not in play — this change touches `AgentProvidersConfig` (JSON sidecar), NOT `SQLiteWikiStore`.
- **macOS 15 / Swift 6.0** — filter iOS 26 / Swift 6.2 guidance from skills.

---

## 10. Gotchas & risks (reviewer-corrected)

1. **`loadOrSeed` silently drops new fields** (`:441-447`, warned at `:173-174`). `stageProviderIds` MUST be passed through the reconstruction or per-stage pins vanish on restart. *(HIGH #1 — now in §4.)*
2. **More than three launch sites.** `selectedProvider()` is read at ingest/chat/lint (wire), extraction `ACPExtractionClient` (scope out — own `acpProviderId`), queue probe `AppQueueIngestionProvider` (scope out — detection), and the default closure `AgentLauncher:259` (verify). The lint path needs BOTH provider (`:1069`) and model (`:1185`) rewired. *(HIGH #2 & #3 — now in §3.)*
3. **Composer vs chat pin** — reconciled via Decision A: composer reflects effective chat provider; keeps setting global default. *(HIGH #4 — now in §3/§5/§6.5.)*
4. **Stale model after provider switch** — cleared in the mutator. *(MEDIUM #6 — now in §2.2.3/§6.3.)*
5. **`save(_:)` bare `try?`** — fixed. The new picker routes through the corrected helper. *(MEDIUM #8 — now in §6.6.)*
6. **`SpawnModelGuard`** covers ingest+chat only today; lint `run()` has none — this plan adds it for consistency. *(§3.)*
7. **`claude-acp` backfill** (`loadOrSeed` injects `selectedModelIds["claude-acp"] = "sonnet"`) is keyed by provider id, not stage — still works; ensure chat/lint stage defaults don't shadow it.
8. **`ProviderEditorView`** (Edit… sheet) has its own per-PROVIDER model picker — leave it alone (different concern).
9. **Do NOT add chat/lint to `ACPIngestStage`** — they are string keys into `stageProviderIds` / `ingestStageModelIds`.
10. **Nested `TabView` style** — commit + visually validate; fall back to segmented `Picker` if double-bar. *(LOW #9 — §2.1.)*
