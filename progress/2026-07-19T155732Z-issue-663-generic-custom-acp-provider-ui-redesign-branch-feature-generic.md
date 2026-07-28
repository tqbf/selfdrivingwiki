---
timestamp: 2026-07-19T155732Z
title: "2026-07-19 — Issue #663: Generic Custom ACP provider + UI redesign (branch `feature/generic-custom-acp`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-19 — Issue #663: Generic Custom ACP provider + UI redesign (branch `feature/generic-custom-acp`)

## Progress


**Problem.** Settings → Agents vended provider creation via three hardcoded
seed buttons (`Add Claude` / `Add Hermes` / `Add OpenCode`) plus a `Custom…`
path that pre-persisted a blank row BEFORE the editor opened (Cancel left
junk in `agent-providers.json`). The runtime layer
(`AgentBackendFactory.makeBackend`) was already fully generic — the only
provider-specific code was in the seeds, the Add buttons, and the
default-fallback logic. So the change was smaller than it appeared.

**Scope (per `tmp/sdw-plans/663-combined-plan.md` + plan-reviewer
corrections):**

### Part 1 — Code removal (statics gone)

- `Sources/WikiFSCore/Core/AgentProvider.swift` — DELETED
  `.hermesDefault` and `.opencodeDefault` statics (~30 lines). KEPT
  `.claudeAcpDefault` as the `selectedProvider()` last-resort fallback
  (defensive safety net for a hand-edited/corrupt config). The
  `acp(from:)` factory is unchanged (the catalog-driven `AddProviderSheet`
  uses it).
- `Sources/WikiFSCore/Core/AgentProvidersConfig.swift`:
  - `seed(discovered:)` now returns `[.claudeAcpDefault]` only (was three
    providers). The `"claude-acp": "sonnet"` `selectedModelId` seed stays —
    `SpawnModelGuard` still needs it for day-one spawnability.
  - `normalized([])` re-seeds `[.claudeAcpDefault]` only. The single-default
    invariant and first-enabled-promotion logic are unchanged.
  - The `loadOrSeed` `claude-acp`-default `"sonnet"` backfill is unchanged
    (upgrade-safety for existing installs).

### Part 2 — UI redesign (AddProviderSheet)

New file: `Sources/WikiFS/Settings/AddProviderSheet.swift` (~370 lines):

- `AddProviderSheet` — the non-destructive Add Provider sheet. Replaces the
  hardcoded seed menu with a two-tier picker sourced from
  `ACPProviderCatalog.agents` (11 entries — Claude, Gemini, Hermes,
  Copilot, Kimi, Cursor, Kiro, Goose, Grok, CodeWhale, Kilo) + a live
  `ACPProviderDiscovery.discover()` PATH scan that runs OFF-main on
  `.task`. Nothing persists until an Add button is pressed (AC.2). Custom
  commands route through an inline `DisclosureGroup` at the bottom.
- `AddProviderModel` (`@MainActor @Observable`) — owns the live scan, the
  search filter (case-insensitive over `label`/`summary`), and the
  `needsEditor(for:)` heuristic. The heuristic (correction §4) drops the
  non-existent `catalogEntryRequiresKey` reference: returns `true` when the
  provider's command is empty (custom add) OR the agent wasn't detected
  on PATH (catalog add for a missing binary — the user may want to tweak
  the command/env/key). A cleanly-detected catalog agent skips the editor
  (fast path: 2 clicks total).
- `ProvidersEmptyState` — native macOS 15 `ContentUnavailableView` shown
  when `config.providers.isEmpty` (defensive — `loadOrSeed` guarantees ≥1).
- `ProviderStatusBadges` — small View for the "Default" capsule badge.
- `ModelStatus` enum + `AgentsSettingsView.modelStatus(for:in:)` — the
  structured `selected`/`noSelectionPickable`/`noneCaptured`/`disabled`
  classifier that the restructured `providerRow` reads. Sibling to the
  existing `modelWarning(for:in:)` (correction §6 — both coexist; the
  `AgentsSettingsViewWarningTests` string-format tests stay load-bearing).

### `AgentsSettingsView` wiring

- Deleted the three seed Menu buttons + the `addSeed(_:)` helper + the
  pre-persist tail of `addCustom()`. Replaced with a single
  `Button("Add Provider") { showAddSheet = true }` and a new
  `appendProvider(_:)` that only writes at confirm time.
