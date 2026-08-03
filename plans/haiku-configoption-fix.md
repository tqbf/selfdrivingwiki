# Plan: Config-Option Model Selection for claude-acp (Issue #834)

> **Status:** Investigation complete; ready to implement.
> **Scope:** `Sources/WikiFSEngine/ACPBackend.swift`, `Sources/WikiFSCore/Core/AgentProviderModelCache.swift`, tests.
> **Risk:** Medium — touches the model-switching path shared by chat, summarizer, and ingest; must not regress the `setModel` path for agents that DO advertise `availableModels`.

---

## 1. Root Cause (confirmed)

claude-acp exposes model selection via a **`"model"` config option** (a
`SessionConfigKind.select` advertised in `NewSessionResponse.configOptions`), **not**
via `ModelsInfo.availableModels`. The app's model-selection code only knows the
`availableModels` → `session/set_model` path, so for claude-acp the selection is a
silent no-op.

The os_log from the issue confirms this exactly:
```
ACPBackend.createSession: agent advertised 5 config option(s): mode, model, effort, fast, agent
ACPBackend.applyModelIfNeeded: session keeping agent default (selected=haiku decision=useAgentDefault baseline=nil)
```

### Call chain that fails
1. `ACPBackend.createSession` passes `advertisedModelIds: modelsInfo?.availableModels.map(\.modelId) ?? []`
   (`ACPBackend.swift:642`). For claude-acp `availableModels` is **empty**.
2. `ACPModelSelectionResolver.resolve` (`AgentProviderModelCache.swift:72-94`) hits
   `guard !advertisedModelIds.isEmpty else { return .useAgentDefault }` (line 83).
3. `applyModelIfNeeded`'s `.useAgentDefault` branch (`ACPBackend.swift:752-769`) skips
   `setModel` → the pinned model `"haiku"` is never applied.

This is the **exact same bug class as Zed #41578** ("Claude Code through ACP now always
defaults to haiku model instead of sonnet"). Zed hit it, Cursor CLI hit it, and we hit
it — because the ACP protocol offers two model-selection mechanisms and clients that only
implement the first one go silent on agents that use the second.

---

## 2. The Two Model-Selection Mechanisms (ACP protocol)

| Mechanism | How the agent advertises | How the client applies | Who uses it |
|---|---|---|---|
| **`ModelsInfo.availableModels`** | `NewSessionResponse.models.availableModels` | `session/set_model` (`client.setModel(modelId:)`) | Older agents; older `claude-code-acp` |
| **`SessionConfigOption` "model"** | `NewSessionResponse.configOptions` — option with `id == "model"`, `kind == .select` | `session/set_config_option` (`client.setConfigOption(configId:value:)`) | Newer claude-code-acp; Cursor CLI |

**The app only implements mechanism #1.** This plan adds mechanism #2.

---

## 3. The `setConfigOption("model", value)` Value Schema — RESOLVED

### 3a. SDK signature (grounded)

The swift-acp SDK (`Sources/ACP/Client.swift:315-324`) exposes a select-value overload:

```swift
public func setConfigOption(
    sessionId: SessionId,
    configId: SessionConfigId,
    value: SessionConfigValueId        // ← wraps as .select(value)
) async throws -> SetSessionConfigOptionResponse
```

The app **already wraps this** for the `thought_level` option at
`ACPBackend.swift:1540-1555`:
```swift
func setConfigOption(sessionHandle: SessionHandle, configId: String, value: String) async throws {
    ...
    let configIdValue = SessionConfigId(configId)
    let valueId = SessionConfigValueId(value)
    _ = try await session.client.setConfigOption(
        sessionId: session.sessionId, configId: configIdValue, value: valueId)
    ...
}
```
**This existing method is reusable verbatim** — pass `configId: "model"`, `value: <resolved>`.

### 3b. Does the "model" config option advertise its allowed values? — YES

The ACP `SessionConfigOption` schema (`swift-acp/Sources/ACPModel/Config.swift`) models a
select as: `id` (e.g. "model"), `kind` = `.select(SessionConfigSelect)` where
`SessionConfigSelect.currentValue` is the agent's current default and
`SessionConfigSelect.options` is `.ungrouped([SessionConfigSelectOption])` /
`.grouped([SessionConfigSelectGroup])`. Each `SessionConfigSelectOption.value` carries a
valid value id. **The implementer should NOT hardcode a translation table; the agent's own
`options` array is the source of truth.**

### 3c. What value to send for Haiku

`SessionConfigValueId(value)` where `value` is the **raw option value id** that the agent
advertised in `select.options[].value`. The implementation must validate the selection
against the advertised `options` (see §5.1) — if it's not in the list, fall back to the
agent default (same defensive posture as the existing stale-selection guard).

### 3d. Existing usage to mirror

`ThinkingEffortOption` (`Sources/WikiFSEngine/ThinkingEffortOption.swift`) is the exact
template: `from(configOptions:)` scans `configOptions` for an option whose
`id.value == "thought_level"`, reads its `.select`, and projects the `options` array.

**Mirror this pattern for the `"model"` option.**

---

## 4. Scope Check — this fix repairs ALL claude-acp sessions

