---
timestamp: 2026-07-18T233052Z
title: "2026-07-18 — Require explicit model selection before agent spawn (branch `fix/require-explicit-model`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-18 — Require explicit model selection before agent spawn (branch `fix/require-explicit-model`)

## Progress


**Problem:** The 2026-07-18 "Working Hypnotically with Children" ingestion stall
(`tmp/ingestion-stall-diagnosis.md`) had multiple causes; this fix targets one of
them — the OpenCode provider was `isDefault: true` with no entry in
`selectedModelIds`, so the launcher passed `nil` to `providerHints`, and the ACP
subprocess silently fell through to its first-listed upstream —
`opencode/big-pickle`, a free model nobody chose (diagnosis root cause #6, an
amplifier of the stall). The dominant cause — `alwaysAsk` permission prompts
with no timeout — is out of scope here (see Scope Boundaries in
`plan-001.md`) and tracked as a separate follow-up.

**Fix:** Added a pure `SpawnModelGuard.validate(provider:modelId:)` helper
(`Sources/WikiFSEngine/SpawnModelGuard.swift`) that returns an actionable
preflight error when the resolved provider has no `selectedModelId`. Wired into
both spawn paths:
- `AgentLauncher.resolveStageRouting` — covers all three ingest stages
  (planner / executor / finalizer) through one choke-point. Placed AFTER the
  PATH-preflight so the more-fundamental "executable missing" error wins when
  both are wrong.
- `AgentLauncher.startInteractiveQuery` — interactive chat. Placed BEFORE the
  PATH-preflight (missing model is a configuration issue we surface first).

The error message includes the provider's label (actionable) and
"Settings → Agents" (discoverable).

Also added a yellow warning caption to the provider row in `AgentsSettingsView`
(`Sources/WikiFS/Settings/AgentsSettingsView.swift`) when no model is selected,
gated by a pure static `modelWarning(for:in:)` helper. Non-blocking — models are
discovered live on first spawn, so blocking save would break new-provider
onboarding. Disabled providers show no caption (they can't spawn anyway).

**Fresh-install safety:** the shipped `AgentProvidersConfig.seed` now pairs the
`claude-acp` default with `selectedModelIds["claude-acp"] = "sonnet"` so a fresh
install can spawn chat/ingest on day one — without this the guard would create a
hard circularity (you must spawn to discover models, but the guard refuses to
spawn until a model is picked). The `loadOrSeed` backfill mirrors this for
existing `claude-acp`-default installs whose `selectedModelIds` was empty —
upgrade-safety only, does NOT touch non-default providers or an existing
non-empty `claude-acp` entry.

**Behavior change:** All providers now require an explicit model selection
before they will spawn, including `claude-acp` (which historically accepted nil
and defaulted to its first-listed model — effectively Sonnet, now the seeded
default). Existing configs with no `selectedModelIds["<id>"]` entry for the
resolved provider must set one via Agents settings before chat or ingest will
run; the preflight error points the user there.

**Accepted UX wrinkle (tracked for follow-up):** a freshly-added provider (not
the shipped seed) has no cached models until its first successful spawn — but
the guard refuses that first spawn. The yellow caption ("No model captured yet
— chat with this provider once to discover models") is the guidance for this
state; a future dry-run `session/new` on Save would close the loop.

**Tests:** `SpawnModelGuardTests` (pure helper), `AgentsSettingsViewWarningTests`
(pure `modelWarning` helper), `AgentProvidersConfigSeedBackfillTests` (seed +
backfill preserve/non-default), a new `AgentLauncherSpawnRefusalTests`
(chat-path refusal with injected config), and an extension to
`AgentProviderModelTests` (the bug-precondition: nil modelId when no selection).

## Verification

Historical verification remains in the progress record above.
