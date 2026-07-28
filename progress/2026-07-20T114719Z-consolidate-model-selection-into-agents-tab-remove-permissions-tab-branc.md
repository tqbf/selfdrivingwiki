---
timestamp: 2026-07-20T114719Z
title: "2026-07-20 — Consolidate model selection into Agents tab; remove Permissions tab (branch `inline-models-remove-permissions-tab`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-20 — Consolidate model selection into Agents tab; remove Permissions tab (branch `inline-models-remove-permissions-tab`)

## Progress


**Problem.** Settings had four tabs (Zotero / Extraction / Agents /
Permissions). The Permissions tab hosted three things whose reasons for
being separate had eroded: the per-operation permission-policy pickers
(kept on `@AppStorage` defaults; the UI added nothing), the "Ask before
quitting" toggle (orphaned after the General tab was removed), and —
post-#711 — the per-stage model picker (`ingestStageModelSection`), which
is conceptually about provider/model selection, not permissions. Meanwhile
the Agents tab kept the `CollapsibleDetailHeader` from when it was a
detail-style pane, and per-provider model selection was reachable only via
the Edit… sheet.

**Fix.** Delete the Permissions tab and move its load-bearing section (the
per-stage model picker) into the Agents tab. Inline a per-provider Model
dropdown on each enabled provider row. Drop the header. While here, fix a
pre-existing field-carrying bug in four `AgentsSettingsView` mutators that
silently wiped `maxConcurrent` AND `ingestStageModelIds` on every
enable-toggle / add / remove / edit (the bug got worse when #711 added
`ingestStageModelIds`).

Plan: `plans/inline-models-and-remove-permissions-tab-v2.md` (v2; v1 at
`plans/inline-models-and-remove-permissions-tab.md` was superseded by #711
before implementation).

### Config — `Sources/WikiFSCore/Core/AgentProvidersConfig.swift`

- New PURE mutator `replacingProviders(_:)`: returns a NEW config with
  `providers` replaced (re-normalized by `init`) and EVERY other field
  carried through unchanged. Mirrors the carry-everything-through shape of
  `settingDefault(id:)` / `settingIngestStageModel(_:forStage:)`. Use this
  from any call site that only wants to change the providers list — the
  memberwise init's defaulted fields silently drop `maxConcurrent` and
  `ingestStageModelIds`.

### UI — `Sources/WikiFS/Window/WikiFSApp.swift`

- Removed the `PermissionsSettingsView` tab entry, its
  `.tag(SettingsTab.permissions)`, its `.tabItem`, and `case permissions`
  from `enum SettingsTab`. Settings now has three tabs (Zotero / Extraction
  / Agents). The `settingsSelectedTab` binding already fell back to
  `.zotero` for unknown raw values, so a stored `"permissions"` selection
  silently routes to Zotero on next launch — no migration.
- Updated the stale doc comment on `AppDelegate.confirmQuitKey` (was
  "Settings → Permissions → App Behavior … Referenced by
  `PermissionsSettingsView`"). The key + the read stay; only the toggle UI
  is gone.

### UI — `Sources/WikiFS/Settings/PermissionsSettingsView.swift` (DELETED)

- File removed. Its three sections are disposed of as:
  - `permissionSection` (Chat/Ingest/Lint bypass-vs-always-ask pickers) →
    UI dropped. The `@AppStorage` keys persist; existing users keep their
    last value, new users get the `bypass` default. No engine change.
  - `appBehaviorSection` ("Ask before quitting" toggle) → UI dropped. Key
    stays; `AppDelegate` still reads `confirmBeforeQuitting`.
  - `ingestStageModelSection` → MOVED to `AgentsSettingsView` (see below).
- `PermissionModeSelector.swift` is NOT deleted — `ChatView` still uses it.

### UI — `Sources/WikiFS/Settings/AgentsSettingsView.swift`

- Removed the `CollapsibleDetailHeader` wrapper from `body`. The header
  was a remnant from when the Agents pane was a detail-style view; the
  inline controls + the moved per-stage section make the title bar with a
  chevron redundant.
- Rewrote `providerRow(_:)`: removed the inline model-status `switch`
  block + the trailing `Spacer()`; added a trailing cluster
  `providerControls(provider)` on enabled providers (hidden when
  disabled).
- New helpers `providerControls(_:)` / `modelPicker(_:)` /
  `modelBinding(for:)`: a `Model ▾` `Picker` bound to the per-provider
  `selectedModelId`, plus a compact orange "pick one before running"
  caption driven by the existing pure `modelStatus(for:in:)` classifier
  (which stays directly unit-tested).
- Moved `ingestStageModelSection` + its `setStageModel` action verbatim
  into `AgentsSettingsView` as a new section below the providers list +
  action bar. Rendered as a nested `Form { Section }.formStyle(.grouped)`
  so it keeps the same visual style it had in the Permissions tab despite
  the parent being a plain VStack.
- Footer note reworded: "Models you pick on each row apply when that
  provider runs. Use Edit… for command, environment, API key, and Refresh
  Models. Ingest Stage Models below apply to whichever provider is
  currently default."
- **§4f field-carrying fix:** the four mutators `enabledBinding` /
  `applyEdit` / `appendProvider` / `removeProvider` previously rebuilt the
  config via the 4-field `AgentProvidersConfig(providers:providerModels:selectedModelIds:favoriteModelIds:)`
  form, which silently defaulted `maxConcurrent` and `ingestStageModelIds`
  to `[:]`. Routed all four through `config.replacingProviders(...)` so
  both fields survive. With per-stage picks now on the same view, the
  silent wipe would have been visible (pick planner=`glm-5.2-fast`,
  toggle an unrelated provider's enabled switch, watch the per-stage pick
  revert).

### Tests

- NEW `replacingProvidersCarriesIngestStageModelIdsAndMaxConcurrent` and
  `replacingProvidersReNormalizesEmptyListToDefault` in
  `Tests/WikiFSTests/AgentProvidersConfigPerStageModelTests.swift`. The
  first is the direct regression for the §4f bug; the second pins the
  empty-list re-seed invariant.
- No test referenced `PermissionsSettingsView` or
  `SettingsTab.permissions` (verified by grep). No test changes were
  needed for the UI moves.
- Existing pure-func tests (`AgentsSettingsViewModelStatusTests`,
  `AgentsSettingsViewWarningTests`, `AgentProvidersConfigPerStageModelTests`,
  `SpawnModelGuardTests`, `ACPBackendTests`, `ACPWiringTests`,
  `AgentProvidersConfigSeedBackfillTests`) all pass unchanged.

## Verification

Historical verification remains in the progress record above.
