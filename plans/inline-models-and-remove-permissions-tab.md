# Plan: Inline model selection into the Agents provider rows; remove the Permissions tab

> **SUPERSEDED by v2** (`plans/inline-models-and-remove-permissions-tab-v2.md`).
> v1 was written before PR #711 (per-stage model selection) merged. #711
> removed `chatProviderId` / `ingestProviderId` / `lintProviderId` — the
> exact fields v1's per-mode chips bind to — and added `ingestStageModelIds`
> + a per-stage picker section to `PermissionsSettingsView`. v2 keeps the
> UX-cleanup parts of v1 (drop the Permissions tab, drop the header, inline
> the Model dropdown, fix the §3e field-carrying bug) and adds a section
> moving #711's per-stage picker into Agents. v1 is kept for revision
> history; do not implement it.

## Goal (operator-confirmed)

Consolidate provider + model + per-mode assignment into the single **Agents**
settings tab, and delete the **Permissions** tab entirely. Design **A** (no
storage-shape change, launcher untouched).

Confirmed decisions:
- **Model selection**: one inline `Model ▾` `Picker` per **enabled** provider
  row, reading/writing the existing per-provider `selectedModelId`.
- **Per-mode assignment**: three compact mode chips (`Chat` / `Ingest` / `Lint`)
  on each enabled provider row, bound to the existing `chatProviderId` /
  `ingestProviderId` / `lintProviderId` fields. A chip is "active" on the row
  whose id equals that mode's pin. Unpinned modes fall back to the default
  provider (legacy behavior) — communicated by a footer note, not a per-row
  indicator.
- **Permission policy pickers** (Chat/Ingest/Lint bypass-vs-always-ask):
  **drop the UI**. The `@AppStorage` keys persist; existing users keep their
  last value, new users get the `bypass` default. No engine change.
- **"Ask before quitting" toggle**: **drop the UI**. Stays on its default
  (`true`). No engine change (`AppDelegate` still reads `confirmBeforeQuitting`).
- **Collapsible title bar** (`CollapsibleDetailHeader`): remove it from
  `AgentsSettingsView` only. The shared type stays (used by ChatView,
  PageDetailView, SourceDetailView).

## Scope note on "no data-model change"
"No data-model change" means **no change to the persisted storage shape** —
`AgentProvidersConfig`'s stored properties, `CodingKeys`, `init(from:)`, and
`save`/`load` are untouched, so no migration, no behavior change for existing
`agent-providers.json` files. This plan DOES add one **pure convenience
mutator** (`replacingProviders(_:)`) to `AgentProvidersConfig` (§3e) — that is a
new method, not a stored-field or coding change, and it mirrors the existing
carry-everything-through mutators (`settingDefault`, `settingChatProvider`,
etc.). The engine/launcher files are still untouched.

## Out of scope (explicitly)
- No change to `AgentLauncher`, `ACPBackend`, `SpawnModelGuard`, or engine routing.
- No change to `PermissionPolicy`, `PermissionModeKey`, `PermissionModeSelector`
  (still used by `ChatView` + the engine). Only the policy *pickers' UI* is removed.
- `ProviderEditorView` (the Edit… sheet) is kept **as-is**, including its Model
  `Section` + Refresh Models button. It is now a second surface editing the same
  `selectedModelId`; this redundancy is accepted (both bind the same field and
  stay consistent). Rationale: the manual model-discovery probe lives there and
  moving it is out of scope.

## Files

### 1. `Sources/WikiFS/Window/WikiFSApp.swift` — remove the Permissions tab + fix a stale comment
- Delete the `PermissionsSettingsView(containerDirectory:)` tab entry, its
  `.tag(SettingsTab.permissions)`, its `.tabItem { Label("Permissions", ...) }`,
  and the preceding explanatory comment block (currently ~lines 511–519).
- Remove `case permissions` from `enum SettingsTab` (currently ~line 532).
- Leave the remaining three tabs (Zotero / Extraction / Agents) and the
  `settingsSelectedTab` binding (which already falls back to `.zotero` for
  unknown/removed raw values, so a stored `"permissions"` selection silently
  routes to Zotero on next launch — no migration needed).
