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

## Review round (PR #1371)

Four code-review findings, all fixed on the same branch.

**1 (MAJOR) — the PATH injection was nil-by-construction on two spawn
shapes.** The first commit threaded the login-shell PATH through the
LAUNCHER's profile, but two other shapes build a `BackendProfile`
themselves and had neither a run context nor a `loginShellPATH`:
`AgentProviderRuntime.backend(from:)` (the summarizer/title profile) and
`ACPExtractionClient.makeProfile` (the extraction profile). Both children
still inherited the daemon's minimal PATH, so #1368 persisted for
chat-summary, chat-title, and ACP-extraction spawns.

- Summarizer/title: `AgentProviderRuntime` takes an injected
  `LoginShellPATHResolver` (production default
  `PathPreflight.loginShellPATH()`), resolves it ONCE per summarization
  snapshot in `prepareSummarization`, carries it on
  `Snapshot.summarizerLoginShellPATH`, and rides it on the profile. One
  cached backend serves many summary/title spawns, so the per-snapshot
  scope is the narrowest one that keeps the hop off the spawn path.
- Extraction: `ACPExtractionClient` carries the `searchPath` its
  `resolveProvider` ALREADY needed to resolve the provider's command — no
  second hop — and `makeProfile` puts it on the profile. The production
  wiring closures resolve that PATH once per provider resolution.
- `ExtractionPluginFactory.ACPResolver` became `async` so the production
  extraction wiring can do that one hop (both `ProcessExtractionServices`
  and the legacy `ExtractionRuntimeFactory` resolver now `await` it).

**2 (MINOR) — a residual "Claude CLI" hardcode.** `PathPreflight.resolve`'s
generic `.missing(reason:)` text told every user to "Install the Claude CLI
(claude.com/claude-code)", and `AgentLauncher.resolveACPProviderSpawn`
surfaced that verbatim for ANY provider. The generic reason is now
provider-neutral ("Install it and make sure it is on your login shell
PATH"); the provider-specific hint path (`readinessMessage` /
`ProviderEnvHint`) is unchanged.

**3 (MINOR) — the new suite was invisible to the default gate.**
`.github/workflows/ci.yml` DOES run `WIKIFS_APP_TESTS=1` steps, but only
three of them and each with an explicit `--filter` list (the Cordis search
group, the chat-lifecycle group, the Phase 5 WebKit group). None of those
lists names `ACPWiringTests`, `AgentRunContextTests`, or the new
`AgentLauncherLaunchLabelTests`, so a suite in `Tests/WikiFSAppTests` would
have had no CI coverage. `AgentLauncherLaunchLabelTests` MOVED to
`Tests/WikiFSTests` (the default graph): it needs `AgentLauncher` and a
failing backend fake, and that target already links `WikiFSEngine` and the
`FakeAgentBackend` with `shouldFailOnStart`, so coverage is not weakened.
The pre-existing `ACPWiringTests` and `AgentRunContextTests` stay where they
are.

**4 (NITs).** `AgentProvider.displayName` is the new single seam for
user-facing provider text (the label, else the provider id) and both
launch-failure catch sites use it — an empty hand-edited label no longer
renders "Failed to launch : …". `PathPreflight.loginShellPATH()` stays
unbounded; the accepted risk is now documented on the method (the hop runs
on user-triggered discovery paths, never per spawn, and bounding it would
need a cancellation/timeout race around `AsyncProcessRunner`).

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
- New suites/tests: `AgentLauncherLaunchLabelTests` (3 tests: the queued
  `run()` catch, the interactive catch, and the empty-label fallback — each
  names the non-claude provider and never contains "claude" or
  "Failed to launch :"); `ACPWiringTests` +6 (seam injects the
  login-shell PATH; profile value outranks the run-context value; run-context
  fallback; provider `env.PATH` wins over injection; PATH unset without
  resolution; sandbox plan passes PATH through; `buildAgentEnv` helper-head
  prepend); `AgentRunContextTests` updated +3 (protected keys still win
  minus PATH, explicit PATH becomes the tail under the helper head, no
  explicit PATH keeps `effectivePATH`, `withScratch` preserves the raw
  resolution); `AgentProviderRuntimeTests` +2 (the summarizer profile
  carries the snapshot's injected login-shell PATH into the child
  environment; a failed resolution leaves the child `PATH` unset);
  `ACPExtractionClientTests` +2 (the extraction profile carries the resolved
  search path into the child `PATH`; a provider `env.PATH` still wins);
  `AgentProvidersConfigSeedBackfillTests` +1 (`displayName` falls back to the
  provider id).
- Review-round gates: `make build` exit 0; `make test` exit 0 with 0 failed
  (the moved `AgentLauncherLaunchLabelTests` and all new pins run in that
  default graph); targeted `WIKIFS_APP_TESTS=1 swift test --parallel`
  `ACPWiringTests|AgentRunContextTests|LLMSpawnSandboxExhaustivenessTests`
  exit 0 (69 tests in 2 suites plus 11 in the sandbox suite).
- The operator should rebuild and reinstall the app so the running daemon
  picks up the fix.
