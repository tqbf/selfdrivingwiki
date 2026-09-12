# Managed extractor seatbelt sandbox

**Status:** Implemented. Every managed extractor package process spawned by
`ManagedExtractorProcessExecutor` runs inside a per-spawn macOS seatbelt
(`sandbox-exec`) profile. Writes are fenced to the operation layout plus
capability-gated shared caches. Network is denied unless the package manifest
declares the `network` capability.

## Threat model

Guarded: a compromised or buggy reviewed package. The package binary is
content-verified before spawn, but it is still third-party code. The hard
fence is filesystem writes. Reads and process-exec stay open — the runtime
needs system dylibs, TLS certificates, and the ability to exec its
interpreter. Network stays closed unless the manifest asks for it.

This mirrors `plans/sandbox-agent.md`, with two differences:

- The agent profile keeps network open because the agent must reach its LLM
  API. The extractor profile can deny network because the host controls the
  manifest and every networked package declares the capability.
- The agent profile fences writes to a scratch dir and the wiki DB. The
  extractor profile fences writes to a hermetic per-operation layout that
  already exists (`ManagedExtractorProcessPaths`), so no relocation step is
  needed.

## The profile

`ExtractorSandboxProfile.generate` emits, in order:

```
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath (param "OPERATION_ROOT")))
(allow file-write* (subpath (param "SHARED_RUNTIME_CACHE")))   ; capability + root
(allow file-write* (subpath (param "SHARED_MODEL_CACHE")))     ; capability + root
(allow file-write* (subpath (param "TOKEN_CACHE")))            ; host-supplied root
(allow file-write-data (literal "/dev/null"))
(allow file-write-data (subpath "/dev/fd"))
(deny network*)                                                ; only without .network
```

- `OPERATION_ROOT` covers the whole per-operation layout. `validate` already
  confines `packageRoot`, `homeRoot`, `temporaryRoot`, and `privateCacheRoot`
  under the operation root, so one allow rule covers them all.
- A cache rule appears only when the manifest declares the capability AND the
  host supplied the root. The capability alone grants nothing.
- `TOKEN_CACHE` is not a capability. The host supplies that root for one
  exact reviewed revision; the manifest cannot request it.
- `/dev/null` and `/dev/fd` are the shell and interpreter basics. Data writes
  only. The Claude-specific tmp marker from the agent profile has no
  extractor equivalent.
- The network deny is last. The seatbelt resolves against the last matching
  rule, so a trailing deny cannot be shadowed by anything after it.

## Canonicalization

Every emitted root goes through `realpath(3)` via `SandboxProfile.canonical`.
Seatbelt matchers match canonical paths. A symlinked component makes an allow
rule silently fail: a root under `/tmp` must be emitted as `/private/tmp/...`
(the trap documented in `plans/sandbox-agent.md`). Paths that do not exist
yet fall back to the input; `realpath` cannot resolve them and the seatbelt
creates them under the canonical parent.

## Fail closed

Before the wrapped spawn, the executor requires `sandbox-exec` to exist as an
executable regular file. A missing path, a non-executable file, or a
directory produces the typed `ManagedExtractorProcessError.sandboxUnavailable`
and the `sandboxUnavailable` diagnostic. No child starts. A package never
runs unsandboxed on macOS.

Linux diagnostic builds have no seatbelt. They spawn unwrapped and emit the
`sandboxUnavailablePlatform` diagnostic so the gap is loud. macOS is the
product gate.

## Enforcement findings (verified live)

Verified on macOS 26.6 arm64 with `sandbox-exec -p` probes and the
`ManagedExtractorProcessExecutorTests` fixture suite. Do not assume these
hold elsewhere; re-probe after a macOS upgrade.

- `(deny file-write*)` with later allows: enforced. Writes outside allowed
  roots fail with `EPERM`. Writes inside succeed.
- `(deny network*)` after `(allow default)`: enforced for TCP `connect()`.
  The failure is a synchronous `EPERM` at the connect call, for blocking and
  non-blocking sockets alike. The listener observes nothing.
- Unix-domain socket `bind` is also denied by `(deny network*)`. If a future
  package needs local IPC sockets, the scoped carve-out is
  `(allow network-bind (local unix-socket (subpath "ROOT")))` layered before
  the deny. This form is verified: bind inside the root succeeds, outside
  fails. The bare form `(allow network-unix)` is invalid syntax; the
  compiler reports `unbound variable`.
- Sandbox nesting is not possible. A second `sandbox_apply` in an already
  sandboxed process fails with `EPERM`.
- An unbound `-D` parameter referenced by `(param ...)` produces a misleading
  compile error: `invalid data type of path filter; expected pattern, got
  boolean`. Check the defines when a profile refuses to compile.

## Runtime gate evidence

One real extraction per local-only bundled runtime, plus one networked
package, run on the developer machine under the production wrap
(`sandbox-exec -p <generated profile> -D OPERATION_ROOT=... -- <runtime>`),
with the closed environment allowlist. Evidence recorded in
`progress/2026-09-12T...-extractor-seatbelt.md`:

- Defuddle 0.19.1 via bun 1.4.0, no capabilities: result frame, correct
  markdown, article metadata extracted.
- Docx2md 1.0.0 via bun 1.4.0, no capabilities: result frame, correct
  markdown via mammoth.
- Pdf2md 1.0.0 via uv (`run --script`), `network` +
  `shared-runtime-cache` declared: uv downloaded 137 packages over the
  network under the profile, terminal result frame received.
- `log show --predicate 'process == "sandboxd"'` showed no denials during
  any run.

## Diagnosing a denied write

Symptom: the package fails with an operation-not-permitted error, or the
extraction dies at a step that writes a file.

1. Reproduce with the diagnostics channel on
   (`log stream` in Console.app, subsystem `com.selfdrivingwiki.debug`,
   category `extraction`). The executor logs `sandbox applied` on every
   confined spawn and `sandbox unavailable` when it refuses to spawn.
2. Run the extraction again with `sandboxd` visible:
   `log show --predicate 'process == "sandboxd"' --last 5m --info --debug`.
   The denied path appears in the denial record.
3. Match the denied path against the emitted rules. A path inside the
   operation root that is still denied usually means a symlinked component:
   the rule names the unresolved path. Canonicalize the root.
4. A package that needs a shared cache it did not declare is a manifest
   change, not a profile change. The capability and the host-supplied root
   must both be present for the allow rule to exist.

The same recipe applies to the agent sandbox; see the research notes at the
end of `plans/sandbox-agent.md`.

## Note for package authors

The sandbox is host-enforced and invisible to package code. One behavior
change is visible: undeclared network use now fails. A package that needs
network access must declare `"capabilities": ["network"]` in
`manifest.json`. Packages that run fully bundled (Defuddle, Docx2md) declare
no capabilities and get no network.
