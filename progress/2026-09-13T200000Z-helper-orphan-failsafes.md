---
timestamp: 2026-09-13T200000Z
title: Helper orphan failsafes (#1259)
branch: bugfix/helper-orphan-failsafes
status: complete
---

# Helper orphan failsafes (#1259)

## Progress

Two orphaned `RendererAssetReferenceExtractorHelper` processes spun at 100%
CPU for days after their `swift test` parents died without killing the
process group. The helper's only termination guarantee was a living parent.

The helper now arms two host-side failsafes before reading its frame, and
neither is visible to the JavaScript (the JSContext still sees no timers and
no way to learn about time):

1. **Self-deadline** — a fixed 60 s ceiling (six times the manifest
   contract's 10 s maximum declared deadline) after which the helper
   exits(3) no matter what it is doing.
2. **Orphan detection** — the parent PID recorded at startup is polled every
   second; a change (reparenting) or launchd-at-birth exits(4) within one
   poll interval.

Stdout writes now use raw `write(2)` with SIGPIPE ignored, so a dead stdout
exits nonzero (2) instead of spinning or dying to an uncatchable signal.
Shorten-only argv overrides (`--self-deadline-seconds`,
`--orphan-poll-milliseconds`) exist for tests; unknown arguments exit 64.

`ExtractorProcessFixture` gained a `spawnChildAndExit` mode (spawns a child,
reports its PID, exits — orphaning it) so tests can simulate parent death,
plus a 600 s `alarm()` ceiling on `holdWithChild`.
`ManagedExtractorFixture` hold modes (`linger`, `malformed-hold`, `hold`)
gained the same 600 s ceiling. Both fixtures previously had `pause()` loops
whose only termination guarantee was the supervising runner.

The full helper/spawned-process surface review required by the issue is in
the PR description.

## Verification

- `swift test --filter HelperFailsafeTests`: 4 tests pass (self-deadline at
  2.3 s, orphan exit at 0.9 s, legitimate extraction unaffected, usage
  error).
- `make test`: 4382 tests in 470 suites pass, including the existing
  `terminatesAndReapsInfiniteLoopHelper` and reviewed-extractor tests.
- `make build` succeeds.
