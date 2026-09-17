---
timestamp: 2026-09-17T194500Z
title: Strict summarizer package-runner fix (#1279) — implementation, review, and matrix
branch: bugfix/strict-summarizer-package-runners
status: implementation + review complete; matrix 6/8 full pass, promotion gated
---

# Strict summarizer package-runner fix (#1279)

## Progress

Implemented the approved #1279 plan on
`bugfix/strict-summarizer-package-runners` (commits `3e9f074d` + `7df86d0e`):

1. **Typed package-runner policy** (`PackageRunnerKind` in
   `PackageRunnerTempLease.swift`): classification on executable + argument
   ARRAYS, run on the EFFECTIVE (post-canonicalization,
   post-staleness-fallback) spawn. `providerHomeSubpaths` now derives
   runner caches from the typed classification (npx/npm → `~/.npm`,
   `bun x`/`bunx` → `~/.bun`, uv → the bounded `.cache/uv` +
   `.local/share/uv` pair); codex/gemini config homes stay command-token
   derived (pre-existing convention).
2. **`PackageRunnerTempLease`**: one unique pre-created
   `~/.bun/wikifs-tmp/<UUID>` staging directory per strict summarizer
   snapshot whose configured command is JS-adapter-shaped. Transactional
   allocation (empty-parent-only rollback, shared-parent safe); explicit
   logged `remove()`; owned through the snapshot teardown transaction
   (retire → drain → backend shutdown → **lease** → scratch).
3. **Trusted launch data**: the lease rides `BackendProfile.packageRunnerTempURL`
   — never a provider hint. `sandboxedSpawnPlan` exports it as the child's
   `TMPDIR` only when the EFFECTIVE runner is Bun, overwriting any provider
   temp hint; a declined canonicalization leaves the lease unused and the
   scratch temp in place.
4. **Shared `ProviderCommandResolver`**: both production
   `AgentProviderProcessInput` compositions (daemon `ProductionPluginCatalogs`,
   renderer `RendererCompositionOwner`) plus `resolveACPProviderSpawn` and
   both readiness paths resolve through ONE login-shell-PATH pass with the
   validated `RuntimeCommandLocator` Bun lookup as the only bare-`bun`
   fallback — the shipped bare `bun x …` command now resolves from the GUI
   daemon (source-audit-pinned by `ProviderCommandResolverWiringTests`).
5. **Strict stays default-OFF.** The pure
   `strictSummarizerEnabled(environment:)` parser (unset/`1`/unknown → on;
   `0`/case-insensitive `false` → off, fail-secure) is in and unit-tested;
   the production static still uses the conservative `== "1"` opt-in. The
   promotion commit must delegate the static to the parser — that wiring is
   the flip (review MEDIUM-1, documented as REQUIRED in the source).

An implementation review (general-purpose subagent) found **no critical and
no high findings**; the three actionable findings (doc/comment accuracy,
lease-rollback shared-parent safety, dispose-order assertion) are fixed in
`7df86d0e`. `git diff main...HEAD -- Sources/WikiFSCore/Core/SandboxProfile.swift`
is empty — the strict trailer and W^X scratch are untouched, verified by
live `sandbox-exec` tests both ways (staged executable runs from the lease;
scratch, `scratch/.tmp`, and global temp stay exec-denied with a lease in
play).

## Matrix (issue #1279 acceptance gate)

App: `build/Self Driving Wiki.app` commit `3e9f074d` (bundle version 1121),
installed to /Applications via `make install`. The strict flag reached the
`wikid` XPC daemon via `XPCService/EnvironmentVariables` in the installed
bundle's Info.plist (launchd sanitizes XPC env; `launchctl setenv` and a
top-level `EnvironmentVariables` key both do NOT propagate — see
Environment, below). Scratch wiki `Sandbox Smoke 1279`
(`01M2K6KZRMXKQAWHPZTGXE29QJ`), two turns per cell, `summary_kind='model'`
verified in SQLite, `sandboxd` captured per cell with a 10-minute delivery
margin.

| Cell | Command | Result |
|---|---|---|
| codex warm (shakedown) | `npx @agentclientprotocol/codex-acp@1.1.7` | full pass — title + model summaries, 0 denials |
| codex-npx COLD (`~/.bun`+`~/.npm` moved aside) | same | full pass — cold bun staging from the lease, 0 denials |
| codex-npx WARM | same | full pass, 0 denials |
| gemini-npx COLD (`~/.bun` moved aside) | `npx @google/gemini-cli@0.56.0 --acp` | full pass, 0 denials |
| gemini-npx WARM | same | full pass, 0 denials |
| fast-agent-uv COLD (`~/.cache/uv` moved aside) | mise `uvx fast-agent-acp@latest --model sonnet` | sandbox pass — cold uv cache install ALLOWED under the fence, `initialize OK agent=fast-agent-acp`, session ran; failure is pure auth (`Could not resolve authentication method`); 0 denials |
| fast-agent-uv WARM | same | sandbox pass — same clean auth-only failure; 0 denials |
| claude-bun COLD | `bun x @agentclientprotocol/claude-agent-acp` (shipped bare form) | adapter staged + executed from the lease; failure is Claude OAuth expiry (`OAuth session expired`) — **SKIPPED by operator decision** |
| claude-bun WARM | same | **SKIPPED by operator decision** |