All three model-application sites route through `ACPBackend.applyModelIfNeeded`
(`ACPBackend.swift:683`), and all three feed it `availableModels` (empty for claude-acp):

| Caller | File:line | `advertisedModelIds` source |
|---|---|---|
| `createSession` | `ACPBackend.swift:637-642` | `modelsInfo?.availableModels.map(\.modelId) ?? []` |
| Parallel executor fork | `AgentLauncher.swift:1953-1959` | `acp.availableModels(for:).map(\.modelId)` |
| Single executor fork | `AgentLauncher.swift:2303-2309` | `acp.availableModels(for:).map(\.modelId)` |

**Conclusion:** fixing `applyModelIfNeeded` (and feeding it the config-option data) repairs
the **chat model picker, the summarizer, and every ingest stage model pin** in one change.

---

## 5. Implementation Plan

### 5.1 Detection + decision: extend the resolver

Add a config-option case to `ACPModelSelectionDecision` and the resolver. Keep the existing
`.apply(selectedId:)` (setModel) case untouched for agents that advertise `availableModels`.

**Architecture note (deviation from original draft):** `AgentProviderModelCache.swift`
lives in `WikiFSCore`, which does **not** depend on `ACPModel` (kept ACP-free for Linux
portability, #754/#780). The new enum **case** is pure `String` (no `ACPModel` types) so it
goes in `WikiFSCore/Core/AgentProviderModelCache.swift`. The new **resolver method** +
helper (which take `[SessionConfigOption]`, an `ACPModel` type) go in a **new**
`Sources/WikiFSEngine/ACPModelConfigOptionResolver.swift` as a `public` extension on
`ACPModelSelectionResolver` — mirroring the `ThinkingEffortOption.swift` precedent of
ACPModel-touching pure logic living in `WikiFSEngine`.

**New decision case** (in `WikiFSCore/Core/AgentProviderModelCache.swift`):
```swift
public enum ACPModelSelectionDecision: Equatable, Sendable {
    case useAgentDefault
    case apply(selectedId: String)                                  // → session/set_model (unchanged)
    case applyViaModelConfigOption(selectedValue: String)           // → session/set_config_option (NEW)
}
```

**New resolver entry point** (PURE, in `Sources/WikiFSEngine/ACPModelConfigOptionResolver.swift`):

```swift
/// Decides whether to apply the selected model via the "model" config
/// option (session/set_config_option) — for agents that advertise model
/// selection as a config option rather than via ModelsInfo.availableModels
/// (e.g. claude-acp). Returns nil when the agent exposes no "model" config
/// option (the caller falls back to the setModel resolver).
public static func resolveConfigOptionModel(
    selectedModelId: String?,
    configOptions: [SessionConfigOption]
) -> ACPModelSelectionDecision? {
    guard let option = configOptions.first(where: {
        $0.id.value == "model" || $0.category == "model"
    }), case .select(let select) = option.kind else {
        return nil   // no "model" config option → caller uses the setModel path
    }
    guard let selectedModelId, !selectedModelId.isEmpty else {
        return .useAgentDefault
    }
    let advertisedValues = Self.configOptionValues(from: select.options)
    guard advertisedValues.contains(selectedModelId) else {
        return .useAgentDefault   // stale/unrecognized → don't 404 the agent
    }
    if select.currentValue.value == selectedModelId {
        return .useAgentDefault
    }
    return .applyViaModelConfigOption(selectedValue: selectedModelId)
}
```

Add a small helper to flatten the ungrouped/grouped options (mirror
`ThinkingEffortOption.flatChoices`):
```swift
static func configOptionValues(from options: SessionConfigSelectOptions) -> [String] {
    switch options {
    case .ungrouped(let opts): return opts.map { $0.value.value }
    case .grouped(let groups): return groups.flatMap { $0.options.map { $0.value.value } }
    }
}
```

> **Why `nil` return = "no config option":** this lets `applyModelIfNeeded` try the
> config-option path first, and when it returns `nil`, fall through to the existing
> `resolve(...)` (setModel) path. Agents that advertise BOTH get the config-option path
> (it takes precedence — it's the agent's preferred mechanism).

### 5.2 Routing: extend `applyModelIfNeeded` (`ACPBackend.swift:683-770`)

Add a `configOptions: [SessionConfigOption]?` parameter so the resolver can detect the
"model" option. Thread it from the three call sites.

```swift
func applyModelIfNeeded(
    session sessionHandle: SessionHandle,
    selectedModelId: String?,
    stage: ACPIngestStage?,
    baselineCurrentModelId: String?,
    advertisedModelIds: [String],
    configOptions: [SessionConfigOption]?   // ← NEW
) async {
    // 1. Try the config-option path FIRST (claude-acp and other config-option agents).
    if let configOptions,
       let coDecision = ACPModelSelectionResolver.resolveConfigOptionModel(
           selectedModelId: selectedModelId, configOptions: configOptions) {
        switch coDecision {
        case .useAgentDefault:
            // log + debug artifact (mirror existing useAgentDefault branch); return
        case .applyViaModelConfigOption(let value):
            // call setConfigOption(configId: "model", value: value) inline
            // + patchConfigOption to refresh stored configOptions + log artifact; return
        case .apply:
            break  // won't happen from resolveConfigOptionModel; fall through to setModel
        }
    }
    // 2. Fall through to the EXISTING setModel path (unchanged behavior).
    let decision = ACPModelSelectionResolver.resolve(
        selectedModelId: selectedModelId,
        currentModelId: baselineCurrentModelId,
        advertisedModelIds: advertisedModelIds)
    switch decision { /* ... existing .apply / .useAgentDefault ... */ }
}
```

The existing `.apply(selectedId:)` → `session.client.setModel(...)` branch is **untouched**
in behavior. The second `switch` gains an exhaustive `.applyViaModelConfigOption` case
(unreachable from `resolve(...)`) which routes to the same no-op/log behavior as
`.useAgentDefault` — required for exhaustiveness, does not change the `.apply` branch.

### 5.3 Thread `configOptions` from the three call sites

| Call site | How to get configOptions |
|---|---|
| `createSession` (`ACPBackend.swift:637`) | local `configOptions` (line 577) |
| Executor fork #1 (`AgentLauncher.swift:1954`) | `await acp.sessionConfigOptions(for: session)` |
| Executor fork #2 (`AgentLauncher.swift:2304`) | `await acp.sessionConfigOptions(for: session)` |

### 5.4 Don't break the setModel path

The existing `.apply(selectedId:)` → `session.client.setModel(...)` branch is untouched.
Agents that advertise `availableModels` keep working exactly as before. The config-option
resolver returns `nil` for them (no `"model"` config option), so `applyModelIfNeeded`
falls straight through to `resolve(...)`.

---

## 6. Tests

### 6.1 `resolveConfigOptionModel` unit tests (new `@Test` cases)

| Test | Inputs | Expected |
|---|---|---|
| `configOptionModel_appliesValidSelection` | selected `"haiku"`, option current=`"sonnet"`, values=`["haiku","sonnet","opus"]` | `.applyViaModelConfigOption(selectedValue: "haiku")` |
| `configOptionModel_alreadyCurrentSkips` | selected `"sonnet"`, current=`"sonnet"` | `.useAgentDefault` |
| `configOptionModel_staleSelectionFallsBack` | selected `"removed"`, values=`["haiku","sonnet"]` | `.useAgentDefault` |
| `configOptionModel_noSelectionUsesDefault` | selected `nil` | `.useAgentDefault` |
| `configOptionModel_emptySelectionUsesDefault` | selected `""` | `.useAgentDefault` |
| `configOptionModel_noModelOptionReturnsNil` | configOptions has only `thought_level` | `nil` |
| `configOptionModel_emptyConfigOptionsReturnsNil` | `configOptions: []` | `nil` |
| `configOptionModel_categoryMatchWorks` | option with `category: "model"`, id `"x"` | resolved (not nil) |

### 6.2 `applyModelIfNeeded` config-option routing (actor-level)

Verify via the existing ACP test mock seam that:
- With a `"model"` config option + selected `"haiku"`, `setConfigOption` is called and
  `setModel` is NOT called.
- With `availableModels` populated and NO `"model"` config option, `setModel` is called
  (existing path preserved).

---

## 7. Change Checklist

- [ ] `AgentProviderModelCache.swift`: add `case applyViaModelConfigOption` to
      `ACPModelSelectionDecision` (PURE, no ACPModel types).
- [ ] NEW `Sources/WikiFSEngine/ACPModelConfigOptionResolver.swift`: add
      `resolveConfigOptionModel(...)` + `configOptionValues(from:)` as a `public`
      extension on `ACPModelSelectionResolver` (PURE, touches ACPModel).
- [ ] `ACPBackend.swift`: add `configOptions: [SessionConfigOption]?` param to
      `applyModelIfNeeded`; add the config-option branch (try first, fall through to
      setModel); call `setConfigOption` inline + patchConfigOption + log artifact.
- [ ] `ACPBackend.swift:637` (`createSession`): pass `configOptions: configOptions`.
- [ ] `AgentLauncher.swift:1954` + `:2304` (fork paths): fetch
      `await acp.sessionConfigOptions(for: session)` and pass it.
- [ ] `Tests/WikiFSAppTests/AgentProviderModelPickerTests.swift`: add the
      `resolveConfigOptionModel` `@Test` cases (§6.1) + actor wiring test (§6.2).
- [ ] `swift build && swift test`.

---

## 8. Why not just "if availableModels empty, send setConfigOption unconditionally"?

Tempting shortcut, but unsafe:
- Some agents advertise NEITHER a models list NOR a `"model"` config option (older agents).
  Sending `setConfigOption(configId: "model", ...)` to an agent that doesn't know that
  option id would error.
- The value must be validated against the option's advertised `options` — sending
  `"haiku"` to an agent whose model option doesn't list it would fail (or silently
  no-op), reproducing the exact "selection ignored" symptom the picker exists to prevent.

The resolver-first design (detect the option → validate the value → decide) preserves the
defensive guarantees of the existing setModel path and handles all three agent shapes
(models-list, config-option, neither) correctly.
