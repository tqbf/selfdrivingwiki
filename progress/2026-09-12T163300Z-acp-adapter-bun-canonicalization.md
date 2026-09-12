---
timestamp: 2026-09-12T163300Z
title: Canonicalize ACP JS-adapter launches through the resolved bun (#1257 Level 1)
branch: feature/acp-adapter-bun-canonicalization
status: complete
---

# Canonicalize ACP JS-adapter launches through the resolved bun (#1257 Level 1)

## Progress

ACP provider commands are user-configured free-form text, and JS adapters
launched through `npx` depended on the user's node/npm state — the first
wrapped chat died on an `EPERM` write to `~/.npm/_cacache` under the seatbelt.

`ACPBackend.startProcess` now canonicalizes adapter-shaped commands —
executable basename `npx`, `bunx`, `npm exec`/`npm x`, or an already-`bun x`
launch — through the bun resolved via `RuntimeCommandLocator` (the extractor
runtimes' login-shell locator), as `<bun> x <package spec...>`. The executing
runtime no longer depends on which node/npm the PATH resolves; note the
configured command's first token must still exist on PATH for provider
resolution (`resolveACPProviderSpawn`), and the adapter itself still execs the
user's `claude` binary. Level 2 (vendored, digest-pinned adapter in
`Contents/Helpers/`) removes the remaining PATH dependence and stays open on
#1257.

Mechanics:

- Shape gate (`isJSAdapterLaunch`) runs before the locate: plain provider
  binaries never pay for the login-shell probe.
- Resolution is memoized per backend actor as a small state machine
  (`notAttempted` / `inFlight(Task)` / `resolved`): concurrent starts share
  one locate, failed resolution is negative-cached for the backend's lifetime
  (documented deviation from the locator's never-cache-failures contract —
  the npx fallback still works), and a fresh-resolution invalidates on a
  stale `RuntimeFileProbe` identity re-probe, re-resolving exactly once.
- `canonicalizedSpawn` returns nil when the rewrite cannot be safe: unknown
  adapter shapes, unresolvable bun, or leading runner flags it cannot
  translate (`npx --quiet pkg`, `npx -p @scope/pkg bin`,
  `npm exec --prefer-online -- pkg`) — the configured command runs unchanged
  and the fallback is logged. `bunx`/`bun x` keep their arguments verbatim
  and only get repointed. npx-only `-y`/`--yes`/`--` are stripped.
- `ACPProviderModelProbe` canonicalizes with the same helper, shape-gated the
  same way, so its cached model list comes from the runtime chat will run.
- Both outcomes log to the agent channel: `adapter canonicalized <old> →
  <new>`, or the fallback naming the configured command.

## Verification

- `make build`, `make test` (4374 tests / 469 suites), bare `swift build`:
  green.
- `WIKIFS_APP_TESTS=1 swift test --filter ACPWiringTests`: 32 passed —
  adapter canonicalization suite (npx rewrite with field preservation, npm
  exec/x aliases, runner-flag stripping, `bun x` repoint, nil for non-adapter
  and missing-bun shapes, shape-gate table, `~/.npm` layering on the fallback
  path) plus the bun-resolution memoization contract (positive memo, negative
  memo, stale-identity re-resolve-once through injected resolver/probe).
- Reviewed twice by Paseo Claude Opus 5 agents (read-only, plan mode):
  - First round: no CRITICAL; three MAJOR + six MINOR, all addressed.
  - Second round (of the fixes): three MAJOR — probe located bun
    unconditionally (now shape-gated), unrecognized runner flags would break
    working launches (now fail safe to the configured command), and the
    memoization machinery was untested (resolver + probe now injectable,
    contract pinned by three tests). Its MINORs: launch errors name the real
    (bun) executable while the configured command is recorded in the adjacent
    agent log line (accepted); negative-cache lifetime documented as a
    deviation (accepted); concurrent-start double-locate fixed via the
    in-flight task; probe locate accepted outside its 60 s race (documented);
    test comment and progress claims corrected.
