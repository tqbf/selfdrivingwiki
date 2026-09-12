---
timestamp: 2026-09-12T160100Z
title: Apply the resolved agent seatbelt to the ACP spawn (issue #1251)
branch: feature/agent-sandbox-apply-acp
status: complete
---

# Apply the resolved agent seatbelt to the ACP spawn (issue #1251)

## Progress

`AgentLauncher` resolved a `SandboxProfile.SandboxInvocation` for every
one-shot and interactive chat spawn, but nothing applied it — the applying
seam died with the legacy CLI backend in `a79469d5`, and the ACP path had no
sandbox parameter. Agents ran unsandboxed while comments claimed otherwise.

Changes:

- `BackendProfile` gains `sandbox: SandboxProfile.SandboxInvocation?`.
  `AgentLauncher` threads the resolved invocation into every spawn-committing
  profile: one-shot run, resume profile, interactive chat, and the multi-phase
  ingest path (planner/executor/finalizer via `runPhaseWithFallback` +
  `runACPIngestFallback`). The resolution is hoisted above the resume attempt
  so a resume that spawns fresh is confined too.
- `ACPBackend.startProcess` applies the wrap when the profile carries a
  sandbox: the spawn runs as
  `sandbox-exec -p <profile> -D k=v ... -- <agent> <args>` via the new
  `SandboxProfile.wrappedArguments` (the deleted `applySandbox` argv pattern;
  the extractor wrap now delegates to the same helper). Fail closed on macOS:
  `sandboxExecutableIsUsable` requires an executable regular file, else
  `ACPBackendError.sandboxUnavailable` and no process starts. `TMPDIR` is
  relocated to the pre-created `<scratch>/.tmp` (the old `applySandbox`
  relocation; the leaf constant is pinned by test on both sides).
- `SandboxProfile.invocation(_:addingHomeSubpaths:)`: provider config homes
  the base profile doesn't allow are layered in per spawn command
  (`claude` → none needed; `codex` → `.codex`; `gemini` → `.gemini`; unknown →
  none, a denied write is the signal to add a mapping). Same command-substring
  convention as `launchHint`.
- The stale "always on" comments are now true; `plans/sandbox-agent.md` and
  the PLAN.md row state the applied posture.

## Verification

- `swift build`, `make build`, `make test`: green (4374 tests / 469 suites;
  one unrelated pre-existing flake in `RaceFreeProcessGroupRunnerTests`
  — `pipeFailure(9)` under full-suite parallel load — passes in isolation,
  twice, and is untouched by this diff).
- `WIKIFS_APP_TESTS=1 swift test --filter ACPWiringTests`: 24 passed, including
  the six new seam tests (provider-home mapping, front-end usability gate,
  profile threading, TMPDIR relocation constants, and the derived
  `sandboxedSpawnPlan` — argv wrap shape, provider-home layering, TMPDIR
  relocation, and the nil-scratch/claude no-op cases). SandboxProfile tests:
  45 passed including the three new wrap/extra-subpath tests.
- Denial-verification probes (per provider, issue #1251's requirement),
  real CLIs under the exact production profile + scratch cwd + relocated
  TMPDIR:
  - claude 2.1.252: full startup under the seatbelt; reached the API with a
    401 (this machine's stored OAuth token is revoked — an environmental
    credential state, not confinement; exec, config reads, and network all
    worked). A full authenticated agent turn needs the app session to verify.
  - codex-cli 0.153.4: `codex --version` clean under the wrap with the
    `~/.codex` allowance.
  - Write fence against the agent spawn shape: an out-of-scratch write is
    denied with EPERM; scratch writes succeed.

## Notes

- The resolver itself stays fail-open on path-resolution misconfiguration
  (logged "running UNSANDBOXED") — that matches the resolver's documented
  contract; the application seam is fail-closed.
- Missing provider for live verification (gemini CLI not exercised) — the
  mapping table covers `.gemini`, and a denied config-home write is the
  designed signal if the allowance is wrong.
- Deliberate scope boundary: other LLM-agent subprocess consumers do NOT
  thread a sandbox yet — `ACPExtractionClient` and `MessageSummarizer`
  build nil-sandbox `BackendProfile`s, and `ACPProviderModelProbe` calls
  `Client.launch` directly (a capability probe, not a turn). Widening
  confinement to those consumers is the natural follow-up.
- Fallback-provider scratches (`<scratch>/fallback-<provider>`) get their
  own `.tmp` created before the wrapped spawn — the wrapped agent's TMPDIR
  must exist in every scratch root.
