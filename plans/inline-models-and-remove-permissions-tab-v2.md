# Plan (v2): Inline model selection into the Agents tab; remove the Permissions tab

> **Supersedes** `plans/inline-models-and-remove-permissions-tab.md` (v1).
> v1 was written before PR #711 (per-stage model selection) merged. #711
> removed `chatProviderId`/`ingestProviderId`/`lintProviderId` — the exact
> fields v1's per-mode chips bound to — and added `ingestStageModelIds` + a
> per-stage picker section to `PermissionsSettingsView`. The operator
> confirmed (in #711's PR body) that the per-operation provider pin layer is
> unwanted. v2 is the post-#711 consolidation: drop the chips, keep the rest
> of v1's UX cleanup, and move the new per-stage picker into Agents.

## Goal

Consolidate the remaining model-selection + provider surfaces into the
**Agents** tab, and delete the **Permissions** tab. No engine change, no
storage-shape change.

Confirmed decisions (post-#711):
- **Per-provider model selection**: one inline `Model ▾` `Picker` per
  **enabled** provider row in `AgentsSettingsView`, reading/writing the
  existing per-provider `selectedModelId`. (Same as v1 §3c minus the chips.)
- **Per-stage model selection (planner / executor / finalizer)**: MOVE the
  existing `ingestStageModelSection` from `PermissionsSettingsView` into
  `AgentsSettingsView` as a new section below the providers list. It stays
  scoped to `selectedProvider()` — per-stage selects a MODEL variant within
  one provider's catalog, NOT a per-stage provider, so it does NOT belong on
  a per-provider row.
- **Permission policy pickers (Chat / Ingest / Lint bypass-vs-always-ask)**:
  **drop the UI**. The `@AppStorage` keys persist; existing users keep their
  last value, new users get the `bypass` default. No engine change. (Same as
  v1.)
- **"Ask before quitting" toggle**: **drop the UI**. Stays on its default
  (`true`). `AppDelegate` still reads `confirmBeforeQuitting`. (Same as v1.)
- **Collapsible title bar** (`CollapsibleDetailHeader`): remove it from
  `AgentsSettingsView` only. The shared type stays (used by ChatView,
  PageDetailView, SourceDetailView). (Same as v1 §3a.)

## Scope note on "no data-model change"

No change to `AgentProvidersConfig`'s stored properties, `CodingKeys`,
`init(from:)`, or `save`/`load`. The plan DOES add one pure convenience
mutator (`replacingProviders(_:)`) — a new method that mirrors the existing
carry-everything-through mutators (`settingDefault`, `settingIngestStageModel`,
etc.). Not a stored-field or coding change.

## Out of scope (explicitly)

- No change to `AgentLauncher`, `ACPBackend`, `SpawnModelGuard`, the fork /
  `applyModelIfNeeded` engine path, or the per-stage resolution logic #711
  added.
- No change to `ACPIngestStage`, `PermissionPolicy`, `PermissionModeKey`,
  `PermissionModeSelector` (still used by `ChatView` + the engine).
- `ProviderEditorView` (the Edit… sheet) is kept **as-is**, including its
  Model `Section` + Refresh Models button. It is now a second surface
  editing the same `selectedModelId`; this redundancy is accepted (both
  bind the same field and stay consistent). The manual model-discovery
  probe lives there; moving it is out of scope.
- v1's `Mode` (`chat`/`ingest`/`lint`) chip enum + helpers are NOT carried
  forward — the underlying fields no longer exist.

## Files

### 1. `Sources/WikiFSCore/Core/AgentProvidersConfig.swift` — add the carry-through mutator

Add a new public method near the existing setters:

```swift
/// PURE mutator: returns a NEW config with `providers` replaced (re-
/// normalized by `init`) and EVERY other field carried through unchanged.
/// Use this from call sites that only want to change the providers list —
/// the memberwise init's defaulted fields silently drop `maxConcurrent`
/// AND `ingestStageModelIds` (post-#711), which is the pre-existing bug
/// `plans/inline-models-and-remove-permissions-tab-v2.md` §5 fixes.
/// Mirrors the carry-everything-through shape of `settingDefault(id:)` /
/// `settingIngestStageModel(_:forStage:)`.
public func replacingProviders(_ providers: [AgentProvider]) -> AgentProvidersConfig {
    AgentProvidersConfig(
        providers: providers,
        providerModels: providerModels,
        selectedModelIds: selectedModelIds,
        favoriteModelIds: favoriteModelIds,
        maxConcurrent: maxConcurrent,
        ingestStageModelIds: ingestStageModelIds)
}
```

(`init` already calls `normalized(providers)`, so the single-default
invariant is preserved — `removeProvider`'s re-normalization behavior is
unchanged.)

### 2. `Sources/WikiFS/Window/WikiFSApp.swift` — remove the Permissions tab + fix a stale comment

- Delete the `PermissionsSettingsView(containerDirectory:)` tab entry, its
  `.tag(SettingsTab.permissions)`, its `.tabItem { Label("Permissions", ...) }`,
  and the preceding explanatory comment block.
- Remove `case permissions` from `enum SettingsTab`.
- Leave the remaining three tabs (Zotero / Extraction / Agents) and the
  `settingsSelectedTab` binding alone. The binding already falls back to
  `.zotero` for unknown/removed raw values, so a stored `"permissions"`
  selection silently routes to Zotero on next launch — no migration.
- **Update the stale doc comment** on `confirmQuitKey`. Replace with:
  *"`@AppStorage` key for the ask-before-quitting behavior. Default is `true`
  (ask) when unset. The Settings toggle was removed with the Permissions tab
  (per `plans/inline-models-and-remove-permissions-tab-v2.md`); the key stays
  because `AppDelegate` reads `confirmBeforeQuitting` for quit gating."*
  Do NOT delete `confirmQuitKey` / `confirmBeforeQuitting`.
- Verified: no caller passes `"permissions"` to `openSettings(tab:)` — the
  only caller (`ActivityWindowView.swift:446`) passes `"extraction"` or
  `"agents"`.

### 3. `Sources/WikiFS/Settings/PermissionsSettingsView.swift` — delete the file

Remove the entire file. After §1 (drop the Permissions tab) and §4 (move
the per-stage section to AgentsSettingsView), no remaining caller references
it. Its three sections are disposed of as:
- `permissionSection` → UI dropped, `@AppStorage` keys persist.
- `appBehaviorSection` → UI dropped, key persists.
- `ingestStageModelSection` → MOVED to `AgentsSettingsView` (see §4).

Do **not** delete `PermissionModeSelector.swift` — it is still used by
`ChatView`.

### 4. `Sources/WikiFS/Settings/AgentsSettingsView.swift` — inline dropdown + per-stage section + drop header + fix field-carrying

#### 4a. Remove the `CollapsibleDetailHeader` wrapper from `body`

- Delete `@State private var isExpanded = true` and its doc comment.
- Rewrite `body` so it returns the `providersSection` directly with the same
  modifiers currently attached inside the header's content closure:
  - `.frame(minWidth: 560, minHeight: 520, alignment: .top)`
  - `.sheet(isPresented: $showAddSheet) { … }`
  - `.sheet(item: $editingProvider) { … }`
  - `.confirmationDialog(...) { … }`
- Keep all existing sheet/sheet/confirmationDialog content byte-for-byte;
  only the `CollapsibleDetailHeader(systemImage:title:isTitleDisabled:isExpanded:onTitleCommit:)`
  container goes away.

#### 4b. Rewrite `providerRow(_:)` — inline Model dropdown

Current row renders: toggle, label+badges, command, a model status `switch`,
then `Spacer()`. New row shape (enabled provider):

```
[○]  claude [badges]                                    Model [sonnet ▾]
     claude acp
     (orange "pick one before running" caption only when
      modelStatus == .noSelectionPickable)
```

Concretely, inside the existing `HStack(spacing: 10)`:
- **Keep** the leading `Toggle`, the `VStack(alignment: .leading)` with
  label+badges + command, and the `.opacity(provider.enabled ? 1.0 : 0.55)`.
- **Move** the model-status `switch Self.modelStatus(for:in:)` block AND the
  trailing `Spacer()` into a trailing cluster: `Spacer()` + `providerControls(provider)`.
- **Disabled providers** (`!provider.enabled`): hide `providerControls`
  entirely. Keep the dimmed label/command.

#### 4c. Add `providerControls(_:)` + `modelPicker(_:)` + `modelBinding(for:)`

```swift
@ViewBuilder
private func providerControls(_ provider: AgentProvider) -> some View {
    VStack(alignment: .trailing, spacing: 4) {
        modelPicker(provider)
        // Compact caption — keeps `modelStatus` in use. `.noneCaptured` is
        // surfaced by the picker itself ("Chat to discover models"
        // placeholder); `.selected` needs no caption.
        switch Self.modelStatus(for: provider, in: config) {
        case .noSelectionPickable:
            Text("pick one before running")
                .font(.caption2).foregroundStyle(.orange)
        case .noneCaptured, .selected, .disabled:
            EmptyView()
        }
    }
}

@ViewBuilder
private func modelPicker(_ provider: AgentProvider) -> some View {
    let cachedModels = config.cachedModels(forProvider: provider.id)
    Picker("Model", selection: modelBinding(for: provider)) {
        if cachedModels.isEmpty {
            Text("Chat to discover models").tag("")
        } else {
            Text("Agent default").tag("")
            ForEach(cachedModels, id: \.modelId) { model in
                Text(model.displayLabel).tag(model.modelId)
            }
        }
    }
    .labelsHidden()
    .disabled(cachedModels.isEmpty)
    .frame(maxWidth: 180)
}

private func modelBinding(for provider: AgentProvider) -> Binding<String> {
    Binding(
        get: { config.selectedModelId(forProvider: provider.id) ?? "" },
        set: { newID in
            save(config.settingSelectedModel(newID.isEmpty ? nil : newID,
                                             forProvider: provider.id))
        })
}
```

> Note on `modelWarning`: same as v1 — `modelWarning` survives solely as a
> pure, directly-tested helper (`AgentsSettingsViewWarningTests`). Keep it
> and its tests; do not claim it is "used by the view."

#### 4d. Move the per-stage model section into `AgentsSettingsView`

Lift `PermissionsSettingsView.ingestStageModelSection` (plus its
`setStageModel` action) into `AgentsSettingsView`. Place it as a sibling of
the providers List + action bar inside the main VStack, BELOW the action bar.
Use a `Form { Section { … } }.formStyle(.grouped)` block to keep the same
visual style it had in the Permissions tab.

```swift
private var ingestStageSection: some View {
    let provider = config.selectedProvider()
    let models = config.cachedModels(forProvider: provider.id)
    let fallbackLabel = config.selectedModelId(forProvider: provider.id) ?? "default"
    return Form {
        Section {
            ForEach(ACPIngestStage.allCases, id: \.rawValue) { stage in
                Picker("\(stage.label) Model", selection: Binding(
                    get: { config.ingestStageModelIds[stage.rawValue] ?? "" },
                    set: { newID in setStageModel(stage, newID.isEmpty ? nil : newID) }
                )) {
                    Text("Same as provider (\(fallbackLabel))").tag("")
                    ForEach(models, id: \.modelId) { model in
                        Text(model.displayLabel).tag(model.modelId)
                    }
                }
                .disabled(models.isEmpty)
                .help(models.isEmpty
                      ? "Chat with this provider once to discover its models."
                      : "Pick a different model for the \(stage.label) phase.")
            }
        } header: {
            Text("Ingest Stage Models (\(provider.label))")
        } footer: {
            Text("Pick a different model for each ingest phase — e.g. a small model for Executors and a large model for the Planner. “Same as provider” uses the provider's selected model (the legacy behavior).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    .formStyle(.grouped)
}

private func setStageModel(_ stage: ACPIngestStage, _ modelId: String?) {
    save(config.settingIngestStageModel(modelId, forStage: stage.rawValue))
}
```

`ACPIngestStage` is in `WikiFSCore` (`Sources/WikiFSCore/Sources/IngestPlan.swift`)
— `AgentsSettingsView` already imports `WikiFSCore`, so no new import.

#### 4e. Footer note (replaces v1's chip-language footer)

Update the existing footer `Text` to:
> "Models you pick on each row apply when that provider runs. Use Edit… for
> command, environment, API key, and Refresh Models. Ingest Stage Models below
> apply to whichever provider is currently default."

#### 4f. Fix field-carrying in the four mutators (v1 §3e, now extended)

**Problem:** four callers — `enabledBinding`, `applyEdit`, `appendProvider`,
`removeProvider` — construct a new config via the 4-field
`AgentProvidersConfig(providers:providerModels:selectedModelIds:favoriteModelIds:)`
form, which **defaults `maxConcurrent` to `[:]` AND `ingestStageModelIds` to
`[:]`**. Today that silently wipes BOTH the per-provider concurrency map AND
the per-stage model picks on every enable-toggle / add / remove / edit. The
per-stage wipe is a regression窗口 #711 opened: a user picks
planner=`glm-5.2-fast` in the (moved) section, toggles an unrelated
provider's enabled switch, and the per-stage picks silently revert.

**Fix:** route the four callers through `replacingProviders`:
- `enabledBinding`: `save(config.replacingProviders(updated.providers))`
- `appendProvider`: `save(config.replacingProviders(updated.providers))`
- `removeProvider`: `save(config.replacingProviders(updated.providers))`
- `applyEdit`: `save(config.replacingProviders(providers).settingSelectedModel(selectedModelId, forProvider: updated.id))`

## Tests / verification

- Run `make build` (regenerates `GeneratedPrompts.swift` / `GeneratedVersion.swift`
  — bare `swift build` does NOT), then `swift test`.
- Existing tests that must still pass unchanged:
  - `Tests/WikiFSTests/AgentsSettingsViewModelStatusTests` — calls
    `modelStatus(for:in:)` directly (pure func, unchanged).
  - `Tests/WikiFSTests/AgentsSettingsViewWarningTests` — calls
    `modelWarning(for:in:)` directly (pure func, unchanged).
  - `Tests/WikiFSTests/AgentProvidersConfigPerStageModelTests` — covers the
    per-stage read/write/carry-through. Should keep passing unchanged.
- New test (REQUIRED): add `replacingProviders` carry-through regression
  coverage to `Tests/WikiFSTests/AgentProvidersConfigPerStageModelTests.swift`
  asserting `replacingProviders(someProviders)` carries
  `ingestStageModelIds` AND `maxConcurrent` through unchanged. This pins the
  exact §4f bug.
- No test references `PermissionsSettingsView` or `SettingsTab.permissions`
  (verified by grep against post-#711 main).
- Manual smoke (cannot be automated — no SwiftUI UI test harness in this
  repo): open Settings → Agents and confirm
  (a) no collapsible title bar;
  (b) each enabled provider row shows the Model dropdown on the right;
  (c) changing the dropdown persists;
  (d) the "Ingest Stage Models" section renders below the action bar with
      three stage pickers;
  (e) toggling a provider's enabled switch does NOT wipe existing per-stage
      picks (the §4f regression);
  (f) the Permissions tab is gone.

## Acceptance criteria

1. Settings has three tabs: Zotero, Extraction, Agents. No Permissions tab.
2. `PermissionsSettingsView.swift` no longer exists; `swift build` succeeds
   with no references to it.
3. `AgentsSettingsView` has no `CollapsibleDetailHeader`; its body renders
   the providers section directly.
4. Each enabled provider row shows an inline Model `Picker` on the right,
   bound to the existing per-provider `selectedModelId`.
5. `AgentsSettingsView` hosts an "Ingest Stage Models" section (moved from
   `PermissionsSettingsView`) with three stage pickers bound to the existing
   `ingestStageModelIds`.
6. The four callers in §4f route through `replacingProviders`; the new
   carry-through regression test passes.
7. `swift test` is green.
8. No engine/launcher files changed (`AgentLauncher`, `ACPBackend`,
   `SpawnModelGuard`, the fork / `applyModelIfNeeded` path untouched).

## Risks, Blockers, and Required Decisions

1. **Pre-existing field-dropping bug** — fixed by §4f. Until the fix lands,
   the per-stage picks silently revert on any enable toggle / add / remove /
   edit. The fix is mechanical and the regression test pins it.
2. **No automated UI test coverage.** AC items 3, 4, and 5 are manual-smoke
   only.
3. **"Agent default" picker option is a `SpawnModelGuard` dead-end.**
   Pre-existing (the `ProviderEditorView` picker has the same option);
   mitigated by the `.noSelectionPickable` → "pick one before running"
   caption. No change to `SpawnModelGuard`.
4. **Per-stage section visual placement.** Putting it below the action bar
   inside the main VStack means it does NOT scroll with the providers List
   (it's a sibling, not a child). That's deliberate — the section is short
   (3 pickers) and should stay visible. If the window is too short to fit
   list + action bar + section, the section will clip — acceptable for now
   (the Settings window has a 520 min height); revisit if smoke testing
   shows clipping at default sizes.

## Notes for the implementer

- `save(_:)` currently uses **bare `try?`** — pre-existing. Do NOT introduce
  NEW bare `try?`. Since §4f touches the callers of `save` (not `save`
  itself), upgrading `save` to `do/catch + DebugLog` is optional and out of
  scope; do it only if it's a one-line change.
- The MOVED `setStageModel` uses `save(_:)` (which writes the file), NOT
  `persist()`. `PermissionsSettingsView` had its own `persist()` helper —
  that helper goes away with the file; `save(_:)` is the equivalent on
  `AgentsSettingsView`. The bare-`try?` caveat above applies.
- Route all logging through `DebugLog`. No `print`.
- Consult `docs/skills/swiftui-pro/SKILL.md` + `macos-design` for picker
  styling (filter iOS-26-only APIs; target is macOS 15 / Swift 6.0).
- Consult `docs/skills/swiftui-ui-patterns/SKILL.md` for nesting a `Form`
  inside a plain `VStack` (the per-stage section's container).

## Documentation Strategy

- Update `PROGRESS.md` with: Permissions tab removed; the per-stage model
  section + the inline per-provider Model dropdown moved into the Agents
  tab; the §4f field-carrying fix (now carries `ingestStageModelIds` too).
- Add a one-liner to v1 (`plans/inline-models-and-remove-permissions-tab.md`)
  pointing to this v2 as the active plan, so a future agent reading the
  older doc knows it was superseded by #711.

## Differences from v1

| v1 section | v2 status |
|---|---|
| §1 Remove Permissions tab | **Keep** — unchanged |
| §2 Delete PermissionsSettingsView | **Keep** — unchanged |
| §3a Remove CollapsibleDetailHeader | **Keep** — unchanged |
| §3b/§3c inline Model dropdown | **Keep** — minus the chip cluster |
| §3c Chat/Ingest/Lint mode chips | **DROP** — fields removed by #711 |
| §3d footer | **Reword** — no chip language, mention stage section |
| §3e `replacingProviders` carry-through | **Keep + extend** — now carries `ingestStageModelIds` |
| NEW: move per-stage section | **Add** — wasn't in v1; replaces the dropped chip surface as the "advanced model config" home |
