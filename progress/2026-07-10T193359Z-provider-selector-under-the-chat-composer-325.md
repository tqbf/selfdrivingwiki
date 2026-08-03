---
timestamp: 2026-07-10T193359Z
title: "2026-07-11 — Provider selector under the chat composer (#325)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — Provider selector under the chat composer (#325)

## Progress


**Change:** added a compact **provider selector** under the chat composer
(`ChatView`), modeled on paseo's `combined-model-selector` trigger and
translated to native macOS. v1 is **provider-only** (no model drill-down —
selfdrivingwiki doesn't yet collect per-agent models). Picking a provider
sets the persisted default, so the next chat session uses it via the
launcher's existing `resolveSelectedProvider` (no launcher spawn change).

- **Model** (`AgentProvidersConfig.swift`): added `settingDefault(id:)` — a
  PURE mutator that marks one provider default + demotes the rest (enforces
  the single-default invariant via `normalized`), and `enabledProviders` — the
  enabled-only view the selector binds (matches the launcher's
  `selectedProvider()` fallback). The Settings view's inline `setDefault` now
  delegates to the shared mutator (DRY).
- **Launcher** (`AgentLauncher.swift`): added `resolveProvidersContainerDirectory`
  (same container resolution as `resolveSelectedProvider`), a read accessor
  `providersConfig()`, and a `setDefaultProvider(id:)` that sets + persists +
  returns the new config. The composer selector reads + mutates through these.
- **UI** (`Sources/WikiFS/ProviderSelector.swift`, new): a `Menu` trigger —
  glyph + current label + a chevron (`menuIndicator(.hidden)`; we draw our own)
  — opening the enabled providers, with a gear → `@Environment(\.openSettings)`.
  Leading-aligned, `.caption`/secondary, sits below the text field as a
  composer VStack sibling (`providerSelectorBar` in both `emptyState` and
  `chatComposer`). Hidden when no wiki is active.
- **Tests** (`Tests/WikiFSTests/ProviderSelectorTests.swift`, new): the
  `settingDefault` invariant (demotes others, reversible, unknown-id-safe,
  pure), `enabledProviders`, the persist→reload round-trip, and the launcher
  wiring (`setDefaultProvider` → `resolveSelectedProvider` reads it; default =
  Claude when unpicked). 88 ACP/provider tests + the fast tier (2049 tests)
  green.
- **Not verified:** the rendered selector needs a live-UI check (couldn't run
  the GUI here) — compile + unit-test only.

## Verification

Historical verification remains in the progress record above.
