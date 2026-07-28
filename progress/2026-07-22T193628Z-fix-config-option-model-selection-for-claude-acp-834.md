---
timestamp: 2026-07-22T193628Z
title: "fix: Config-option model selection for claude-acp (#834)"
branch: null
status: historical
timestamp_source: git-commit
---

# fix: Config-option model selection for claude-acp (#834)

## Progress


**Goal:** claude-acp exposes model selection via a `"model"` config option
(`session/set_config_option`), not via `ModelsInfo.availableModels`
(`session/set_model`). The app only implemented the `availableModels` path, so a
pinned model (e.g. `"haiku"`) was silently dropped — the resolver hit the
empty-list guard and skipped `setModel`. This adds a config-option-aware
model-selection path, trying it FIRST and falling through to the unchanged
`setModel` path. Same bug class as Zed #41578.

**Investigation → plan:** `plans/haiku-configoption-fix.md`.

**Architecture deviation from the original plan:** the plan placed
`resolveConfigOptionModel` in `WikiFSCore/Core/AgentProviderModelCache.swift`,
but `WikiFSCore` does NOT depend on `ACPModel` (kept ACP-free for Linux
portability, #754/#780). The new enum **case** (`applyViaModelConfigOption`,
pure `String`) went in `WikiFSCore`; the resolver **method** + helper (touching
`ACPModel.SessionConfigOption`) went in a new
`Sources/WikiFSEngine/ACPModelConfigOptionResolver.swift` as a `public`
extension on `ACPModelSelectionResolver` — mirroring the `ThinkingEffortOption`
precedent of ACPModel-touching pure logic living in `WikiFSEngine`.

**Plan-review correction applied:** the pre-existing public
`setConfigOption(sessionHandle:configId:value:)` wrapper had a bug — it
constructed `SessionConfigId(value)` (using the VALUE as the config id) instead
of `SessionConfigId(configId)`, breaking the `thought_level` path too. Fixed
(`ACPBackend.swift:1655`). The new config-option model path bypasses the
wrapper entirely, calling `session.client.setConfigOption(...)` directly with
`SessionConfigId("model")`.

**Files touched:**
- **Edit (resolver enum):** `Sources/WikiFSCore/Core/AgentProviderModelCache.swift`
  — added `case applyViaModelConfigOption(selectedValue: String)` to
  `ACPModelSelectionDecision` (no `ACPModel` types, stays in `WikiFSCore`).
- **New (resolver method):** `Sources/WikiFSEngine/ACPModelConfigOptionResolver.swift`
  — `public extension ACPModelSelectionResolver` with
  `resolveConfigOptionModel(selectedModelId:configOptions:)` (detect the
  `"model"` select by id OR category, validate the value against the advertised
  `options`, decide) + `configOptionValues(from:)` (flatten
  ungrouped/grouped). Mirrors `ThinkingEffortOption` patterns.
- **Edit (routing):** `Sources/WikiFSEngine/ACPBackend.swift` —
  `applyModelIfNeeded` gained a `configOptions` param; tries the config-option
  path FIRST (returning non-nil = agent advertises a `"model"` config option),
  applies via `session.client.setConfigOption(configId:"model", value:)` +
  `patchConfigOption` to refresh stored `configOptions`, then falls through to
  the UNCHANGED `setModel` path when `nil`. Added exhaustive
  `.applyViaModelConfigOption` case to the setModel `switch` (unreachable there,
  defensive no-op). Fixed the `setConfigOption` wrapper's
  `SessionConfigId(value)` → `SessionConfigId(configId)` bug.
- **Edit (call sites):** `Sources/WikiFSEngine/ACPBackend.swift` (`createSession`
  passes the local `configOptions`) + `Sources/WikiFSEngine/AgentLauncher.swift`
  (both fork paths fetch `await acp.sessionConfigOptions(for: session)` —
  forkSession inherits the parent's configOptions).
- **Edit (tests):** `Tests/WikiFSAppTests/AgentProviderModelPickerTests.swift`
  — 8 `resolveConfigOptionModel` cases (apply/already-current/stale/nil/empty
  selection, no-model-option→nil, empty→nil, category-match) + 2
  `configOptionValues` flatten tests (ungrouped/grouped) + 1 setModel-path
  regression guard.

**Evidence:** `swift build` clean (warnings-as-errors on WikiFSEngine);
`swift test` full suite — 3514 tests in 295 suites passed; the 11 new
config-option tests pass via `swift test --filter "configOptionModel|configOptionValues|setModelPathStillApplies"`.

## Verification

Historical verification remains in the progress record above.
