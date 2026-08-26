# Dynamic extractor packages: Phase 4a

Phase 4a adds the managed extractor process executor.

## Delivered

- `ManagedExtractorProcessExecutor` runs one exact validated revision through protocol revision 1.
- Direct launch resolves the entry point inside the package snapshot. Runtime launch resolves one host-owned immutable search list to an absolute executable and never relies on child PATH lookup.
- The executor records a pre-spawn file identity (device, inode, mode, size) and rechecks it immediately before spawn.
- The child receives an allowlisted environment only: operation-private `HOME`, `TMPDIR`, `XDG_CACHE_HOME`, deterministic locale, request correlation values, and capability-gated shared cache paths. It never receives the parent environment, credentials, database paths, or `PATH`.
- Protocol output decodes incrementally and losslessly. A new runner stdout observer delivers every byte in order on a serial queue; the old buffering stream remains for the signed fixture probe only.
- Malformed protocol frames terminate the verified process group promptly instead of waiting for the deadline.
- The effective timeout is the lesser of manifest duration and remaining request deadline.
- Failures are typed: launch, missing runtime, identity change, malformed protocol, sequence violation, timeout, cancellation, output limit, and nonzero or signaled termination.
- Process cleanup reuses the hardened race-free runner path: verified identity before every group signal, TERM then grace then KILL, and awaited reaping on timeout and failure.

## Runner hardening (committed separately as 80a24254)

- Group signals now fail closed when child identity cannot be observed.
- Timeout and failure cleanup perform verified escalation and await reap completion.
- Cancellation can no longer strand a registered continuation in exit or drain waiters.
- Termination causes are typed as normal exit or signal; `terminationStatus` remains for compatibility.

## Verification

The following gates passed on 2026-08-26:

```text
swift test --filter 'ManagedExtractorProcessExecutorTests|RaceFreeProcessGroupRunnerTests'
12 tests passed

make lint
swift build
git diff --check
```

The managed fixture covers direct success with streamed progress, environment allowlisting, parent-secret absence, capability gating, absolute runtime resolution with typed missing-runtime failure, malformed output (exit and hold variants), nonzero exit, timeout with child reaping, cooperative cancellation with child reaping, and prompt termination on malformed protocol from a holding process. Runner tests cover lossless ordered observer delivery, typed signal causes, and repeated immediate cancellation without leaked waiters.

LSP diagnostics are clear for the executor, runner, and tests.

## Remaining Phase 4 work

Phase 4 still needs `ProcessExtractorProvider`: preparation admission checks, operation snapshot creation, adaptation to existing PDF and HTML extraction surfaces, readiness validation, and exact provenance threading.
