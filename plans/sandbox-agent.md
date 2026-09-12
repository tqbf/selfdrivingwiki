# Agent seatbelt sandbox (write whitelist)

**Status:** Implemented on `main` and APPLIED to every AgentLauncher
Ingest/Edit/chat ACP process spawn (issue #1251). Confines the spawned agent
process's filesystem **writes** to a strict allowlist via the macOS seatbelt
(`/usr/bin/sandbox-exec`). Provider-agnostic, macOS 15+, always on for those
spawns — `AgentLauncher` resolves the invocation into `BackendProfile.sandbox`,
and `ACPBackend.startProcess` wraps the spawn argv (`-p <profile> -D … -- <agent>`)
and relocates `TMPDIR` into the scratch dir, fail-closed when the front-end is
unusable. Other LLM-agent consumers (ACP extraction client, message summarizer,
the capability probe) do not thread a sandbox yet; see the PR for #1251.
See also `plans/extractor-sandbox.md` for the managed-extractor twin of this
fence.

## What it does

When enabled (Settings → Agent → Sandbox), every agent spawn (Ingest / Query / Lint
and the interactive Query session) is wrapped so the agent — and **every child it
spawns** (`wikictl`, `node`, `bash`, …) — can write to ONLY:

- the per-run scratch dir (`~/Library/Caches/Self Driving Wiki-agent/<UUID>/`, the
  process cwd), and
- the active wiki's `<ulid>.sqlite` + its SQLite `-wal` / `-shm` / `-journal` sidecars,
- plus any user-listed extra allowed paths.

Every other filesystem write is denied. **Reads, all network, and process execution
stay open** — so the provider starts, reaches its LLM API, reads sources, and runs
`wikictl` unchanged; only the write channel is fenced.

This gives, for free: no persistent backdoors (`LaunchAgents`, shell init), no
credential tampering (`~/.ssh`, `~/.aws`, keychains), and **cross-wiki DB
confinement** (the agent of wiki A cannot write wiki B's DB).

## Threat model

Guarded: a prompt-injected agent (driven by ingested content) trying to plant a
backdoor, overwrite shell init / credentials, or otherwise modify the user's files.

Explicitly NOT guarded (accepted non-goals):
- **Network exfiltration is still possible** (network is open). A provider-egress
  allowlist is the natural follow-up.
- **Reads are open** everywhere.

## How it's invoked

The seatbelt composes *around* the configured provider command, so swapping providers
needs no profile change. `ACPBackend.startProcess` (when `BackendProfile.sandbox`
is non-nil) rewrites the spawn to `executable = /usr/bin/sandbox-exec` and prepends
`-p <profile> -D HOME=… -D SCRATCH_DIR=… -D WIKI_DB=… -- <providerExe>` to the
unchanged provider argv (`SandboxProfile.wrappedArguments`).

The profile is **generated in Swift** (`SandboxProfile.generate`) and passed as one
argv element via `sandbox-exec -p`:

```scheme
(version 1)
(allow default)                                  ; reads/network/exec open
(deny file-write*)                               ; default-deny writes
(allow file-write* (subpath (param "SCRATCH_DIR")))
(allow file-write* (literal (param "WIKI_DB")))
(allow file-write* (literal (string-append (param "WIKI_DB") "-wal")))
(allow file-write* (literal (string-append (param "WIKI_DB") "-shm")))
(allow file-write* (literal (string-append (param "WIKI_DB") "-journal")))
;; one (allow file-write* (literal|subpath <userPath>)) per extra-allowed line
```

### Path canonicalization (symlink trap) — verified empirically

The seatbelt `subpath`/`literal` matchers resolve against the **canonical (real)**
path (the kernel's own `realpath`). If a path passed to the profile contains a symlink
component (e.g. `/tmp` → `/private/tmp`, or `/etc` → `/private/etc`), the rule
**silently fails to match** and the write is denied — the allow looks correct but does
nothing. `SandboxProfile.invocation` therefore canonicalizes the scratch dir, the DB
path, and every user extra-allowed path with `realpath(3)` (NOT Foundation's
`URL.resolvingSymlinksInPath()`, which is unreliable and does NOT resolve `/tmp`).
Keeping this in the tested core layer guards against a regression dropping it (the
production paths — `~/Library/Caches`, `~/Library/Group Containers` — are real, so this
is defensive). (Verified: a `/tmp`-based scratch dir is denied; the same profile with
`/private/tmp`/`$HOME` paths works — scratch + DB writes allowed, everything else denied.)

### Provider self-write relocation

The provider process writes its own config/temp to run. Those are **relocated or
allowed** so the allowlist stays small. Today (issue #1251 wiring):

- `TMPDIR=<scratch>/.tmp` — node/CLI temp. `ACPBackend.startProcess` sets this on
  the wrapped spawn; `AgentLauncher.createSandboxTmpDir` creates the directory
  first (including the `.tmp` under each fallback-provider scratch).
- `~/.claude` + `~/.claude.json` — allowed directly by the base profile (the
  transcript must persist there). Credential/execution subpaths are denied by
  `claudeHomeDenyRules`.
- Other providers' config homes (`~/.codex`, `~/.gemini`) are layered per spawn
  command via `SandboxProfile.invocation(_:addingHomeSubpaths:)` — same
  command-substring convention as `launchHint`.

The launcher creates the scratch `.tmp` subdirectories before spawn (the app
process is unsandboxed; only the spawned child is confined).

### `WIKI_DB` is not conflated

The `-D WIKI_DB=<container>/<ulid>.sqlite` is a **sandbox-exec profile parameter**
(consumed by `(param "WIKI_DB")`). sandbox-exec `-D` params are profile variables and
are **not** injected into the child environment. The existing `WIKI_DB=<ulid>`
**environment variable** that `wikictl` reads is set unchanged by
`OperationCommand.build` — a completely separate channel. They coexist.

## Config

`SandboxConfig` (`sandbox-config.json` in the App Group container) mirrors
`AgentCommandConfig`:

- `enabled: Bool` (default `false`).
- `extraAllowedPaths: String` — one path per line; `~` expanded; non-absolute dropped.
  **Additive only** (can widen, never remove the scratch/DB core).

Loaded fresh at spawn time so Settings changes apply on the next run.

## Adapting for non-claude providers

Claude Code's write locations are covered by the base profile plus the TMPDIR
relocation. A different provider may write its state/temp elsewhere. To adapt:

1. Run once with the sandbox on; if the provider errors on a write, it hit a denial.
2. Find the denied path (see Diagnosing a denied write below).
3. If the write belongs in a config home, add a mapping entry in
   `ACPBackend.providerHomeSubpaths(forCommand:)` (command substring →
   `~`-relative directory). Otherwise relocate it via the provider's env var in
   `BackendProfile.providerHints` (`env.`-prefixed hints reach the child).

This is provider-specific env knowledge, but the seatbelt **profile** stays
provider-neutral — the extra home allowance is data derived from the spawn
command, not a named provider policy in the profile.

## Diagnosing a denied write

Denied writes are the correct sandbox failure mode. To find what was blocked:

```sh
log show --predicate 'process == "sandboxd"' --last 5m --info --debug
```

Look for the `(deny file-write*)` trace naming the path. Then relocate the offending
env or allowlist the path.

## Why not Apple Container / App Sandbox

- **Apple Container** needs macOS 26 and runs a **Linux** container, where the macOS
  `wikictl` binary cannot run — it would force re-architecting the write path.
- **App Sandbox (entitlements)** sandboxes the *app*, not a single spawned subprocess,
  and conflicts with this local dev-signed, un-sandboxed app's access needs.
- `sandbox-exec` ships on macOS 15, needs no entitlement, and is inherited by child
  processes. It is marked deprecated by Apple (they favor App Sandbox), but it is
  stable and depended on by Claude Code, Codex CLI, SwiftPM, Bazel, and Nix.

## Failure modes

- **Stray writes fail closed.** A provider writing outside scratch/DB that isn't
  relocated is denied and the run may error. Correct behavior; diagnose + relocate.
- **Fail-open on misconfiguration** (unresolvable HOME/scratch/DB) skips the sandbox
  and logs a warning — the resolver's documented contract; the APPLICATION seam is
  fail-closed (an unusable `sandbox-exec` refuses to spawn at all).

## Files

- `Sources/WikiFSCore/Core/SandboxProfile.swift` — `SandboxInvocation` + pure
  `generate(...)` / `invocation(...)` / `wrappedArguments(...)` /
  `invocation(_:addingHomeSubpaths:)`.
- `Sources/WikiFSEngine/ACPBackend.swift` — `BackendProfile.sandbox` application:
  `sandboxedSpawnPlan`, `sandboxExecutableIsUsable` (fail closed),
  `providerHomeSubpaths(forCommand:)`.
- `Sources/WikiFSEngine/AgentLauncher.swift` — `resolveSandboxInvocation` +
  `createSandboxTmpDir` + threading into every `BackendProfile` spawn site.
- Tests: `SandboxProfileTests` (pure profiles + argv), `ACPWiringTests`
  seatbelt section (mapping, gate, plan builder, threading), and the live
  probes recorded in `progress/2026-09-12T160100Z-agent-sandbox-apply-acp.md`.
- `plans/extractor-sandbox.md` — the managed-extractor twin of this fence
  (shared `wrappedArguments`).
