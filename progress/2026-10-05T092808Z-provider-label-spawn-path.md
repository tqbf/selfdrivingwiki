---
timestamp: 2026-10-05T092808Z
title: Provider-labeled launch failure and login-shell PATH in the spawn environment
branch: bugfix/issue-1368-provider-label-spawn-path
status: in-review
---

# Provider-labeled launch failure and login-shell PATH in the spawn environment

## Progress

Issue #1368: a chat send failed with "Failed to launch claude: … env: node:
No such file or directory" while the selected provider was codex-acp (chat
01M45104K1THXB7AREMWRKTZ6G, 2026-10-04 20:17). Two defects.

Defect 1 — the wrong name in the failure message. Two catch sites in
`AgentLauncher` hardcoded the prefix "Failed to launch claude": the queued
`run()` spawn catch and the `startInteractiveQuery` backend.start catch. The
real provider id sat on the neighboring log line. A user running codex read
"trying to start claude" and misdiagnosed the failure. Both sites now name
the resolved provider's label (`"Failed to launch \(provider.label): …"`).
Message text only — the error flow is unchanged, and a grep for other
user-facing "claude" strings on the spawn path found none (the rest are
comments and code identifiers).

Defect 2 — the spawned child had no usable PATH. The provider command runs
`bun x @agentclientprotocol/codex-acp`; bunx installs the package and execs
its bin, whose shebang is `#!/usr/bin/env node`. The daemon resolves a
login-shell PATH to FIND the executable, but the child never saw it:
`ACPBackend.resolveSpawnConfig` built the environment from `env.`-prefixed
provider hints only, so the child inherited the daemon's minimal launchd
PATH — which lacks `~/.local/bin` and the mise directories where node lives.

The fix threads the already-resolved login-shell PATH to the child at the
one seam every ACP launch traverses:

- `AgentRunContext` carries the RAW login-shell resolution
  (`resolvedLoginShellPATH`, nil when the hop failed) beside the existing
  fallback-applied `userPATH`. `makeRunContext` resolves it once per run —
  no new login-shell spawns per launch.
- `BackendProfile.loginShellPATH` is trusted launch data for callers that
  hold a discovery PATH (same pattern as `packageRunnerTempURL`), and
  outranks the run-context value.
- `ACPBackend.resolveSpawnConfig` sets the spawn environment's `PATH` from
  that value, replacing the daemon's inherited PATH. A provider-configured
  `env.PATH` still wins — explicit user config beats host injection. No
  resolution and no `env.PATH` leaves `PATH` unset; no default is invented.
- `AgentRunContext.environment` keeps the trusted wikictl helper directory
  as the PATH head and makes an explicit PATH the tail, so the injected
  login-shell PATH (or a user `env.PATH`) replaces the inherited entries
  instead of being discarded by the protected-key overwrite. Routing,
  scratch, and temp keys stay protected.
- `buildAgentEnv` (the legacy `cli`-only composition) prepends the helper
  head on top of a spawn-environment PATH instead of letting the inherited
  PATH ride underneath.
- The seatbelt launch plan (#1251) passes the environment through unchanged
  except `TMPDIR`; a test now pins that PATH survives the wrapper.
- `ACPProviderModelProbe` composes its own child environment, so it accepts
  the same `loginShellPATH` and rides the shared plan. The three production
  catalog-probe defaults resolve it through `PathPreflight.loginShellPATH()`
  — one hop per probe, the same resolver the daemon uses for discovery — so
  probe launches behave like chat launches.
- The sandbox-exhaustiveness audit's exemption fragment for the probe's
  configuration-only `BackendProfile` was updated to the new constructor
  text (the count inventory was unchanged).

`bun x --bun` stays a follow-up per the issue recommendation: it changes
only the default argv, does not fix user-customized agent-providers.json
entries, and waits on the bundled-runtime work. The PATH fix covers every
ACP package with a node shebang, whatever the argv.

## Verification

- `make build` passed (app built and signed).
- `make test` passed (full default SwiftPM suite, exit 0, 0 failed —
  includes `DocumentationContractTests`,
  `LLMSpawnSandboxExhaustivenessTests`).
- `WIKIFS_APP_TESTS=1 swift test --parallel` (the opt-in app-tests graph)
  ran with this change: every suite that exercises the changed seams passed
  — `ACPWiringTests`, `AgentRunContextTests`,
  `AgentLauncherLaunchLabelTests` (new), `LLMSpawnSandboxExhaustivenessTests`,
  `ACPChatResumeTests`, `AgentLauncherLaunchFailureCompletionTests`,
  `ACPProviderModelProbeTests`, `ACPIngestPlanTests`. The graph also has
  pre-existing local-environment failures in suites this change does not
  touch (renderer/webview/extraction: `SourcesTests`, `PdfExtractionServiceTests`
  expects uv NOT installed, `YouTubeEmbedWebViewTests`, `DiagramEmbedTests`,
  and neighbors); each verified to fail identically on the base commit
  (stash → run → same failures → restore).
- New suites/tests: `AgentLauncherLaunchLabelTests` (2 tests: the queued
  `run()` catch and the interactive catch each name the non-claude provider
  label and never contain "claude"); `ACPWiringTests` +6 (seam injects the
  login-shell PATH; profile value outranks the run-context value; run-context
  fallback; provider `env.PATH` wins over injection; PATH unset without
  resolution; sandbox plan passes PATH through; `buildAgentEnv` helper-head
  prepend); `AgentRunContextTests` updated +3 (protected keys still win
  minus PATH, explicit PATH becomes the tail under the helper head, no
  explicit PATH keeps `effectivePATH`, `withScratch` preserves the raw
  resolution).
- The operator should rebuild and reinstall the app so the running daemon
  picks up the fix.