- **Update the stale doc comment** on `confirmQuitKey` (currently lines 587–590,
  which say "Settings → Permissions → App Behavior … Referenced by
  `PermissionsSettingsView`"). Replace with: *"`@AppStorage` key for the
  ask-before-quitting behavior. Default is `true` (ask) when unset. The Settings
  toggle was removed with the Permissions tab; the key stays because
  `AppDelegate` reads `confirmBeforeQuitting` for quit gating."* Do NOT delete
  `confirmQuitKey` / `confirmBeforeQuitting` — `AppDelegate:706` still reads it.
- Verified: no caller passes `"permissions"` to `openSettings(tab:)` — the only
  caller (`ActivityWindowView.swift:446`) passes `"extraction"` or `"agents"`.

### 2. `Sources/WikiFS/Settings/PermissionsSettingsView.swift` — delete the file
- Remove the entire file. Verified its only external reference was the
  `WikiFSApp.swift` tab entry being deleted in step 1 (plus its own `#Preview`).
- Do **not** delete `PermissionModeSelector.swift` — it is still used by
  `ChatView` (`PermissionModeSelector(rawValue: $permissionModeRaw)`-style init).

### 3. `Sources/WikiFS/Settings/AgentsSettingsView.swift` — inline controls + drop the header + fix field-carrying

#### 3a. Remove the `CollapsibleDetailHeader` wrapper from `body`
- Delete `@State private var isExpanded = true` and its doc comment (~lines 47–51).
- Rewrite `body` so it returns the `providersSection` directly with the same
  modifiers currently attached inside the header's content closure:
  - `.frame(minWidth: 560, minHeight: 520, alignment: .top)`
  - `.sheet(isPresented: $showAddSheet) { … }`
  - `.sheet(item: $editingProvider) { … }`
  - `.confirmationDialog(...) { … }`
- Keep all existing sheet/sheet/confirmationDialog content byte-for-byte; only
  the wrapping `CollapsibleDetailHeader(systemImage:title:isTitleDisabled:isExpanded:onTitleCommit:)`
  container goes away. Verified safe: those modifiers are on `providersSection`
  *inside* the header's content closure, so they re-attach directly to the view.

#### 3b. Rewrite `providerRow(_:)` — inline Model dropdown + mode chips
Current row (lines ~242–292) renders: toggle, label+badges, command, a model
status `switch`, then `Spacer()`. New row shape (enabled provider):

```
[○]  claude [badges]                      Chat  Ingest  Lint     Model [sonnet ▾]
     claude acp                             ●     ●       ○
                                          (orange "pick one before running" caption
                                           only when modelStatus == .noSelectionPickable)
```

Concretely, inside the existing `HStack(spacing: 10)`:
- **Keep** the leading `Toggle` (enabled switch), the `VStack(alignment: .leading)`
  with label+badges + command, and the `.opacity(provider.enabled ? 1.0 : 0.55)`.
- **Replace** the model-status `switch Self.modelStatus(for:in:)` block AND the
  trailing `Spacer()` with a trailing `Spacer()` followed by a new
  `providerControls(provider)` view (see 3c). The status `switch` moves into
  `providerControls` as a compact caption so `modelStatus` stays **used**.
- **Disabled providers** (`!provider.enabled`): hide `providerControls`
  entirely (a disabled provider can't be mode-pinned and the launcher won't
  select it). Keep the dimmed label/command.

#### 3c. Add `providerControls(_:)` + helpers
A new private view + helpers, mirroring the patterns in the deleted
`PermissionsSettingsView` (lift its `setChatProvider`/`setModel`/`operationRow`
idioms):

```swift
@ViewBuilder
private func providerControls(_ provider: AgentProvider) -> some View {
    VStack(alignment: .trailing, spacing: 4) {
        HStack(spacing: 8) {
            modeChip(.chat,   provider: provider)
            modeChip(.ingest, provider: provider)
            modeChip(.lint,   provider: provider)
            Divider().frame(height: 16)
            modelPicker(provider)
        }
        // Compact caption — keeps modelStatus in use.
        switch Self.modelStatus(for: provider, in: config) {
        case .noSelectionPickable:
            Text("pick one before running")
                .font(.caption2).foregroundStyle(.orange)
        default: EmptyView()   // .noneCaptured shown by modelPicker; .selected needs nothing
        }
    }
}
```

- `modeChip(_ mode:, provider:)`: a small bordered button (`.buttonStyle(.bordered)`,
  `.controlSize(.small)`). Active when `mode.isPinned(to: provider.id, in: config)`.
  Tap action:
  - if active → `save(config.settingXxxProvider(id: nil))` (un-pin → default fallback)
  - if inactive → `save(config.settingXxxProvider(id: provider.id))` (pin to this row)
  Use a private `enum Mode { case chat, ingest, lint }` with `isPinned(to:in:)`
  and `apply(to:id:)` helpers so the chip logic is table-driven (no triplicated switch).
- `modelPicker(_ provider:)`: a `Picker("Model", selection: modelBinding(for: provider))`.
  - Options: `Text("Agent default").tag("")` + `ForEach(cachedModels) { Text($0.name).tag($0.modelId) }`.
  - When `cachedModels.isEmpty`: `.disabled(true)` and the picker's content is a
    single `Text("Chat to discover models").tag("")`.
  - `modelBinding(for:)`: `Binding(get: { config.selectedModelId(forProvider: provider.id) ?? "" }, set: { newID in save(config.settingSelectedModel(newID.isEmpty ? nil : newID, forProvider: provider.id)) })`.

> Note on `modelWarning` (accuracy): `modelStatus` stays used in `providerControls`.
> `modelWarning` is **not** called from rendering code today and the plan doesn't
> change that — it survives solely as a pure, directly-tested helper
> (`AgentsSettingsViewWarningTests`). Keep it and its test; do not claim it is
> "used by the view."

#### 3d. Footer note (replaces the old "Select a provider and click Edit…" caption)
Update the existing footer `Text` under the list (currently ~lines 186–192) to:
> "Pin Chat / Ingest / Lint to a provider with the chips on each row. Modes you
> don't pin use the default provider. Use Edit… for command, environment, API
> key, and Refresh Models."

#### 3e. Fix field-carrying in existing mutators (addresses plan-reviewer HIGH)
**Problem:** four existing callers — `enabledBinding` (~366), `applyEdit`
(~397), `appendProvider` (~425), `removeProvider` (~450) — construct a new
config via the 4-field `AgentProvidersConfig(providers:providerModels:selectedModelIds:favoriteModelIds:)`
form, which **defaults `maxConcurrent` to `[:]` and `chatProviderId`/
`ingestProviderId`/`lintProviderId` to `nil`**. Today that silently wipes the
per-mode pins + concurrency on every enable-toggle / add / remove / edit. With
mode chips now on the same rows, the wipe becomes *visible* (pin Chat to X,
toggle Y's enabled switch, watch Chat snap back to default) — so this must be
fixed for the feature to work.

**Fix (primary — add a carry-through mutator):** add to
`Sources/WikiFSCore/Core/AgentProvidersConfig.swift`:

```swift
/// PURE mutator: returns a NEW config with `providers` replaced (re-normalized
/// by `init`) and EVERY other field carried through unchanged. Use this from
/// call sites that only want to change the providers list — the memberwise init's
/// defaulted fields silently drop the per-op provider pins + maxConcurrent.
public func replacingProviders(_ providers: [AgentProvider]) -> AgentProvidersConfig {
    AgentProvidersConfig(
        providers: providers,
        providerModels: providerModels,
        selectedModelIds: selectedModelIds,
        favoriteModelIds: favoriteModelIds,
        maxConcurrent: maxConcurrent,
        chatProviderId: chatProviderId,
        ingestProviderId: ingestProviderId,
        lintProviderId: lintProviderId)
}
```

(`init` already calls `normalized(providers)`, so the single-default invariant
is preserved — `removeProvider`'s re-normalization behavior is unchanged.)

Then route the four callers through it:
- `enabledBinding`: `save(config.replacingProviders(updated.providers))`
- `appendProvider`: `save(config.replacingProviders(updated.providers))`
- `removeProvider`: `save(config.replacingProviders(updated.providers))`
- `applyEdit`: `save(config.replacingProviders(providers).settingSelectedModel(selectedModelId, forProvider: updated.id))`

**Fallback (if you prefer not to touch the model file):** in each of the four
callers, pass all eight fields explicitly
(`…, maxConcurrent: updated.maxConcurrent, chatProviderId: updated.chatProviderId,
ingestProviderId: updated.ingestProviderId, lintProviderId: updated.lintProviderId`).
Equivalent result, more repetition.

**Regression test (required):** add a unit test to the `AgentProvidersConfig`
test file asserting `replacingProviders(someProviders)` carries
`chatProviderId`/`ingestProviderId`/`lintProviderId`/`maxConcurrent` through
unchanged (the exact bug). This guards against the field set drifting again.

## Tests / verification
- Run `make build` (regenerates `GeneratedPrompts.swift` / `GeneratedVersion.swift`
  — bare `swift build` does NOT, and CI runs `make version prompts` first), then
  `swift test`.
- Existing tests that must still pass unchanged:
  - `Tests/WikiFSTests/AgentsSettingsViewModelStatusTests` — calls
    `modelStatus(for:in:)` directly (pure func, unchanged).
  - `Tests/WikiFSTests/AgentsSettingsViewWarningTests` — calls
    `modelWarning(for:in:)` directly (pure func, unchanged).
- New test: `replacingProviders` carry-through regression (§3e).
- No test references `PermissionsSettingsView` or `SettingsTab.permissions`
  (verified by grep). If any test imported the deleted file, update it.
- Manual smoke (cannot be automated — no SwiftUI UI test harness in this repo):
  open Settings → Agents and confirm (a) no collapsible title bar; (b) each
  enabled provider row shows the three mode chips + Model dropdown on the right;
  (c) changing the dropdown persists; (d) toggling a chip re-pins the mode;
  (e) toggling a DIFFERENT provider's enabled switch does NOT wipe existing pins
  (the §3e regression); (f) the Permissions tab is gone.

## Acceptance criteria
1. Settings has three tabs: Zotero, Extraction, Agents. No Permissions tab.
2. `PermissionsSettingsView.swift` no longer exists; `swift build` succeeds with
   no references to it.
3. `AgentsSettingsView` has no `CollapsibleDetailHeader`; its body renders the
   providers section directly.
4. Each enabled provider row shows inline mode chips (Chat/Ingest/Lint) + a
   Model `Picker` on the right, both bound to the existing config fields.
5. The four callers in §3e route through `replacingProviders` (or pass all 8
   fields); the new carry-through regression test passes.
6. `swift test` is green.
7. No engine/launcher files changed (`AgentLauncher`, `ACPBackend`,
   `SpawnModelGuard` untouched).

## Review Strategy
- **Plan-mode review:** via the `plan-reviewer` subagent before handoff — DONE.
  It returned 1 HIGH (the §3e field-dropping bug), 2 MEDIUM (missing Review
  Strategy / Risks sections), and 4 LOW (stale comment, `modelWarning` claim,
  `save()` claim, missing docs section). All are addressed in this revision:
  HIGH → §3e; MEDIUMs → this section + Risks; LOWs → §1 comment, §3c note,
  Notes below, Documentation Strategy.
- **Post-implementation verification (by the orchestrator during babysit):**
  after the implementer opens the PR, read the diff and confirm (1) no
  engine/launcher/data-model *storage* files changed, (2) the §3e fix is present
  in all four callers and the regression test exists, (3) CI (`swift test`) is
  green. If any of those fail, send the implementer a correction before merge.

## Risks, Blockers, and Required Decisions
1. **Pre-existing field-dropping bug** (was HIGH) — fixed by §3e. Until the fix
   lands, the inline chips would visibly de-pin on any enable toggle. The fix
   is mechanical and low-risk; the regression test pins it.
2. **No automated UI test coverage.** AC items 3 and 4 (collapsible header gone;
   chips/dropdown render and persist) are manual-smoke only — this repo has no
   SwiftUI snapshot/UI test harness. The implementer should smoke-test in a
   running app; the orchestrator cannot verify visually.
3. **"Agent default" picker option is a `SpawnModelGuard` dead-end.** Selecting
   it leaves `selectedModelId` empty, which makes the launcher refuse to spawn.
   This is pre-existing (the `ProviderEditorView` picker has the same option)
   and is mitigated by the `.noSelectionPickable` → "pick one before running"
   caption. No change to `SpawnModelGuard`.

## Documentation Strategy
- Update `PROGRESS.md` with: Permissions tab removed; model selection + per-mode
  assignment (chat/ingest/lint chips) moved inline onto the Agents provider rows;
  the §3e field-carrying fix. A future agent reading `PLAN.md`/`PROGRESS.md`
  should know the Permissions tab no longer exists and where the per-mode model
  config now lives.
- No user-facing docs exist beyond the app itself (Settings UI is self-describing
  via the footer note in §3d).

## Notes for the implementer
- `save(_:)` currently uses **bare `try?`** at line ~470 (pre-existing — it
  silently swallows persistence failures). Do NOT introduce *new* bare `try?`.
  Since §3e touches the callers of `save` (not `save` itself), upgrading `save`
  to `do/catch + DebugLog` is **optional and out of scope**; do it only if it's
  a one-line change and doesn't expand the diff meaningfully.
- Route all logging through `DebugLog` (house rule). No `print`.
- Consult `docs/skills/swiftui-pro/SKILL.md` + `macos-design` before/after for
  chip + picker styling (filter iOS-26-only APIs; target is macOS 15 / Swift 6.0).
- Keep the row readable at the default window width (560 min); if the three chips
  + dropdown overflow, compress chip labels to icons (`bubble.left`,
  `tray.and.arrow.down`, `checkmark.seal`) with tooltips rather than truncating.
