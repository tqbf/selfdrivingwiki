---
timestamp: 2026-07-16T162638Z
title: "2026-07-16 — ACP extraction backend (#453)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-16 — ACP extraction backend (#453)

## Progress


**Implemented (branch `bouncy-manatee`).** Added an `.acp` extraction
backend that delegates PDF→Markdown to a user-configured ACP provider
(Claude, Gemini, Hermes, Copilot, …) instead of the hardcoded
`AnthropicExtractionClient` / `GeminiExtractionClient` HTTP clients.

- **New `ACPExtractionClient`** (`Sources/WikiFSEngine/ACPExtractionClient.swift`)
  — a `MarkdownExtractor` conformer that writes the PDF to a temp file,
  spawns an ACP session via `ACPBackend` (reusing the provider's
  `AgentProvidersConfig` + `ACPCredentialStore` Keychain key), sends the
  extraction prompt referencing the file path, and collects the markdown
  from the `AgentEvent` stream. Works with ANY ACP provider — no vendor-
  specific HTTP code, no second Keychain entry.
- **`ExtractionBackend.acp` case** — added to the enum with
  `displayName`, `helpText`, and `agentName` ("acp-extraction" for PROV).
  The old `.anthropic` / `.gemini` cases are retained for backward compat
  (existing `extraction-config.json` files decode fine).
- **`ExtractionConfig.acpProviderId`** — new optional field: the provider id
  to use for extraction. nil = use the app's default provider. Forward-
  compatible (decodes as nil from old config files).
- **`ExtractionCoordinator`** — new `acpCredentialStore` property (defaults
  to `KeychainACPCredentialStore`). The `.acp` case in `current()` resolves
  the provider via `ACPExtractionClient.resolveProvider`, falling back to
  the local extractor if no provider resolves.
- **`ExtractionSettingsView`** — new "ACP Provider" section with a provider
  picker (populated from `AgentProvidersConfig.enabledProviders`). No
  credentials to enter — the API key comes from Settings → Agents.
- **`SourceDetailView` / `QueueExtractionWorker`** — wired the `.acp`
  case into `extractorFor`, `modelVersionFor`, and the queue capacity map.
- **Tests** — 5 new tests in `ExtractionConfigTests` (round-trip, forward-
  compat decode, agent name) and 1 in `ExtractionCoordinatorTests` (falls
  back to local when no provider resolves).

## Verification

Historical verification remains in the progress record above.
