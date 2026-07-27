# Paseo Worktree Archive Cleanup

## Scope

Fix archive-time leakage from aborted `swift test` runs in Paseo worktrees.
The teardown is intentionally narrow:

- only `paseo.json`
- one checked-in cleanup script under `scripts/`
- one deterministic shell test fixture + harness
- proportional plan/progress notes

The hook runs during `worktree.teardown`, with the worktree as `cwd`, before
Paseo removes the directory.

## Safety model

The cleanup script kills only processes it can tie to one worktree's test
artifacts.

1. Seed ownership from literal command-line references to that worktree's
   `.xctest` bundle or `.build` helper path.
2. Expand narrowly to related wrappers:
   - test-related ancestors (`swift`, `swift-test`, `swiftpm-testing-helper`,
     `xctest`, `time`, `env`)
   - same-process-group wrappers (`swift`, `swift-test`, `swiftpm-testing-helper`,
     `xctest`, `time`, `tee`, `env`)
3. Send `TERM`, wait a bounded grace window, then `KILL` any survivors.

Non-goals:

- no global `pkill`
- no regex matching on raw worktree paths
- no cleanup for the primary/local checkout
- no attempt to kill arbitrary editors or non-test processes that merely happen
  to reference worktree files
