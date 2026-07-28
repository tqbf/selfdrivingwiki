---
timestamp: 2026-07-27T012419Z
title: "chore: Paseo worktree archive cleanup for leaked swift-test helpers"
branch: null
status: historical
timestamp_source: git-commit
---

# chore: Paseo worktree archive cleanup for leaked swift-test helpers

## Progress


**Bug.** Archiving a Paseo worktree could leave orphaned `swiftpm-testing-helper`
or test-bundle processes behind when a `swift test` run had been aborted. The
observed case had `PPID 1` and a command line referencing that worktree's
`.build/.../WikiFSPackageTests.xctest`, so it survived archive and polluted
later runs in other worktrees.

**Fix.**
- Added `scripts/paseo-archive-cleanup.sh` and wired it into
  [`paseo.json`](paseo.json). The existing setup copy now quotes both
  `PASEO_SOURCE_CHECKOUT_PATH` and `PASEO_WORKTREE_PATH`, and teardown now
  calls the checked-in script instead of embedding shell inline.
- The cleanup script proves ownership from **literal** command-line references
  to the current worktree's `.xctest` bundle or `.build` helper path. It then
  expands only to related test wrappers (`swift`, `swift-test`,
  `swiftpm-testing-helper`, `xctest`, `time`, `tee`, `env`) by ancestor chain
  and process group.
- No `pgrep`/`pkill` regexes are used against raw worktree paths. Matching is
  literal shell substring checks over a `ps` snapshot, which keeps spaces and
  metacharacters safe.
- Shutdown is bounded: `TERM`, poll for a short grace window, then `KILL`
  survivors. Missing/raced-away PIDs are non-errors.
- Added deterministic dry-run verification via
  `scripts/tests/test-paseo-archive-cleanup.sh` and
  `scripts/tests/paseo-archive-cleanup-fixture.psv`. The fixture proves one
  synthetic worktree is selected while another worktree, a same-prefix
  directory (`alpha one-backup`), and a non-test editor process are not.

**Limitations.**
- The cleanup is intentionally scoped to Paseo **worktree archive teardown**.
  It does not try to clean up processes from the primary/local checkout.
- Ownership proof depends on leaked processes still carrying a command-line
  reference to the worktree's test bundle or `.build` path. That covers the
  observed helper/test-bundle leak and related wrappers, but not arbitrary
  detached processes with no surviving worktree evidence.

**Verification.**
- `scripts/tests/test-paseo-archive-cleanup.sh` — passed.
- `python3 -m json.tool paseo.json >/dev/null` — passed.
- `shellcheck scripts/paseo-archive-cleanup.sh scripts/tests/test-paseo-archive-cleanup.sh` —
  could not run on this machine because `shellcheck` is not installed.
- `git diff --check` — passed.

**Plan:** [`plans/paseo-worktree-process-cleanup.md`](plans/paseo-worktree-process-cleanup.md).

## Verification

Historical verification remains in the progress record above.
