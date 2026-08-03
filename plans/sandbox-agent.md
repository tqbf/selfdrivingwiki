# Agent seatbelt sandbox (write whitelist)

**Status:** Implemented on `main`. Confines the spawned agent process's filesystem
**writes** to a strict allowlist via the macOS seatbelt (`/usr/bin/sandbox-exec`).
Provider-agnostic, macOS 15+, opt-in (off by default).

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
needs no profile change. `OperationCommand.build` (when `sandbox` is non-nil) sets
`executable = /usr/bin/sandbox-exec` and prepends `-p <profile> -D HOME=… -D
SCRATCH_DIR=… -D WIKI_DB=… -- <providerExe>` to the unchanged provider argv.

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

The provider process writes its own config/temp to run. Those are **relocated into the
scratch dir** so the allowlist stays tiny and provider-agnostic. `OperationCommand`
sets (only when sandbox is on), as distinct env keys that never clobber
`WIKI_ROOT`/`WIKI_DB`/`PATH`:

- `CLAUDE_CONFIG_DIR=<scratch>/.claude-config` — Claude Code's config/history.
- `TMPDIR=<scratch>/.tmp` — node/CLI temp.

The launcher creates both subdirectories before spawn (the app process is unsandboxed;
only the spawned child is confined).

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

Claude Code's two write locations are relocated by the two env vars above. A different
provider may write its state/temp elsewhere. To adapt:

1. Run once with the sandbox on; if the provider errors on a write, it hit a denial.
2. Find the denied path (see Diagnosing a denied write below).
3. Either relocate it into the scratch dir via the provider's env var (add the env in
   `OperationCommand.applySandbox` alongside `CLAUDE_CONFIG_DIR`/`TMPDIR`), or add the
   path to **extra allowed paths** in Settings → Agent → Sandbox.

This is provider-specific env knowledge, but the seatbelt **profile** is
provider-agnostic — it never names a provider.

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
  and logs a warning — acceptable because the feature is opt-in and default-off.

## Files

- `Sources/WikiFSCore/SandboxConfig.swift` — config + `parsedExtraAllowedPaths`.
- `Sources/WikiFSCore/SandboxProfile.swift` — `SandboxInvocation` + pure
  `generate(...)` / `invocation(...)`.
- `Sources/WikiFSCore/OperationCommand.swift` — `sandbox:` param + `applySandbox`.
- `Sources/WikiFS/AgentLauncher.swift` — `resolveSandboxInvocation` + relocation dirs.
- `Sources/WikiFS/AgentCommandSettingsView.swift` — Sandbox section.
- `Sources/WikiFSCore/ClaudePromptHelp.swift` — Command Template reflects the sandbox.
- Tests: `SandboxConfigTests`, `SandboxProfileTests`, `SandboxedOperationCommandTests`.
