---
timestamp: 2026-07-10T193359Z
title: "2026-07-11 — Agent providers model + Settings UI (#324)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-11 — Agent providers model + Settings UI (#324)

## Progress


**Change:** replaced the slice-3 `useACPBackend` bool + single `ACPAgentConfig`
with a **provider list** (`agent-providers.json`) the user configures in a new
Settings → **Providers** tab. Modeled on paseo's `providers-section.tsx` +
`provider-catalog-list.tsx` + `provider-diagnostic-sheet.tsx`, translated to
native macOS SwiftUI.

- **Model** (`Sources/WikiFSCore/AgentProvider.swift` +
  `AgentProvidersConfig.swift`): `AgentProvider { id, label, backend, command,
  env, enabled, isDefault }` where `enum AgentBackendKind { claudeCLI, acp }`.
  `AgentProvidersConfig` persists to `agent-providers.json` (App Group
  container). `loadOrSeed` seeds **Claude (default, enabled)** + ACP agents
  discovered on PATH. Pure `seed(discovered:)` for tests. Single-default
  invariant enforced by `normalized`.
- **Catalog** (`ACPProviderCatalog.swift`): expanded from 2 → **12 confirmed
  ACP agents** ported from paseo's `acp-provider-catalog.ts` — gemini, hermes,
  copilot, kimi, cursor, kiro, goose, grok, codewhale, kilo, plus the npx
  wrappers `claude-agent-acp` + `codex-acp`. Claude stays OUT (the `.claudeCLI`
  default).
- **Settings UI** (`Sources/WikiFS/AgentProvidersSettingsView.swift`): providers
  list (icon/name + status badge + enable toggle + details), a radio-group
  default selector, an **Add Provider** catalog sheet (searchable, hides
  already-added), and a per-provider detail editor (command, `SecureField` API
  key via Keychain, enable). Native `Form`/`.formStyle(.grouped)`. Used the
  `swiftui-pro` + `macos-design` skills.
- **Launcher wiring** (`AgentLauncher.swift`): new `resolveSelectedProvider`
  seam; both `run()` + `startInteractiveQuery()` now pick the provider from
  config and construct the backend via `AgentBackendFactory.makeBackend(
  provider:policy:)`. `.acp` resolves the provider's PATH command + per-provider
  Keychain key into `providerHints`. **Default = Claude → zero behavior
  change.**
- **Credential store** (`ACPCredentialStore.swift`): added per-provider Keychain
  keying (`apiKey(forProvider:)` / `setAPIKey(_:forProvider:)`), namespaced by
  account `acp-provider:<id>`. The legacy single-key API is preserved.
- `AgentBackendFactory.makeBackend(useACPBackend:policy:)` + the slice-3
  `acpProviderHints(...)` retained (existing tests + `ACPSmokeTests` unchanged).

**Tests:** new `AgentProviderModelTests` (5 suites, 30+ tests) — seed/normalize/
persist/round-trip, catalog expansion + Claude-absent + command[0]==detect,
selection→backend mapping, per-provider Keychain isolation. All existing ACP
suites green. Fast tier: **2041 tests in 170 suites pass.**

**Couldn't verify:** live non-Claude E2E (no creds) — the model/selection/
catalog are unit-tested; `ACPSmokeTests` covers the Claude path. Flagged for
manual E2E when credentials are available.

## Verification

Historical verification remains in the progress record above.
