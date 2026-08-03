---
timestamp: 2026-07-13T023132Z
title: "2026-07-12 — ACP Multi-Provider: Phase 4 (legacy deletion)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-12 — ACP Multi-Provider: Phase 4 (legacy deletion)

## Progress


**What shipped.** Phase 4 of `plans/acp-multi-provider.md` — the app is now
ACP-only. All legacy Claude-CLI code paths, config types, and settings UI were
deleted. This completes the 4-phase plan (Phases 1–3 shipped in commit
`50d1c0f`).

**Deleted (12 files, ~3585 lines of source + tests):**
- `Sources/WikiFSEngine/ClaudeCLIBackend.swift` — the `claude -p` stream-json
  backend. `AgentBackendFactory.makeBackend` now always returns `ACPBackend`.
- `Sources/WikiFSCore/AgentCommandConfig.swift` — `agent-command-config.json`
  (executable, prefix-args, model override, extra env). The tokenizer + tilde-
  expansion helpers were extracted to `ShellArgv.swift` (both call sites in
  `AgentBackendFactory.providerHints` and `AgentLauncher` still need them).
- `Sources/WikiFSCore/ACPAgentConfig.swift` — `acp-agent-config.json`
  (dead wiring kept for old tests; the real path was always
  `AgentProvidersConfig`).
- `Sources/WikiFSCore/OperationCommand.swift` — the pure-argv assembly type
  (`OperationCommand.build`). With the CLI backend gone, spawn argv is built
  directly in `AgentLauncher` from `AgentSpawnConfig`.
- `Sources/WikiFSCore/ClaudePromptHelp.swift` + `ClaudePromptHelpDocument.swift`
  + 3 view files (`ClaudePromptHelpView`, `ClaudePromptHelpCommands`,
  `PromptHelpSectionView`) — the in-app Claude prompt debugger/help feature.
- `Sources/WikiFS/AgentCommandSettingsView.swift` +
  `AgentProvidersSettingsView.swift` — the old Agent + Providers settings tabs
  (replaced by the unified `AgentsSettingsView` in Phase 3).
- Tests: `ACPConfigTests`, `AgentCommandConfigTests`, `ClaudePromptHelpTests`,
  `OperationCommandTests`, `SandboxedOperationCommandTests`.

**New file:**
- `Sources/WikiFSCore/ShellArgv.swift` — `tokenize(_:)` (shell-style argv
  splitting, no shell invoked) + `expandTilde(_:)`. Extracted from
  `AgentCommandConfig` since `AgentBackendFactory.providerHints` and
  `AgentLauncher`'s ACP spawn resolution still need both transforms,
  independent of the deleted CLI config type.

**Key model changes:**
- `AgentProvider.backend` field (`.claudeCLI` / `.acp`) removed — all providers
  are ACP. The old `claudeDefault` (id `"claude"`, CLI, no command) was replaced
  by `claudeAcpDefault` (`bun x @agentclientprotocol/claude-agent-acp`).
- `AgentProvidersConfig` no longer injects `claudeCachedModels` (`["opus",
  "sonnet", "haiku"]`) — model lists always come from ACP discovery.
- `IngestPlan` stripped of opus/sonnet tiering (`topLevelModelAlias`,
  `agentsJSON`, `digesterPrompt`) — it is now a pure source-size predicate.
  Which provider/model runs each stage is resolved separately via
  `AgentProvidersConfig.resolvedProvider(for:)`.
- `AgentBackendFactory.makeBackend(useACPBackend:policy:)` →
  `makeBackend(policy:)` — no more `useACPBackend` UserDefaults toggle.
- `AgentBackendFactory.providerHints` removed the `.claudeCLI` branch.

**Gates:** `swift build` clean; fast tier **2268 tests in 190 suites pass**.
All remaining references to deleted types are in doc comments documenting the
old architecture — no functional code references remain.

## Verification

Historical verification remains in the progress record above.
