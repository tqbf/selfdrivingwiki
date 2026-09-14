# Agent seatbelt sandbox (write whitelist)

**Status:** Implemented on `main` and APPLIED to every LLM-driven child
process (issues #1251 and #1276). Confines each spawned agent process's
filesystem **writes** to a strict allowlist via the macOS seatbelt
(`/usr/bin/sandbox-exec`). Provider-agnostic, macOS 15+, always on:

- **Ingest / Edit / chat** (`AgentLauncher`): the write invocation — writes
  fenced to the wiki DB + scratch + provider config homes; `TMPDIR` relocated
  into the scratch; fail-closed when the front-end is unusable.
- **ACP extraction** (`ACPExtractionClient`): read-only — the staging
  directory doubles as the scratch (`LLMSandboxScratch`); NO wiki DB define;
  no global temp allowance; fail-closed.
- **Model summaries + chat titles** (`AgentProviderRuntime` /
  `MessageSummarizer`): read-only — one owned scratch per
  `prepareSummarization` snapshot, kept for the cached backend's full
  lifetime; release/dispose drains active leases, terminates the backend via
  the process-level `AgentBackend.shutdown()` contract, and only then removes
  the scratch.
- **Provider-model probes** (`ACPProviderModelProbe`): read-only — dedicated
  probe scratch; launch consumed ONLY through the shared typed sandboxed
  launch plan (`ACPBackend.sandboxedSpawnPlan`); the sandbox gate runs at the
  runtime boundary (before command resolution) AND at the direct launch seam.

Every spawn site states its sandbox decision with an explicit `sandbox:`
argument on `BackendProfile`; `LLMSpawnSandboxExhaustivenessTests` audits the
source (closed inventory + named exemptions) and fails on `sandbox: nil`, an
omitted decision, or a new direct `client.launch` outside the shared plan path.
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

## Run context: absolute paths, temp relocation, heredocs (2026-09)

This section records the run-context contract added after the heredoc denial in
chat `01M2EXC4NEDK5WYEMZGFADYXCH`. Feature plan:
`plans/agent-scripting-and-processed-source-rewrite.md`.

### The adapter cannot be trusted with cwd or environment

An ACP adapter may move its nested tool working directory and drop environment
variables. Codex ACP did both: tools ran in a chat-level cache directory, and
`WIKI_DB` was gone. Correctness therefore comes from three places that no
adapter can sanitize:

1. **The typed run context** (`AgentRunContext`, `WikiFSEngine`). One value per
   run carries the canonical timestamped scratch, `<scratch>/.tmp`, the optional
   zsh prefix `<scratch>/.tmp/zsh`, the typed `WikiID`, the trusted absolute
   `wikictl` path, and the effective `PATH`. The launcher builds it once per
   run and threads it through every `BackendProfile`.
2. **The protected environment.** `ACPBackend.startProcess` merges provider
   hints first, then overwrites `WIKI_DB`, `WIKICTL`, `WIKI_SCRATCH`, `PATH`,
   `TMPDIR`, and `TMPPREFIX` from the run context. Provider config cannot
   redirect wiki routing, the scratch, or temp relocation.
3. **The prompt.** Every operation prompt (one-shot, each ingest phase,
   fallback, interactive chat) ends with a RUN ENVIRONMENT block. It states the
   absolute scratch, temp, state, and staged-source paths and renders the
   trusted invocation as `'/abs/wikictl' --wiki <ulid>` through one tested
   quoting helper (`ShellQuoting`). The agent copies the command line from the
   prompt. Nested cwd, `PATH`, `WIKI_DB`, and `WIKICTL` are conveniences.

The profile text is prompt data, not an unforgeable capability. The Seatbelt
active-DB literal allowlist stays the security boundary: a mistaken or
malicious cross-wiki command cannot write (`AgentSandboxProcessTests.
productionSandboxPreventsCrossWikiMutation` proves the denial with the real
`wikictl` binary). No executable stored in agent-writable scratch is generated
or trusted.

### Temp files and heredocs — measured behavior

- zsh stages heredoc temp files under `TMPPREFIX` (default `/tmp/zsh…`,
  independent of `TMPDIR`). The run context sets `TMPPREFIX=<scratch>/.tmp/zsh`,
  so zsh heredocs work inside the fence. This is a compatibility setting for
  adapters that launch zsh (the rbenv-init case). zsh is not selected or
  required anywhere.
- macOS `/bin/sh` and `/bin/bash` stage heredoc temp files in `/tmp`
  REGARDLESS of `TMPDIR`. An in-shell heredoc therefore cannot run inside the
  fence. This is why the profile must NOT permit `/tmp` or `/tmp/zsh*`:
  the allow would be global. Heredoc bodies reach sandboxed `/bin/sh` through
  stdin or a scratch file instead.
- Standard temp files (`mktemp`, runtimes, SQLite) honor `TMPDIR` and work
  under `<scratch>/.tmp`.

The launcher creates `.tmp` and `.tmp/zsh` before every spawn (and before the
sandbox applies), through `AgentRunContext.createTempDirectories()`.

### User PATH discovery is shell-neutral

The effective `PATH` is the helper directory followed by the user environment
PATH. That PATH comes from one login-shell hop through the account's configured
shell (`$SHELL`, else the passwd record) — never a hard-coded `/bin/zsh`. The
hop feeds environment discovery only; agent scripts must not depend on login
shell startup files. A failed or implausible result (empty, or whitespace such
as fish renders) falls back to the inherited process PATH
(`UserEnvironmentPath`, tested with an injected runner).

### CAS-protected processed-source rewrite

`wikictl source edit-markdown` now REQUIRES `--expect-head <version-id>` and
writes only through `appendUserProcessedMarkdown` — one store transaction that
compares the active head, then appends one `.user` version, advances the
`source-derived` ref, refreshes FTS, emits one event, and schedules one
embedding. A stale head throws `SourceMarkdownConflictError` before any write;
the CLI maps it to exit 3 with a re-read/reapply/retry-once message.
`source info` prints `head_version_id` so agents can read the CAS token.
Raw source bytes stay immutable; the File Provider projection stays read-only.

### Live coverage

`AgentSandboxProcessTests` (macOS, `WIKIFS_APP_TESTS=1`) runs the real
`/usr/bin/sandbox-exec`: `/bin/sh` transform + outside-write denial, stdin-fed
heredoc transform, zsh heredoc with scratch `TMPPREFIX`, installed Bun/Python
smokes (capability-gated skips), the absolute `wikictl --wiki` CAS rewrite with
`WIKI_DB`/`WIKICTL`/`PATH` removed, and the cross-wiki denial. The deterministic
half lives in `AgentRunContextTests` and `AgentRuntimePathTests`.

## Strict summarizer tier (issue #1276 follow-up)

The summarizer child is the most fenceable LLM spawn in the app: one-shot, no
file tools, no wiki database, and its input is directly prompt-injectable. It
runs the **strict** profile — `SandboxProfile.strictReadOnlyInvocation`, the
read-only profile plus a **trailer** of last-matching denies:

- **W^X on writable land**: `process-exec*` + `file-map-executable` denied
  under the scratch (including the relocated `TMPDIR`), `CLAUDE_TMP`,
  `/private/tmp`, and `/private/var/tmp`. Nothing the child writes can run or
  be mapped executable.
- **macOS pivot/escape exec denies**: `open` and `launchctl` (launchd spawns
  them outside the fence entirely), `osascript`, `osacompile`, `automator`,
  `shortcuts`, `security`, `crontab`, `at`, `sudo`.
- **Named credential/data read denies**: `~/.ssh`, `~/.aws`, `~/.gnupg`,
  `~/.config/gcloud`, `~/.config/gh`, `~/.kube`, `~/.docker`, `~/.netrc`,
  `~/.git-credentials`, `Library/Keychains`, plus the personal-data set
  (`Messages`, `Mail`, `Cookies`, `Safari`, Firefox/Chrome profiles). Network
  is open, so a read is exfiltration.

Deliberate limits (an adapter is ARBITRARY — it may itself be `uv`, `bun`, or
`node`, so interpreter denies and blanket `$HOME` denies are rejected; the
adapter auth files must stay readable for authentication; the provider-home
write allows stay because `bun x`/`npx` write their caches there).

**Structural invariant:** the seatbelt is purely LAST-MATCH-WINS (verified
empirically — a later rule wins regardless of specificity).
`SandboxInvocation` therefore carries `baseProfile` + `trailer` with a
computed `profile`; `invocation(_:addingHomeSubpaths:)` folds per-spawn write
allows into the BASE and the trailer is always emitted last. A deny that can
be re-opened by later layering is impossible by construction.

**Failure contract:** a strict-mode launch failure degrades — model summaries
fall back to `defaultSummary` truncation per target, and chat titles fall back
to the provisional text. It never leaves a silent unsummarized row, and never
retries unfenced. Escape hatch: `WIKIFS_SUMMARIZER_STRICT=0` (no rebuild).
Before relying on strict with a new adapter, smoke it: start a chat, confirm a
model title + summary appear, and check
`log show --predicate 'process == "sandboxd"' --last 5m --info --debug` for
denials naming the adapter.

Extraction and provider-model probes stay on the plain read-only profile until
they get their own smoke pass (see the issues filed from this work). Residual
risks: network exfiltration, the adapter's own runtime as a full interpreter,
and the write+exec overlap in `~/.bun`/`~/.npm` (that overlap is what makes
`bun x` work).

## Files

- `Sources/WikiFSCore/Core/SandboxProfile.swift` — `SandboxInvocation` + pure
  `generate(...)` / `invocation(...)` / `generateReadOnly(...)` /
  `readOnlyInvocation(...)` / `wrappedArguments(...)` /
  `invocation(_:addingHomeSubpaths:)`.
- `Sources/WikiFSEngine/LLMSandboxScratch.swift` — the read-only LLM scratch
  contract (issue #1276): unique directory + pre-created `.tmp` leaf + the
  matching read-only invocation, owned as one typed value with explicit
  `remove()` cleanup.
- `Sources/WikiFSEngine/ACPBackend.swift` — `BackendProfile.sandbox`
  application: `sandboxedSpawnPlan` (the shared typed launch plan),
  `launchPolicyViolation` (pure fail-closed check), `sandboxExecutableIsUsable`,
  `providerHomeSubpaths(forCommand:)`, and the process-level `shutdown()`
  contract for cached backends.
- `Sources/WikiFSEngine/AgentLauncher.swift` — `resolveSandboxInvocation` +
  `createSandboxTmpDir` + threading into every `BackendProfile` spawn site.
- `Sources/WikiFSEngine/ACPExtractionClient.swift` — extraction fence
  (staging directory = scratch, issue #1276).
- `Sources/WikiFSEngine/AgentProviderRuntime.swift` — summarizer fence:
  snapshot-owned scratch, per-snapshot lease gate, retire → quiesce →
  terminate → remove teardown (issue #1276).
- `Sources/WikiFSEngine/ACPProviderModelProbe.swift` — probe fence: dedicated
  scratch + typed launch plan consumption (issue #1276).
- Tests: `SandboxProfileTests` (pure profiles + argv),
  `LLMSpawnSandboxExhaustivenessTests` (source audit: constructor inventory +
  direct-launch inventory + mutation fixtures), `ACPExtractionClientTests` /
  `AgentProviderRuntimeTests` / `MessageSummaryTests` (profile ownership,
  teardown ordering, catalog ordering), `ACPWiringTests` seatbelt section
  (mapping, gate, plan builder, threading, extraction effective plan), and the
  live probes recorded in `progress/2026-09-12T160100Z-agent-sandbox-apply-acp.md`.
- `plans/extractor-sandbox.md` — the managed-extractor twin of this fence
  (shared `wrappedArguments`).