- Sequential sheet dismiss→present handoff (correction §5): the
  `onAddNeedsEditor` callback sets `showAddSheet = false` then
  `DispatchQueue.main.async { editingProvider = provider }` so the first
  sheet finishes dismissing before the editor presents — works around the
  SwiftUI hazard where the second `.sheet` silently fails when the first
  is mid-dismissal.
- `providerRow` restructured per §3.2: leading `Toggle` (`.switch` +
  `.controlSize(.mini)` + `labelsHidden()`) + `VStack(label, command,
  ModelStatus line)`. Disabled rows `.opacity(0.55)`; switch stays full
  opacity. Middle-truncates the command line so both executable + tail
  flag stay visible.

### `ProviderEditorView` refactor

- Reordered sections: **Command → Model → Advanced (Environment +
  Authentication)**. The old order had Environment between Command and
  Authentication, cluttering the common case.
- `DisclosureGroup("Advanced")` wraps Environment + Authentication.
  Auto-expands on `.onAppear` when the provider already has env vars OR a
  stored API key (so existing config is never hidden). Documented the
  one-frame collapsed→expanded flash as accepted (correction §7 — Low).
- Cancel button gets `.keyboardShortcut(.cancelAction)` (was missing).
- `.ready` model refresh state now shows a compact `Label("N models",
  systemImage: "circle.fill")` caption (was `EmptyView` — the picker's
  count was the only signal, which disappeared when collapsed).

### Tests (5 existing + 2 new suites)

- `AgentLauncherSpawnRefusalTests` — replaced `.opencodeDefault` references
  with inline `AgentProvider(...)` literals (lines 41, 98).
- `AgentProviderModelTests` — updated seed-order assertions from
  `["claude-acp","hermes","opencode"]` to `["claude-acp"]` (5 sites).
  Replaced the `.opencodeDefault` reference at line 234 with an inline
  literal. Renamed `normalizedReseedsAllThreeWhenEmpty` →
  `normalizedReseedsClaudeAcpOnlyWhenEmpty`,
  `emptyProvidersListReseedsAllThreeDefaults` →
  `emptyProvidersListReseedsClaudeAcpOnly`. New
  `hermesOpencodeIDsRoundTripAfterStaticRemoval` pins **AC.3** (existing
  `agent-providers.json` with hermes/opencode IDs decodes + re-encodes).
- `AgentProvidersConfigSeedBackfillTests` — replaced `.opencodeDefault`
  with inline literal at line 79.
- `AgentsSettingsViewWarningTests` — replaced `.opencodeDefault` (×3) and
  `.hermesDefault` (×1) with inline literals.
- `ChatViewPreflightBannerTests` — replaced `.opencodeDefault` at line 212.
- `SpawnModelGuardTests` — updated the inline-fixture comment to reflect
  that only `claudeAcpDefault` is a static seed now.
- NEW `AddProviderSheetTests` (8 tests) — pins AC.2 (cancel = no change at
  the onAdd seam), AC.6 (`seed()`/`normalized([])` → `[claudeAcpDefault]`),
  the `needsEditor` heuristic (custom-empty, detected, non-detected
  branches), `freshCustomID` collision loop, the dedup contract
  (`otherAgents` excludes both `existingIDs` AND `detected`), and the
  query filter.
- NEW `AgentsSettingsViewModelStatusTests` (7 tests) — pins all 4
  `ModelStatus` branches (`disabled`, `selected(name)` with friendly name
  + raw-id fallback, `noneCaptured`, `noSelectionPickable`), the
  empty-string-selection parity with `modelWarning`, and stability across
  providers with the same state.

### Migration / breaking changes

- **No migration needed for existing configs.** `agent-providers.json`
  rows whose `id` happens to be `"hermes"` or `"opencode"` are just
  `AgentProvider` rows — they decode + re-encode losslessly (AC.3).
  Removing the `.hermesDefault`/`.opencodeDefault` statics does NOT remove
  the user's saved rows.
- The `loadOrSeed` `claude-acp`-default `"sonnet"` backfill is unchanged.

**Build/Tests:** `make version prompts` ✓; `swift build` clean ✓; fast tier
**2772 tests / 236 suites pass** (+15 new across `AddProviderSheetTests` +
`AgentsSettingsViewModelStatusTests` + the `hermesOpencodeIDsRoundTripAfterStaticRemoval`
AC.3 test).

**Status:** PR open (feature/generic-custom-acp), not merged. Closes #663.

## Verification

Historical verification remains in the progress record above.
