---
timestamp: 2026-09-12T150300Z
title: Per-spawn seatbelt sandbox for managed extractor packages
branch: feature/extractor-seatbelt-sandbox
status: complete
---

# Per-spawn seatbelt sandbox for managed extractor packages

## Progress

Every managed extractor package process spawned by
`ManagedExtractorProcessExecutor` now runs inside a per-spawn macOS seatbelt
(`sandbox-exec`) profile. Writes are fenced to the per-operation layout plus
capability-gated shared runtime/model/token caches. Network is denied unless
the package manifest declares the `network` capability. See
`plans/extractor-sandbox.md`.

Changes:

- `Sources/WikiFSCore/Extractor/ExtractorSandboxProfile.swift` (new): pure
  profile generator, invocation builder, and argv wrap. No IO.
- `Sources/WikiFSCore/Extractor/ManagedExtractorProcessExecutor.swift`: wraps
  every spawn with `sandbox-exec -p <profile> -D k=v ... -- <real target>`.
  Identity pinning is unchanged and runs before the wrap. The result still
  reports the real executable. Fail closed: an unusable sandbox front-end
  throws `ManagedExtractorProcessError.sandboxUnavailable` and starts no
  process. Linux diagnostic builds spawn unwrapped and log
  `sandboxUnavailablePlatform`.
- `Sources/WikiFSCore/Extractor/ManagedExtractorDiagnostics.swift`: three new
  events — `sandboxApplied(networkDenied:)`,
  `sandboxUnavailable(command:detail:)`, `sandboxUnavailablePlatform(command:)`.
- `Sources/WikiFSCore/Core/SandboxProfile.swift`: `canonical(_:)` promoted
  from private to internal so both profiles share one realpath helper.
- `Sources/ManagedExtractorFixture/main.swift`: two enforcement modes —
  `outside-write <path>` and `tcp-connect <host> <port>` (direct BSD
  sockets, 3 s bound connect). The TCP probe reports `ok`, `denied`
  (EPERM/EACCES), or a distinct `error-<errno>` so an environment without
  enforcement fails loudly instead of silently matching.
- Tests: `ExtractorSandboxProfileTests` (13 pure tests) and five new
  executor tests with a capturing diagnostics sink and an ephemeral-port
  loopback listener.
- `plans/extractor-sandbox.md`, this entry, and a `PLAN.md` feature row.

## Verification

- `swift build`, `swift build --build-tests`: green.
- `swift test --filter ExtractorSandboxProfileTests`: 13 passed.
- `swift test --filter ManagedExtractorProcessExecutorTests`: 22 passed,
  including the pre-existing fixture suite unchanged under the seatbelt
  (write fence, network deny/allow, fail-closed x3, diagnostics parity).
- `swift test --filter ManagedExtractorDiagnosticsTests`: 6 passed
  (formatter coverage for the three new events).
- Full `make build` / `make test` / bare `swift build` gates: see the PR
  description for the final run on this branch.

Live enforcement probes (macOS 26.6 arm64, recorded in
`plans/extractor-sandbox.md`):

- `(deny file-write*)` with later allows: enforced; outside writes get
  EPERM.
- `(deny network*)` after `(allow default)`: enforced for TCP connect —
  synchronous EPERM, blocking and non-blocking, C and Swift probes; the
  listener observed nothing.
- Unix-socket bind denied under `(deny network*)`; the verified scoped
  carve-out is `(allow network-bind (local unix-socket (subpath ...)))`.
  `(allow network-unix)` is invalid syntax.
- A second `sandbox_apply` inside a sandboxed process fails with EPERM; a
  wrap must be a single profile.
- Unbound `(param ...)` defines compile to a misleading "expected pattern,
  got boolean" error.

Runtime gate (AC.9), one real extraction per local-only bundled runtime plus
one networked package, all under the production wrap with the closed
environment allowlist:

- Defuddle 0.19.1 via bun 1.4.0, no capabilities: result frame, correct
  markdown, article metadata (title/author/word count).
- Docx2md 1.0.0 via bun 1.4.0, no capabilities: result frame, mammoth
  1.12.2, correct markdown.
- Pdf2md 1.0.0 via uv `run --script` with `network` +
  `shared-runtime-cache`: uv downloaded 137 packages over the network
  under the profile (149 s), terminal result frame, correct markdown.
- `log show --predicate 'process == "sandboxd"' --last 15m`: no denials.

## Notes

- The executor accepts an internal `sandboxExecutableURL` for the
  fail-closed tests; production always uses `/usr/bin/sandbox-exec`.
- The agent-side sandbox seam is dead (resolved in `AgentLauncher`, never
  applied to the ACP spawn). Out of scope here; see the companion GitHub
  issue filed for it.