Operator decision (2026-09-17): the two claude-acp rows are dropped from
this matrix round ("don't bother with claude" — the Claude Code OAuth
session on this machine was expired and went unrefreshed). Consequences,
per the plan's own rule (do not claim a full pass on auth-blocked cells):

- AC.11 is NOT claimed: 6 of 8 cells are full passes; the 2 uv cells are
  sandbox-only passes (no uv credentials on this machine), and the 2 claude
  cells are skipped.
- **The strict default stays OFF.** The promotion commit is NOT made.
  `AgentProviderRuntime.strictSummarizerEnabled` remains the conservative
  opt-in (`WIKIFS_SUMMARIZER_STRICT=1` enables; unset/`0` = off). The
  flip's required wiring — delegate the static to the pure fail-secure
  `strictSummarizerEnabled(environment:)` parser (already implemented and
  unit-tested) — is documented in the source and is the ONLY remaining
  change a future promotion needs, gated on rerunning the two claude cells
  and the two uv cells with credentials.

Notes:

- The shipped bare `bun x` command resolved from the daemon without any
  absolute-path configuration (AC.9) — every bun-cells launch above used the
  shipped configuration form.
- The uv row used the mise-managed `uvx` (the repo's pinned uv) because the
  machine's bare `uvx` resolves to a broken standalone-install shim
  (`~/.local/bin/uvx` with no sibling `uv`; exits before any cache write).
  This is an environment defect, not a sandbox or product issue; the plan's
  no-absolute-path rule targets the bun resolution bug (AC.9).
- Degradation contract observed live: every auth-failed summarizer degraded
  to default truncation / provisional title exactly per the strict failure
  contract.
- Lease lifecycle observed live: `~/.bun/wikifs-tmp` gained one directory
  per live snapshot and was emptied by teardown across cells (release
  replaces the snapshot; the last snapshot's lease outlives the cell by
  design and was removed by the next release).
- sandboxd positive control: a deliberate `sandbox-exec` denial from a
  terminal context produced NO `log show` records even after 75 minutes —
  violation reporting appears RESPONSIBLE-PROCESS-scoped (the Sep 15
  captures were wikid-responsible). The per-cell 0-denial captures are
  valid for the app/daemon spawns that the matrix runs.

## Verification

- `make build` — clean (warnings-as-errors).
- `make test` — full default graph green (4086 tests).
- `WIKIFS_APP_TESTS=1 make test` — full app graph green, including the two
  new live Seatbelt tests (`strictBunRunnerCanExecuteFromOwnedTemp`,
  `strictPackageRunnerTempDoesNotOpenScratchExecution`).
- Focused suites: `AgentProviderRuntimeLeaseTests`,
  `PackageRunnerTempLeaseTests`, `ProviderCommandResolverTests`,
  `ProviderCommandResolverWiringTests`, `StrictSummarizerEnvironmentParser`
  — all green.
- Per-cell reports + `sandboxd` windows: `tmp/1279/report-row5*.txt`,
  `/tmp/1279-sandboxd-row5*.log`.

## Environment restore state (COMPLETE)

- `agent-providers.json` restored bit-for-bit from the `.pre-1279` backup
  (codex-acp enabled+default as before; the temporary `fast-agent` row is
  gone). The uv cells' provider row was removed with the restore.
- The test-rig `wikid.xpc` Info.plist env injection was REMOVED, the bundle
  re-signed with the dev identity, and the app relaunched — the daemon runs
  the default-off production state. No launchd/`launchctl` strict override
  remains.
- bun/npm/uv caches were moved aside per cold cell and restored after each;
  no `.cold-1279` remnants.

## Follow-up (the promotion gate)

The promotion commit (flip the strict default) is deliberately NOT in this
branch. It requires: Claude login refreshed on this machine, the two
claude-bun cells rerun to full passes (title + model summaries + 0
denials), the two uv cells rerun with credentials, and then exactly one
change — delegate `strictSummarizerEnabled` to
`strictSummarizerEnabled(environment:)` (already implemented + tested).
`WIKIFS_SUMMARIZER_STRICT=0` remains the documented rollback afterwards.
